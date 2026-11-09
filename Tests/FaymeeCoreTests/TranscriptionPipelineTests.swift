import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-10T02:00:00Z", strategy: .iso8601)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private struct EngineError: LocalizedError {
    var errorDescription: String? { "模型加载失败" }
}

/// 假引擎：返回固定句子，记录收到的参数。block 为 true 时 transcribe 一直等到被取消
private final class FakeTranscriber: Transcriber, @unchecked Sendable {
    var sentences: [TranscribedSentence] = []
    var prepareError: Error?
    var transcribeError: Error?
    var block = false
    private(set) var calls: [(audio: URL, hotwords: [String])] = []
    /// 每次进入 transcribe 时 yield 一次，测试据此知道转写已经开始
    let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation

    init(_ sentences: [TranscribedSentence] = []) {
        self.sentences = sentences
        (started, startedContinuation) = AsyncStream.makeStream()
    }

    func prepare(progress: @escaping (Double) -> Void) async throws {
        progress(1)
        if let prepareError { throw prepareError }
    }

    func transcribe(audio: URL, hotwords: [String],
                    progress: @escaping (Double) -> Void) async throws -> [TranscribedSentence] {
        calls.append((audio, hotwords))
        startedContinuation.yield()
        progress(0.5)
        if block { try await Task.sleep(for: .seconds(3600)) }
        if let transcribeError { throw transcribeError }
        return sentences
    }
}

/// 不理会取消的引擎：transcribe 挂起，直到测试手动给出结果
private final class SlowToCancelTranscriber: Transcriber, @unchecked Sendable {
    var continuation: CheckedContinuation<[TranscribedSentence], Error>?

    func prepare(progress: @escaping (Double) -> Void) async throws {}

