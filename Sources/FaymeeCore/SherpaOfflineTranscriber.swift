import Foundation
import SherpaOnnxC

/// sherpa 整段识别模型的一个已加载实例：16 kHz 单声道样本 → 文字（+ 可选逐字开始时间）。
/// 各家族一个实现（Paraformer、Fun-ASR-Nano、Qwen3-ASR），创建时加载模型，释放时（deinit）销毁 sherpa 句柄。
///
/// - 会后转写：`SherpaOfflineTranscriber` 每场转写建一个，按段调用，转写结束就释放
/// - 实时字幕定稿：会话开始时建一个、结束时释放，对每句的音频直接调用（不切段）
/// - 同一实例不会被并发调用；`recognize` 同步、可能耗时，调用方放在后台队列
public protocol SegmentRecognizer: AnyObject {
    /// 识别一段音频。样本是 16 kHz 单声道 float32（[-1, 1]），一段不超过 10 秒（见 `SpeechSegmentation`）
    func recognize(_ samples: ArraySlice<Float>) throws -> SegmentRecognition
}

/// sherpa 模型文件的问题。加载前先查，不交给 sherpa-onnx（坏模型会让它 `_Exit` 整个进程）
public enum SherpaModelError: LocalizedError, Equatable {
    /// 文件不在
    case missing(model: String, file: String)
    /// 文件大小不对（没下完、被截断）
    case incomplete(model: String, file: String)
    /// 打进 App 的静音切段模型不在或大小不对
    case vadMissing
    /// sherpa-onnx 创建识别器失败（返回 NULL）
    case engineUnavailable(model: String)

    public var errorDescription: String? {
        switch self {
        case let .missing(model, file): "\(model)模型缺少文件 \(file)，请在设置里重新下载"
        case let .incomplete(model, file): "\(model)文件 \(file) 不完整，请在设置里重新下载"
        case .vadMissing: "缺少静音切段模型，请重新安装 Faymee"
        case let .engineUnavailable(model): "\(model)引擎启动失败"
        }
    }
}

extension LocalModel {
    /// 按大小确认文件齐全（不算哈希：下载器校验过哈希才改名到位）。`name` 是错误信息里的模型名
    public func checkFiles(name: String, in root: URL = LocalModel.defaultDirectory) throws {
        for file in files {
            let url = url(of: file, in: root)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SherpaModelError.missing(model: name, file: file.path)
            }
            guard fileHasSize(url, file.size) else { throw SherpaModelError.incomplete(model: name, file: file.path) }
        }
    }
}

/// Silero VAD（打进 App 的 `Contents/Resources/VAD/silero_vad.onnx`）：找出录音里说话的部分
public enum SileroVAD {
    /// sherpa-onnx `asr-models/silero_vad.onnx`，与 scripts/fetch-vad-model.sh 一致
    public static let modelSize: Int64 = 643_854

    /// App 里的模型位置；`swift run` 等没有打包时为 nil
    public static var bundledModel: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("VAD/silero_vad.onnx")
    }

    /// 文件在且大小对
    public static func check(_ url: URL?) throws {
        guard let url, fileHasSize(url, modelSize) else { throw SherpaModelError.vadMissing }
    }

    /// 参数同评估脚本（capped.py）：最短静音 0.4 秒；其余显式写出 sherpa-onnx 的默认值（C API 里 0 表示默认，
    /// 不写就看不出用的是什么）。`max_speech_duration` 不是硬上限，只是段太长时提高门限促使它断开
    static let threshold: Float = 0.5
    static let minSilence: Float = 0.4
    static let minSpeech: Float = 0.25
    static let maxSpeech: Float = 10
    static let windowSize = 512

    /// 整段 16 kHz 样本里说话的部分（样本下标，按先后、不重叠）。每喂一窗就取走已完成的段，缓冲不会积压；
    /// 每喂约 10 秒检查一次取消
    static func speech(in samples: [Float], model: URL, flag: CancelFlag,
                       progress: (Double) -> Void = { _ in }) throws -> [Range<Int>] {
        try check(model)
        let path = strdup(model.path)
        let cpu = strdup("cpu")
        defer { free(path); free(cpu) }
        var config = SherpaOnnxVadModelConfig()
        config.silero_vad.model = UnsafePointer(path)
        config.silero_vad.threshold = threshold
        config.silero_vad.min_silence_duration = minSilence
        config.silero_vad.min_speech_duration = minSpeech
        config.silero_vad.max_speech_duration = maxSpeech
        config.silero_vad.window_size = Int32(windowSize)
        config.sample_rate = Int32(SpeechSegmentation.sampleRate)
        config.num_threads = 1
        config.provider = UnsafePointer(cpu)
        // 缓冲要装下正在说的一段（段一完成就取走）。真实会议里 VAD 出过 60 秒的段，同评估脚本取 600 秒（约 38 MB）
        guard let vad = SherpaOnnxCreateVoiceActivityDetector(&config, 600) else { throw SherpaModelError.vadMissing }
        defer { SherpaOnnxDestroyVoiceActivityDetector(vad) }

        var ranges: [Range<Int>] = []
        func drain() {
            while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
                // Front 返回一份拷贝：只用起点和长度，样本从自己的数组里取
                if let segment = SherpaOnnxVoiceActivityDetectorFront(vad) {
                    let start = max(0, Int(segment.pointee.start))
                    let end = min(samples.count, start + Int(segment.pointee.n))
                    if end > start { ranges.append(start..<end) }
                    SherpaOnnxDestroySpeechSegment(segment)
                }
                SherpaOnnxVoiceActivityDetectorPop(vad)
            }
        }
        try samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var i = 0
            while i < buffer.count {
                if i % (windowSize * 312) == 0 {
                    try flag.check()
                    progress(Double(i) / Double(buffer.count))
                }
                let n = min(windowSize, buffer.count - i)
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, base + i, Int32(n))
                drain()
                i += n
            }
        }
        SherpaOnnxVoiceActivityDetectorFlush(vad)
        drain()
        progress(1)
        return ranges
    }
}

