import AVFoundation
import Foundation

/// 实时字幕定稿用的模型：设置里“实时字幕定稿”选中的整段模型（Paraformer、Fun-ASR-Nano）。
/// 实时字幕会话开始时在后台建一个识别器，会话结束时释放；流式引擎每定稿一句，就把这一句的音频交给它重转
public struct LiveCaptionFinalizerModel: Sendable {
    /// 目录项 id
    public let id: String
    /// 建识别器（在后台线程上调用，可以慢）。参数是热词表（不支持热词的模型忽略）
    let makeRecognizer: @Sendable ([String]) throws -> any SegmentRecognizer

    public init(id: String, makeRecognizer: @escaping @Sendable ([String]) throws -> any SegmentRecognizer) {
        self.id = id
        self.makeRecognizer = makeRecognizer
    }

    /// 定稿每个模型的推理线程数。和流式引擎（2 线程）、录音同时跑，不多占核
    static let threads = 2

    /// 所选的定稿模型；“不用”、不是能定稿的模型，或模型（含标点模型等依赖）没下载完时为 nil（不定稿）。
    /// 文件取自目录项自己的 `download`（`SegmentRecognizerLoader`）。录音开始时选一次，录音中改设置从下一场起生效
    public init?(selected: CatalogModel?, catalog: ModelCatalog = .builtIn,
                 directory: URL = LocalModel.defaultDirectory) {
        self.init(selected: selected, catalog: catalog, directory: directory, adapter: \.segmentRecognizer)
    }

    /// 测试用：`adapter` 代替 `ModelFamily.segmentRecognizer`（换掉加载）
    init?(selected: CatalogModel?, catalog: ModelCatalog, directory: URL,
          adapter: (ModelFamily) -> SegmentRecognizerAdapter?) {
        guard let selected, selected.roles.contains(.liveFinalize),
              let loader = SegmentRecognizerLoader(model: selected, catalog: catalog, modelDirectory: directory,
                                                   adapter: adapter),
              loader.isDownloaded else { return nil }
        // 加载时再按大小确认一次文件（会中可能被删；坏文件会让 sherpa-onnx `_Exit` 整个进程）
        self.init(id: selected.id) { hotwords in try loader.makeRecognizer(hotwords: hotwords, threads: Self.threads) }
    }
}

/// 定稿的工作线程：建好识别器后逐句重转，结果从 `results` 按句子 id 交出。
///
/// - 一个专用线程，同一时间只识别一句。识别比说话慢时请求排队，排队超过 `backlog` 句丢最旧的（那句保留流式结果）
/// - 超过 10 秒的句子按 `SpeechSegmentation` 的规矩在安静处切成 ≤ 10 秒的几段分别识别再接起来
///   （Fun-ASR-Nano 的上下文装不下更长的音频，会整段缺字）
/// - `cancel` 后不再识别新的句子，手上这句识别完（或模型加载完）就释放识别器。识别器在用时进入
///   `SherpaStreamingTranscriber.inFlight`，App 退出前等它放掉（onnxruntime 在进程退出时还在用会崩）
final class SentenceFinalizer: @unchecked Sendable {
    struct Result: Sendable {
        let id: Int
        let text: String
    }

    /// 排队等定稿的句子最多这么多，再多丢最旧的
    static let backlog = 5

    let results: AsyncStream<Result>

    private let condition = NSCondition()
    private var pending: [(id: Int, samples: [Float])] = []
    private var cancelled = false
    private var _dropped = 0
    /// 因积压丢掉的请求数（测量用）
    var dropped: Int { condition.withLock { _dropped } }

    init(model: LiveCaptionFinalizerModel, hotwords: [String]) {
        let (results, output) = AsyncStream<Result>.makeStream()
        self.results = results
        let make = model.makeRecognizer
        // 线程还没开始跑时 App 退出也要等它
        SherpaStreamingTranscriber.inFlight.enter()
        let thread = Thread { [self] in
            work(make: make, hotwords: hotwords, output: output)
            output.finish()
            SherpaStreamingTranscriber.inFlight.leave()
        }
        thread.name = "faymee.live-caption-finalize"
        thread.qualityOfService = .userInitiated
        // onnxruntime 推理时调用线程也要算，默认的 512 KB 栈偏小
        thread.stackSize = 8 << 20
        thread.start()
    }

    /// 交一句音频（16 kHz 单声道）去定稿。不阻塞
    func submit(id: Int, samples: [Float]) {
        condition.withLock {
            guard !cancelled else { return }
            pending.append((id, samples))
            if pending.count > Self.backlog {
                pending.removeFirst()
                _dropped += 1
            }
            condition.signal()
        }
    }

    /// 丢掉还在排队的句子（手上这句照常识别完）
    func dropPending() {
        condition.withLock { pending.removeAll() }
    }

    /// 不再定稿：丢掉排队的，手上这句识别完就释放识别器、结束 `results`
    func cancel() {
        condition.withLock {
            cancelled = true
            pending.removeAll()
            condition.signal()
        }
    }