    func transcribe(audio: URL, hotwords: [String],
                    progress: @escaping (Double) -> Void) async throws -> [TranscribedSentence] {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

/// 代替 AppModel：会议元数据的唯一写入者，记录转写状态的每次变化
@MainActor
private final class FakeHost: TranscriptionHost {
    let store: MeetingStore
    var meetings: [String: Meeting] = [:]
    private(set) var history: [String: [TranscriptionState.Status]] = [:]

    init(store: MeetingStore) { self.store = store }

    func meeting(_ id: String) -> Meeting? { meetings[id] }

    func setTranscription(_ state: TranscriptionState, for id: String) {
        guard var m = meetings[id] else { return }
        m.transcription = state
        meetings[id] = m
        history[id, default: []].append(state.status)
        try! store.save(m)
    }
}

@MainActor
private final class Fixture {
    let store = MeetingStore(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("FaymeeCoreTests-\(UUID().uuidString)", isDirectory: true))
    let host: FakeHost
    let engine: FakeTranscriber
    let pipeline: TranscriptionPipeline
    private(set) var finished: [(id: String, outcome: TranscriptionOutcome)] = []

    init(_ engine: FakeTranscriber = FakeTranscriber()) {
        host = FakeHost(store: store)
        self.engine = engine
        pipeline = TranscriptionPipeline(store: store, transcriber: engine, engine: "fake/1", host: host)
        pipeline.onFinish = { [unowned self] in self.finished.append(($0, $1)) }
    }

    deinit { try? FileManager.default.removeItem(at: store.root) }

    /// 一场 10 分钟、已整理好的会议，可带合盖空白
    @discardableResult
    func addMeeting(_ id: String = "m1", gaps: [Gap] = [], transcription: TranscriptionState? = nil) -> Meeting {
        var m = Meeting(id: id, title: "会议", startedAt: t0, endedAt: at(600), status: .done,
                        segments: [Segment(file: "0001.caf", startedAt: t0, sampleRate: 48000, channels: 1,
                                           device: "MacBook Pro 麦克风", deviceUID: "BuiltIn",
                                           offset: 0, duration: 600)],
                        recording: "recording.m4a", duration: 600)
        m.lidGaps = gaps
        m.transcription = transcription
        try! FileManager.default.createDirectory(at: store.directory(id), withIntermediateDirectories: true)
        try! store.save(m)
        host.meetings[id] = m
        return m
    }

    /// 等到队列空、没有正在转写的会议
    func drain() async throws {
        try await until { self.pipeline.isIdle }
    }

    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}

@MainActor @Suite struct TranscriptionPipelineTests {
    @Test func 转写整理好的会议写出带合盖空白的转写稿() async throws {
        let f = Fixture(FakeTranscriber([
            .init(start: 0, end: 5, text: "大家好"),
            .init(start: 295, end: 299, text: "合盖前最后一句"),
            .init(start: 320, end: 323, text: "合盖时的幻觉"),
            .init(start: 355, end: 370, text: "开盖后接着说"),
        ]))
        // 墙钟 300–360 秒合盖，录音里对应 300–360 秒
        let m = f.addMeeting(gaps: [Gap(start: at(300), end: at(360), reason: .lidClosed)])
        f.pipeline.hotwords = ["飞书", "王总"]

        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.engine == "fake/1")
        #expect(t.hotwords == ["飞书", "王总"])
        #expect(t.items == [
            .sentence(.init(id: "s1", start: 0, end: 5, text: "大家好")),
            .sentence(.init(id: "s2", start: 295, end: 299, text: "合盖前最后一句")),
            .gap(.init(start: 300, end: 360, reason: .lidClosed)),
            // 跨过空白结束的句子中点在空白外，保留
            .sentence(.init(id: "s3", start: 355, end: 370, text: "开盖后接着说")),
        ])
        #expect(f.engine.calls.map(\.hotwords) == [["飞书", "王总"]])
        #expect(f.engine.calls.map(\.audio) == [f.store.directory(m.id).appendingPathComponent("recording.m4a")])
        #expect(f.host.history[m.id] == [.queued, .running, .done])
        #expect(f.store.loadAll().first?.transcription == TranscriptionState(status: .done))
        #expect(f.finished.map(\.id) == [m.id])
    }

    @Test func 重新转写失败时保留旧稿并记下原因() async throws {
        let f = Fixture(FakeTranscriber([.init(start: 0, end: 5, text: "第一版")]))
        let m = f.addMeeting()
        f.pipeline.enqueue(m.id)
        try await f.drain()
        let url = f.store.directory(m.id).appendingPathComponent("transcript.json")
        let before = try Data(contentsOf: url)

        f.engine.transcribeError = EngineError()
        #expect(f.pipeline.enqueue(m.id))
        try await f.drain()

        #expect(try Data(contentsOf: url) == before)
        #expect(f.host.meetings[m.id]?.transcription == TranscriptionState(status: .failed, error: "模型加载失败"))
        #expect(f.host.history[m.id] == [.queued, .running, .done, .queued, .running, .failed])
        #expect(f.finished.last?.outcome == .failed("模型加载失败"))
    }

    @Test func 重新转写成功时整体替换旧稿() async throws {
        let f = Fixture(FakeTranscriber([.init(start: 0, end: 5, text: "第一版"), .init(start: 6, end: 8, text: "多出来的")]))
        let m = f.addMeeting()
        f.pipeline.enqueue(m.id)
        try await f.drain()

        f.engine.sentences = [.init(start: 1, end: 4, text: "第二版")]
        f.pipeline.hotwords = ["新词"]
        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.items == [.sentence(.init(id: "s1", start: 1, end: 4, text: "第二版"))])
        #expect(t.hotwords == ["新词"])
        #expect(f.host.meetings[m.id]?.transcription == TranscriptionState(status: .done))
    }

    @Test func 准备引擎失败时会议标为失败() async throws {
        let engine = FakeTranscriber([.init(start: 0, end: 5, text: "不该出现")])
        engine.prepareError = EngineError()
        let f = Fixture(engine)
        let m = f.addMeeting()

        f.pipeline.enqueue(m.id)
        try await f.drain()

        #expect(try f.store.loadTranscript(m.id) == nil)
        #expect(f.engine.calls.isEmpty)
        #expect(f.host.meetings[m.id]?.transcription == TranscriptionState(status: .failed, error: "模型加载失败"))
    }

    @Test func 一次转写一场并按入队先后进行() async throws {
        let engine = FakeTranscriber([.init(start: 0, end: 5, text: "嗯")])
        engine.block = true
        let f = Fixture(engine)
        f.addMeeting("m1")
        f.addMeeting("m2")
        f.addMeeting("m3")

        f.pipeline.enqueue("m1")
        f.pipeline.enqueue("m2")
        f.pipeline.enqueue("m3")
        // 重复入队忽略
        #expect(!f.pipeline.enqueue("m1"))
        #expect(!f.pipeline.enqueue("m2"))
        var started = f.engine.started.makeAsyncIterator()
        await started.next()

        #expect(f.pipeline.activeID == "m1")
        #expect(f.pipeline.queue == ["m2", "m3"])
        #expect(f.host.meetings["m2"]?.transcription?.status == .queued)

        f.engine.block = false
        f.pipeline.remove("m1")
        try await f.drain()
        #expect(f.engine.calls.map { $0.audio.deletingLastPathComponent().lastPathComponent } == ["m1", "m2", "m3"])
    }

    @Test func 暂停时取消正在进行的转写并放回队首_恢复后从头再转() async throws {
        let engine = FakeTranscriber([.init(start: 0, end: 5, text: "完整的一句")])
        engine.block = true
        let f = Fixture(engine)
        f.addMeeting("m1")
        f.addMeeting("m2")
        f.pipeline.enqueue("m1")
        f.pipeline.enqueue("m2")
        var started = f.engine.started.makeAsyncIterator()
        await started.next()

        // 开始录音
        f.pipeline.isSuspended = true
        #expect(f.pipeline.activeID == nil)
        #expect(f.pipeline.queue == ["m1", "m2"])
        #expect(f.host.meetings["m1"]?.transcription?.status == .queued)
        // 暂停期间入队的照样排在后面，但不开始
        f.addMeeting("m3")
        f.pipeline.enqueue("m3")
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.pipeline.activeID == nil)
        #expect(f.engine.calls.count == 1)
        #expect(try f.store.loadTranscript("m1") == nil)
        #expect(f.finished.isEmpty)

        // 录音结束、整理完成
        f.engine.block = false
        f.pipeline.isSuspended = false
        try await f.drain()

        #expect(f.engine.calls.map { $0.audio.deletingLastPathComponent().lastPathComponent } == ["m1", "m1", "m2", "m3"])
        #expect(f.host.history["m1"] == [.queued, .running, .queued, .running, .done])
        #expect(try f.store.loadTranscript("m1")?.sentences.map(\.text) == ["完整的一句"])
        #expect(f.finished.map(\.id) == ["m1", "m2", "m3"])
    }

    @Test func 转写中删除会议时取消且不写任何文件() async throws {
        let engine = FakeTranscriber([.init(start: 0, end: 5, text: "嗯")])
        engine.block = true
        let f = Fixture(engine)
        f.addMeeting("m1")
        f.addMeeting("m2")
        f.pipeline.enqueue("m1")
        f.pipeline.enqueue("m2")
        var started = f.engine.started.makeAsyncIterator()
        await started.next()
        let historyBefore = f.host.history["m1"]

        f.engine.block = false
        f.pipeline.remove("m1")
        try f.store.trash("m1")
        f.host.meetings["m1"] = nil
        try await f.drain()

        #expect(!FileManager.default.fileExists(atPath: f.store.directory("m1").path))
        #expect(f.host.history["m1"] == historyBefore)
        #expect(f.finished.map(\.id) == ["m2"])
    }

    @Test func 引擎不理会取消照常返回时结果作废() async throws {
        // 真实引擎可能取消得不及时：被取消后仍返回结果，这份结果不能写进已删除或已重新排队的会议
        let engine = SlowToCancelTranscriber()
        let f = Fixture()
        let pipeline = TranscriptionPipeline(store: f.store, transcriber: engine, engine: "slow", host: f.host)
        var finished: [String] = []
        pipeline.onFinish = { id, _ in finished.append(id) }
        f.addMeeting("m1")
        pipeline.enqueue("m1")
        try await f.until { engine.continuation != nil }

        pipeline.isSuspended = true
        engine.continuation?.resume(returning: [.init(start: 0, end: 1, text: "过期的结果")])
        try await Task.sleep(for: .milliseconds(50))

        #expect(try f.store.loadTranscript("m1") == nil)
        #expect(f.host.meetings["m1"]?.transcription?.status == .queued)
        #expect(pipeline.queue == ["m1"])
        #expect(finished.isEmpty)
    }

    @Test func 启动时把排队中和转写中的会议重新排队() async throws {
        let f = Fixture(FakeTranscriber([.init(start: 0, end: 5, text: "嗯")]))
        f.pipeline.isSuspended = true
        // endedAt 近似整理完成的先后；上次正在转写的排最前
        var queuedLate = f.addMeeting("queued-late", transcription: TranscriptionState(status: .queued))
        queuedLate.endedAt = at(900)
        f.host.meetings[queuedLate.id] = queuedLate
        let queuedEarly = f.addMeeting("queued-early", transcription: TranscriptionState(status: .queued))
        let running = f.addMeeting("running", transcription: TranscriptionState(status: .running))
        let done = f.addMeeting("done", transcription: TranscriptionState(status: .done))
        let failed = f.addMeeting("failed", transcription: TranscriptionState(status: .failed, error: "x"))
        let legacy = f.addMeeting("legacy")

        f.pipeline.restore([queuedLate, done, queuedEarly, legacy, running, failed])

        #expect(f.pipeline.queue == ["running", "queued-early", "queued-late"])
        f.pipeline.isSuspended = false
        try await f.drain()
        for id in ["running", "queued-early", "queued-late"] {
            #expect(f.host.meetings[id]?.transcription?.status == .done)
        }
        #expect(f.host.meetings["legacy"]?.transcription == nil)
        #expect(f.host.meetings["done"]?.transcription?.status == .done)
        #expect(f.host.meetings["failed"]?.transcription?.status == .failed)
    }

    @Test func 只转写整理好的会议() async throws {
        let f = Fixture()
        var m = f.addMeeting()
        m.status = .failed
        m.recording = nil
        f.host.meetings[m.id] = m

        #expect(!f.pipeline.enqueue(m.id))
        #expect(!f.pipeline.enqueue("不存在"))
        #expect(f.pipeline.isIdle)
        #expect(f.host.history.isEmpty)
    }
}
