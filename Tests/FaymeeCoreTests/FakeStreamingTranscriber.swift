import AVFoundation
@testable import FaymeeCore

/// 假的一次流式转写：测试用 `emit` 发事件，记下收到的音频和结束方式
final class FakeTranscription: StreamingTranscription, @unchecked Sendable {
    let format: AVAudioFormat
    let hotwords: [String]
    let events: AsyncStream<StreamingTranscriptionEvent>
    private let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    private(set) var appended = 0
    private(set) var finished = false
    private(set) var cancelled = false

    init(format: AVAudioFormat, hotwords: [String]) {
        self.format = format
        self.hotwords = hotwords
        (events, continuation) = AsyncStream.makeStream()
    }

    func append(_ buffer: AVAudioPCMBuffer) { appended += 1 }
    /// 结束、取消时都不马上关事件流：测试还可以发迟到的事件，再 `end()`
    func finish() { finished = true }
    func cancel() { cancelled = true }

    func emit(_ event: StreamingTranscriptionEvent) { continuation.yield(event) }
    func volatile(_ text: String, _ start: TimeInterval) { emit(.volatile(text, start: start)) }
    func sentence(_ start: TimeInterval, _ end: TimeInterval, _ text: String) {
        emit(.sentence(.init(start: start, end: end, text: text)))
    }
    func fail(_ reason: String) {
        emit(.failed(reason))
        continuation.finish()
    }
    func end() { continuation.finish() }
}

/// 假引擎：记下每次开始的转写。prepareGate 不为 nil 时 prepare 等到测试放行
final class FakeStreamingTranscriber: StreamingTranscriber, @unchecked Sendable {
    private(set) var sessions: [FakeTranscription] = []
    private(set) var prepareCalls = 0
    var prepareErrors: [Error] = []
    var prepareProgress: Double?
    var prepareGate: CheckedContinuation<Void, Never>?
    var blocksPrepare = false

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        prepareCalls += 1
        if let prepareProgress { progress(prepareProgress) }
        if blocksPrepare { await withCheckedContinuation { prepareGate = $0 } }
        if !prepareErrors.isEmpty { throw prepareErrors.removeFirst() }
    }

    func start(format: AVAudioFormat, hotwords: [String]) -> any StreamingTranscription {
        let s = FakeTranscription(format: format, hotwords: hotwords)
        sessions.append(s)
        return s
    }

    var last: FakeTranscription { sessions.last! }
}
