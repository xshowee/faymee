import AVFoundation
import Foundation
import SherpaOnnxC

/// 实时字幕的 sherpa-onnx 流式引擎（家族 `sherpaOnlineTransducer`，如 X-ASR 480ms / 960ms）：
/// 在线 transducer 边送边解码，尾部静音 0.6 秒算一段说完（endpoint）。一段按句末标点切成句子发 `.sentence`，
/// 没说完的部分发 `.volatile`（见 `SegmentDecoder.decode`）。X-ASR 自带标点和英文大小写，不接标点模型。
///
/// - 模型文件从 `directory` 下的模型目录读，按文件名前缀找 encoder / decoder / joiner，加 `tokens.txt`；
///   同一家族的新模型只要文件名照这个规矩，加一条目录项就能用
/// - 坏模型会让 sherpa-onnx `_Exit` 整个进程：每次开始转写前都按大小确认文件齐全（ticket 01 下载时已校验 sha256），
///   不齐（比如会中删了模型）就发 `.failed`，不交给 sherpa-onnx
/// - 每次 `start` 加载一份识别器（int8 约 170 MB，加载不到 1 秒），转写结束或取消时释放；加载期间送来的音频先缓存
/// - 默认不用热词，`start` 传进来的热词表忽略，一直用 `greedy_search`（评估用的就是它）。热词要 `modified_beam_search`：
///   它的结果会回改，句子只能等停顿处定稿，真实会议里九成句子晚 9–15 秒才定稿，字差异率也没变好（ticket 07）。
///   热词交给实时字幕定稿和会后转写。`usesHotwords` 打开时按流传入热词（见 `OnlineRecognizer.hotwordsVocab`），留给对比测试
/// - 退出 App 前调用 `waitUntilReleased`：识别器还在加载或解码时进程退出，onnxruntime 会崩在已析构的全局表上
public final class SherpaStreamingTranscriber: StreamingTranscriber {
    public let model: LocalModel
    private let directory: URL
    private let threads: Int
    private let usesHotwords: Bool

    /// threads 与评估一致取 2：480ms 版 20 分钟音频约 40 秒解完（约 3% 实时），不必多占核
    public init(model: LocalModel, directory: URL = LocalModel.defaultDirectory, threads: Int = 2,
                usesHotwords: Bool = false) {
        self.model = model
        self.directory = directory
        self.threads = threads
        self.usesHotwords = usesHotwords
    }

    /// 正在用识别器（加载、解码）的转写任务。转写任务开始前进入、放掉识别器后离开
    static let inFlight = DispatchGroup()

    /// 等所有转写任务放掉识别器（取消或结束之后，最多再等加载完一次，通常不到 1 秒）。App 退出前在主线程调用；
    /// 转写任务不需要主线程。超时返回 false
    @discardableResult
    public static func waitUntilReleased(timeout: TimeInterval) -> Bool {
        inFlight.wait(timeout: .now() + timeout) == .success
    }

    /// 模型是用时下载的，下载由设置里的模型选择负责；这里只确认文件齐全
    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard model.isDownloaded(in: directory) else { throw SherpaStreamingError.modelMissing }
        progress(1)
    }

    public func start(format: AVAudioFormat, hotwords: [String]) -> any StreamingTranscription {
        SherpaStreamingTranscription(model: model, directory: directory, threads: threads, format: format,
                                     hotwords: usesHotwords ? hotwords : [])
    }
}

enum SherpaStreamingError: LocalizedError {
    case modelMissing
    case unsupportedFormat
    case engineUnavailable

    var errorDescription: String? {
        switch self {
        case .modelMissing: "实时字幕模型还没下载完"
        case .unsupportedFormat: "实时字幕不支持当前麦克风的音频格式"
        case .engineUnavailable: "实时字幕模型加载失败"
        }
    }
}

/// AVAudioPCMBuffer 不是 Sendable。送入后只在转写任务里读，调用方不再改它
private struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    /// 开头在调用方时间线上的位置
    let time: TimeInterval
}