    private var isCancelled: Bool { condition.withLock { cancelled } }

    /// 识别器只在这个函数里活着：返回时已释放
    private func work(make: @Sendable ([String]) throws -> any SegmentRecognizer, hotwords: [String],
                      output: AsyncStream<Result>.Continuation) {
        guard !isCancelled, let recognizer = try? make(hotwords) else { return }
        while let request = next() {
            // 识别出错、中途取消：这句保留流式结果
            guard let text = try? Self.recognize(request.samples, with: recognizer, until: { isCancelled }) else {
                continue
            }
            output.yield(Result(id: request.id, text: text))
        }
    }

    /// 等下一句；取消后返回 nil
    private func next() -> (id: Int, samples: [Float])? {
        condition.withLock {
            while pending.isEmpty, !cancelled { condition.wait() }
            return cancelled ? nil : pending.removeFirst()
        }
    }

    /// 识别一句：超过 10 秒的切成几段分别识别再接起来。每段之前看一眼 stop，取消了就不再往下识别（返回 nil）
    static func recognize(_ samples: [Float], with recognizer: any SegmentRecognizer,
                          until stop: () -> Bool = { false }) throws -> String? {
        var text = ""
        for piece in SpeechSegmentation.pieces(of: samples) {
            if stop() { return nil }
            text = join(text, try recognizer.recognize(samples[piece]).text)
        }
        return text
    }

    /// 接起两段文字：英文、数字接英文、数字时中间加空格
    static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        guard let last = a.last, let first = b.first else { return a + b }
        let latin = { (c: Character) in c.isASCII && (c.isLetter || c.isNumber) }
        return latin(last) && latin(first) ? a + " " + b : a + b
    }
}

/// 实时字幕最近一段音频（16 kHz 单声道），按录音里的时间切出一句的音频交给定稿。
///
/// 时间和流式引擎算的一致：每块的时间当作它开头的位置，按样本数往后排，只在差得超过
/// `StreamingAudioTimeline.tolerance` 时重新对齐（同 `SherpaStreamingTranscriber`），所以按引擎给的句子时间切得准
struct RecentAudio {
    /// 只留最近这么多秒
    static let capacity: TimeInterval = 60

    private var samples: [Float] = []
    /// samples[0] 是从开始（或上次 reset）算起的第几个样本
    private var dropped = 0
    private var timeline = StreamingAudioTimeline()
    /// 已记进时间线的秒数（按每块原始音频的时长算，同引擎）
    private var fed: TimeInterval = 0
    /// 每块开头：从开始算起的样本号、录音里的时间
    private var chunks: [(sample: Int, time: TimeInterval)] = []
    private var resampler: (format: AVAudioFormat, converter: MonoResampler)?

    /// 送入一块。time 是录音里的时间（同送给流式引擎的）
    mutating func append(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) {
        if resampler?.format != buffer.format {
            resampler = MonoResampler(from: buffer.format).map { (buffer.format, $0) }
        }
        guard let converted = try? resampler?.converter.convert(buffer) else { return }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        timeline.record(duration: duration, at: time)
        let start = dropped + samples.count
        chunks.append((start, timeline.time(at: fed)))
        fed += duration
        samples += converted
        trim()
    }

    /// 录音里 start...end 秒的音频；开头已经被挤出缓存（或什么都没有）时为 nil。
    /// 开头早于开始（或恢复）后的第一块音频时（第一句往前补的边），从第一块切起
    func clip(from start: TimeInterval, to end: TimeInterval) -> [Float]? {
        guard var lower = index(at: start) else { return nil }
        if lower < dropped {
            guard dropped == 0 else { return nil }
            lower = 0
        }
        let upper = min(index(at: end) ?? lower, dropped + samples.count)
        guard upper > lower else { return nil }
        return Array(samples[(lower - dropped)..<(upper - dropped)])
    }

    mutating func reset() { self = RecentAudio() }

    /// 录音里的时间对应的样本号：落在哪块里，按那块的开头和样本数推算
    private func index(at time: TimeInterval) -> Int? {
        guard let chunk = chunks.last(where: { $0.time <= time }) ?? chunks.first else { return nil }
        return chunk.sample + Int(((time - chunk.time) * Double(MonoResampler.sampleRate)).rounded())
    }

    /// 超出 `capacity` 10 秒以上才丢一次，不每块都挪动整个缓存
    private mutating func trim() {
        let excess = samples.count - Int(Self.capacity) * MonoResampler.sampleRate
        guard excess >= 10 * MonoResampler.sampleRate else { return }
        samples.removeFirst(excess)
        dropped += excess
        // 留一块开头在缓存之前的，缓存最前面的样本仍能定位
        if let keep = chunks.lastIndex(where: { $0.sample <= dropped }), keep > 0 {
            chunks.removeFirst(keep)
        }
    }
}