/// sherpa 整段模型的会后转写（Paraformer、Fun-ASR-Nano、Qwen3-ASR 共用）：
/// 查模型文件 → 解码成 16 kHz 单声道 → Silero VAD 切段（补边、10 秒硬上限）→ 逐段识别 → 组装句子。
/// 家族之间只差“怎么加载模型、怎么识别一段”，由 `makeRecognizer` 提供。
///
/// - 加载前按大小确认主模型和依赖的辅助模型（如标点模型）、静音切段模型都齐全，缺了抛 `SherpaModelError`
/// - 识别器每场转写建一个（热词是识别器级别的配置），转写结束就释放，不常驻内存
/// - 进度：解码 0–5%，切段 5–10%，识别 10–100% 按已识别到录音的哪个位置；每段之间检查取消
/// - 内存主要是整段录音解码后的样本（1 小时约 230 MB）
public final class SherpaOfflineTranscriber: Transcriber, @unchecked Sendable {
    public typealias MakeRecognizer = @Sendable (_ hotwords: [String]) throws -> any SegmentRecognizer
    typealias Segmenter = @Sendable (_ samples: [Float], _ flag: CancelFlag) throws -> [Range<Int>]

    private let models: [(name: String, model: LocalModel)]
    private let root: URL
    private let vadModel: URL?
    private let segmenter: Segmenter
    private let makeRecognizer: MakeRecognizer
    /// 串行：同一时刻只跑一场（占 CPU 和与录音时长成正比的内存）
    private let queue = DispatchQueue(label: "com.faymee.sherpa-transcriber", qos: .utility)

    /// - Parameters:
    ///   - model: 目录项；它和它依赖的、需要下载的辅助模型都要在 `modelDirectory` 下齐全
    ///   - vadModel: 静音切段模型，App 里传 `SileroVAD.bundledModel`
    ///   - makeRecognizer: 加载模型、建识别器（参数是热词表）。只在文件确认齐全后调用
    public convenience init(model: CatalogModel, catalog: ModelCatalog = .builtIn,
                            modelDirectory: URL = LocalModel.defaultDirectory, vadModel: URL?,
                            makeRecognizer: @escaping MakeRecognizer) {
        self.init(model: model, catalog: catalog, modelDirectory: modelDirectory, vadModel: vadModel,
                  segmenter: { samples, flag in
                      guard let vadModel else { throw SherpaModelError.vadMissing }
                      return try SileroVAD.speech(in: samples, model: vadModel, flag: flag)
                  },
                  makeRecognizer: makeRecognizer)
    }

    /// 测试用：`segmenter` 代替 VAD 给出说话段
    init(model: CatalogModel, catalog: ModelCatalog, modelDirectory: URL, vadModel: URL?,
         segmenter: @escaping Segmenter, makeRecognizer: @escaping MakeRecognizer) {
        models = ([model] + catalog.dependencies(of: model)).compactMap { m in m.download.map { (m.name, $0) } }
        root = modelDirectory
        self.vadModel = vadModel
        self.segmenter = segmenter
        self.makeRecognizer = makeRecognizer
    }

    /// 只确认文件齐全（按大小，很快）；模型在转写时才加载
    public func prepare(progress: @escaping (Double) -> Void) async throws {
        try checkFiles()
        progress(1)
    }

    public func transcribe(audio: URL, hotwords: [String],
                           progress: @escaping (Double) -> Void) async throws -> [TranscribedSentence] {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                queue.async {
                    c.resume(with: Result {
                        try self.run(audio: audio, hotwords: hotwords, flag: flag, progress: progress)
                    })
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    private func checkFiles() throws {
        for (name, model) in models { try model.checkFiles(name: name, in: root) }
        try SileroVAD.check(vadModel)
    }

    private static let decodeShare = 0.05
    private static let segmentShare = 0.05

    private func run(audio: URL, hotwords: [String], flag: CancelFlag,
                     progress: @escaping (Double) -> Void) throws -> [TranscribedSentence] {
        try flag.check()
        try checkFiles()
        let samples = try SherpaOnnxDiarizer.decode(audio, flag: flag) { progress($0 * Self.decodeShare) }
        try flag.check()
        let speech = try segmenter(samples, flag)
        let segments = SpeechSegmentation.segments(speech: speech, samples: samples)
        progress(Self.decodeShare + Self.segmentShare)

        let recognizeFrom = Self.decodeShare + Self.segmentShare
        var results: [(segment: SpeechSegment, recognition: SegmentRecognition)] = []
        // 识别器只活在这一场转写里：函数返回即释放
        if !segments.isEmpty {
            let recognizer = try makeRecognizer(hotwords)
            for segment in segments {
                try flag.check()
                results.append((segment, try recognizer.recognize(samples[segment.audio])))
                let done = Double(segment.audio.upperBound) / Double(max(1, samples.count))
                progress(recognizeFrom + (1 - recognizeFrom) * done)
            }
        }
        try flag.check()
        progress(1)
        return SentenceAssembly.sentences(results)
    }
}