private final class SherpaStreamingTranscription: StreamingTranscription, @unchecked Sendable {
    let events: AsyncStream<StreamingTranscriptionEvent>
    private let output: AsyncStream<StreamingTranscriptionEvent>.Continuation
    private let input: AsyncStream<AudioChunk>.Continuation
    private var task: Task<Void, Never>?

    /// 识别器跟不上（或还在加载）时最多积压这么多块（采集约 0.1 秒一块，约 1 分钟），再多丢最旧的
    private static let backlog = 600

    init(model: LocalModel, directory: URL, threads: Int, format: AVAudioFormat, hotwords: [String]) {
        (events, output) = AsyncStream.makeStream()
        let audio: AsyncStream<AudioChunk>
        (audio, input) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(Self.backlog))
        let output = output
        // 解码是同步的 C 调用，每块几毫秒到几十毫秒；不在调用方（主线程）的执行器上跑。
        // 在这里就进入 inFlight：任务还没开始跑时 App 退出也要等它
        SherpaStreamingTranscriber.inFlight.enter()
        task = Task.detached(priority: .userInitiated) {
            // run 返回时识别器已释放（局部变量）
            defer { SherpaStreamingTranscriber.inFlight.leave() }
            do {
                try await Self.run(audio, model: model, directory: directory, threads: threads, format: format,
                                   hotwords: hotwords, output: output)
            } catch where !Task.isCancelled {
                output.yield(.failed(error.localizedDescription))
            } catch {}
            output.finish()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) {
        input.yield(AudioChunk(buffer: buffer, time: time))
    }

    func finish() { input.finish() }

    /// 事件流立即结束；识别器在转写任务手上的这块解完（或加载完）后释放
    func cancel() {
        input.finish()
        task?.cancel()
        output.finish()
    }

    // MARK: - 转写

    /// 结束时补的静音：让最后一块音频所在的那段也能解出来（同评估）
    private static let tailPadding = MonoResampler.sampleRate / 2

    private static func run(_ audio: AsyncStream<AudioChunk>, model: LocalModel, directory: URL, threads: Int,
                            format: AVAudioFormat, hotwords: [String],
                            output: AsyncStream<StreamingTranscriptionEvent>.Continuation) async throws {
        guard model.isDownloaded(in: directory) else { throw SherpaStreamingError.modelMissing }
        guard let resampler = MonoResampler(from: format) else { throw SherpaStreamingError.unsupportedFormat }
        // 还没开始加载就取消了（录音刚开始就停）：不加载
        try Task.checkCancellation()
        let recognizer = try OnlineRecognizer(model: model, directory: directory, threads: threads,
                                              hotwords: hotwords)
        try Task.checkCancellation()
        let decoder = SegmentDecoder(recognizer: recognizer, hotwords: hotwords)
        var timeline = StreamingAudioTimeline()
        var emitter = Emitter(output: output)

        // 取消时 AsyncStream 的迭代直接结束（取消后不再往下解）
        for await chunk in audio {
            if Task.isCancelled { break }
            // 积压太多时丢掉的音频不进识别器，只记实际送进去的，结果的时间据此换回调用方的时间线
            let seconds = Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
            timeline.record(duration: seconds, at: chunk.time)
            decoder.accept(try resampler.convert(chunk.buffer))
            decoder.decode(emitter: &emitter, timeline: timeline)
        }
        try Task.checkCancellation()
        decoder.accept([Float](repeating: 0, count: tailPadding), padding: true)
        decoder.finish(emitter: &emitter, timeline: timeline)
    }

    /// 发事件：句子时间换到调用方的时间线上，不早于上一句的结束
    private struct Emitter {
        let output: AsyncStream<StreamingTranscriptionEvent>.Continuation
        var volatile = ""
        var lastEnd: TimeInterval = -.infinity

        mutating func volatile(_ text: String, start: TimeInterval, timeline: StreamingAudioTimeline) {
            guard text != volatile else { return }
            volatile = text
            output.yield(.volatile(text, start: max(timeline.time(at: start), lastEnd)))
        }

        /// 这一段说完了：发出切好的句子（同时清掉临时文字）；一句都没有时只清掉临时文字
        mutating func sentences(_ sentences: [TranscribedSentence], timeline: StreamingAudioTimeline) {
            guard !sentences.isEmpty else { return clearVolatile() }
            for sentence in sentences {
                let s = max(timeline.time(at: sentence.start), lastEnd)
                let e = max(s, timeline.time(at: sentence.end))
                lastEnd = e
                output.yield(.sentence(TranscribedSentence(start: s, end: e, text: sentence.text)))
            }
            volatile = ""
        }

        mutating func clearVolatile() {
            guard !volatile.isEmpty else { return }
            volatile = ""
            output.yield(.volatile("", start: 0))
        }
    }

    /// 一个识别流：送样本、解码、按 endpoint 断句。时间都是识别器时间（从第一块音频开头起按样本数算的秒数）
    private final class SegmentDecoder {
        private let recognizer: OnlineRecognizer
        private let stream: OpaquePointer
        /// 已送入的样本数（不含结束时补的静音），句子结束时间不超过它
        private var fed = 0

        init(recognizer: OnlineRecognizer, hotwords: [String]) {
            self.recognizer = recognizer
            stream = recognizer.makeStream(hotwords: hotwords)
        }

        deinit { SherpaOnnxDestroyOnlineStream(stream) }

        private var fedSeconds: Double { Double(fed) / Double(MonoResampler.sampleRate) }

        /// padding：结束时补的静音，不算送入的音频
        func accept(_ samples: [Float], padding: Bool = false) {
            guard !samples.isEmpty else { return }
            if !padding { fed += samples.count }
            samples.withUnsafeBufferPointer {
                SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(MonoResampler.sampleRate), $0.baseAddress,
                                                     Int32($0.count))
            }
        }

        /// 这一段里已经发出去的句子数
        private var emitted = 0

        /// 解完已送入的音频。一段说完（endpoint）就把这段剩下的按句末标点切成句子发出、开始下一段；
        /// 没说完时，识别结果只往后加的话（不用热词时），后面已经接着说了的句子先发出，不等整段说完
        /// （一段可以长到 20 秒），其余作为临时文字
        func decode(emitter: inout Emitter, timeline: StreamingAudioTimeline) {
            while SherpaOnnxIsOnlineStreamReady(recognizer.handle, stream) != 0 {
                SherpaOnnxDecodeOnlineStream(recognizer.handle, stream)
            }
            let sentences = recognizer.result(of: stream).sentences(limit: fedSeconds)
            if SherpaOnnxOnlineStreamIsEndpoint(recognizer.handle, stream) != 0 {
                emitter.sentences(Array(sentences.dropFirst(emitted)), timeline: timeline)
                emitted = 0
                SherpaOnnxOnlineStreamReset(recognizer.handle, stream)
                return
            }
            if recognizer.isAppendOnly, sentences.count - 1 > emitted {
                emitter.sentences(Array(sentences[emitted..<sentences.count - 1]), timeline: timeline)
                emitted = sentences.count - 1
            }
            let open = sentences.dropFirst(emitted)
            if let first = open.first {
                emitter.volatile(open.map(\.text).joined(), start: first.start, timeline: timeline)
            } else {
                emitter.clearVolatile()
            }
        }

        /// 输入结束：解完剩下的，最后没说完的半句也定稿
        func finish(emitter: inout Emitter, timeline: StreamingAudioTimeline) {
            SherpaOnnxOnlineStreamInputFinished(stream)
            while SherpaOnnxIsOnlineStreamReady(recognizer.handle, stream) != 0 {
                SherpaOnnxDecodeOnlineStream(recognizer.handle, stream)
            }
            let sentences = recognizer.result(of: stream).sentences(limit: fedSeconds)
            emitter.sentences(Array(sentences.dropFirst(emitted)), timeline: timeline)
        }
    }
}
