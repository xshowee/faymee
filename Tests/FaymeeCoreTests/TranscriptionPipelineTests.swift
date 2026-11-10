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
    private(set) var calls = 0

    func prepare(progress: @escaping (Double) -> Void) async throws {}

    func transcribe(audio: URL, hotwords: [String],
                    progress: @escaping (Double) -> Void) async throws -> [TranscribedSentence] {
        try await withCheckedThrowingContinuation {
            continuation = $0
            calls += 1
        }
    }
}

/// 假区分说话人引擎：按脚本返回说话片段和声纹，记录收到的参数。block 为 true 时 diarize 一直等到被取消
private final class FakeDiarizer: SpeakerDiarizer, @unchecked Sendable {
    let engine = "fake/diarizer"
    let voiceprintModel = "fake/voiceprint"
    var result = DiarizationResult(segments: [], voiceprints: [:])
    var prepareError: Error?
    var diarizeError: Error?
    var block = false
    /// 在 diarize 返回前调用，模拟区分期间别处改了文件
    var onDiarize: (() -> Void)?
    private(set) var calls: [(audio: URL, speakerCount: Int?)] = []
    /// 每次进入 diarize 时 yield 一次
    let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation

    init(_ segments: [SpeakerSegment] = [], voiceprints: [Int: Voiceprint] = [:]) {
        result = DiarizationResult(segments: segments, voiceprints: voiceprints)
        (started, startedContinuation) = AsyncStream.makeStream()
    }

    func prepare(progress: @escaping (Double) -> Void) async throws {
        progress(1)
        if let prepareError { throw prepareError }
    }

    func diarize(audio: URL, speakerCount: Int?,
                 progress: @escaping (Double) -> Void) async throws -> DiarizationResult {
        calls.append((audio, speakerCount))
        startedContinuation.yield()
        progress(0.5)
        if block { try await Task.sleep(for: .seconds(3600)) }
        onDiarize?()
        if let diarizeError { throw diarizeError }
        return result
    }
}

/// 不理会取消的区分引擎：diarize 挂起，直到测试手动给出结果
private final class SlowToCancelDiarizer: SpeakerDiarizer, @unchecked Sendable {
    let engine = "slow/diarizer"
    let voiceprintModel = "slow/voiceprint"
    var continuation: CheckedContinuation<DiarizationResult, Error>?

    func prepare(progress: @escaping (Double) -> Void) async throws {}

    func diarize(audio: URL, speakerCount: Int?,
                 progress: @escaping (Double) -> Void) async throws -> DiarizationResult {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

/// 代替 AppModel：会议元数据的唯一写入者，记录转写状态的每次变化
@MainActor
private final class FakeHost: TranscriptionHost {
    let store: MeetingStore
    var meetings: [String: Meeting] = [:]
    private(set) var history: [String: [TranscriptionState.Status]] = [:]
    private(set) var diarizationHistory: [String: [DiarizationState.Status?]] = [:]

    init(store: MeetingStore) { self.store = store }

    func meeting(_ id: String) -> Meeting? { meetings[id] }

    func setTranscription(_ state: TranscriptionState, for id: String) {
        guard var m = meetings[id] else { return }
        m.transcription = state
        meetings[id] = m
        history[id, default: []].append(state.status)
        try! store.save(m)
    }

    func setDiarization(_ state: DiarizationState?, for id: String) {
        guard var m = meetings[id] else { return }
        m.diarization = state
        meetings[id] = m
        diarizationHistory[id, default: []].append(state?.status)
        try! store.save(m)
    }
}

@MainActor
private final class Fixture {
    let store = MeetingStore(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("FaymeeCoreTests-\(UUID().uuidString)", isDirectory: true))
    let host: FakeHost
    let engine: FakeTranscriber
    let diarizer: FakeDiarizer?
    let pipeline: TranscriptionPipeline
    private(set) var finished: [(id: String, outcome: TranscriptionOutcome)] = []

    init(_ engine: FakeTranscriber = FakeTranscriber(), diarizer: FakeDiarizer? = nil,
         voiceprints: VoiceprintStore? = nil) {
        host = FakeHost(store: store)
        self.engine = engine
        self.diarizer = diarizer
        pipeline = TranscriptionPipeline(store: store, transcriber: engine, engine: "fake/1", diarizer: diarizer,
                                         voiceprints: voiceprints, host: host)
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

    @Test func 修改热词只影响之后开始的转写() async throws {
        let f = Fixture(FakeTranscriber([.init(start: 0, end: 5, text: "嗯")]))
        f.addMeeting("m1")
        f.addMeeting("m2")
        f.pipeline.hotwords = ["旧词"]

        f.pipeline.enqueue("m1")
        f.pipeline.enqueue("m2")
        // m1 已开始、m2 还在排队时改热词
        f.pipeline.hotwords = ["新词"]
        try await f.drain()

        #expect(f.engine.calls.map(\.hotwords) == [["旧词"], ["新词"]])
        #expect(try f.store.loadTranscript("m1")?.hotwords == ["旧词"])
        #expect(try f.store.loadTranscript("m2")?.hotwords == ["新词"])
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

    @Test func 取消后引擎还没退出时不算空闲_下一场等它退出再开始() async throws {
        let engine = SlowToCancelTranscriber()
        let f = Fixture()
        let pipeline = TranscriptionPipeline(store: f.store, transcriber: engine, engine: "slow", host: f.host)
        var idle: [Bool] = []
        pipeline.onIdleChange = { idle.append($0) }
        f.addMeeting("m1")
        f.addMeeting("m2")
        pipeline.enqueue("m1")
        pipeline.enqueue("m2")
        try await f.until { engine.continuation != nil }
        let first = engine.continuation

        pipeline.remove("m1")
        pipeline.remove("m2")
        try await Task.sleep(for: .milliseconds(50))
        #expect(!pipeline.isIdle)
        #expect(idle == [false])

        f.addMeeting("m3")
        pipeline.enqueue("m3")
        try await Task.sleep(for: .milliseconds(50))
        // 同一时间只用一次引擎
        #expect(engine.calls == 1)
        #expect(pipeline.activeID == "m3")

        first?.resume(returning: [])
        try await f.until { engine.calls == 2 }
        engine.continuation?.resume(returning: [.init(start: 0, end: 1, text: "嗯")])
        try await f.until { pipeline.isIdle }
        #expect(idle == [false, true])
        #expect(f.host.meetings["m3"]?.transcription?.status == .done)
        #expect(try f.store.loadTranscript("m1") == nil)
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

private let vp1 = Voiceprint([1, 0, 0])
private let vp2 = Voiceprint([0, 1, 0])

/// 两人对话：引擎编号 7 先开口、编号 3 后开口
private let twoPeople = [
    TranscribedSentence(start: 0, end: 5, text: "我们开始吧"),
    TranscribedSentence(start: 6, end: 10, text: "好的我先说"),
    TranscribedSentence(start: 11, end: 15, text: "你接着讲"),
    TranscribedSentence(start: 30, end: 33, text: "没人说话时的噪声"),
]
private let twoPeopleSegments = [
    SpeakerSegment(start: 0, end: 5.5, speaker: 7),
    // 第二句横跨两人：编号 3 占 3 秒，编号 7 占 1 秒，归给 3
    SpeakerSegment(start: 5.5, end: 7, speaker: 7),
    SpeakerSegment(start: 7, end: 10, speaker: 3),
    SpeakerSegment(start: 11, end: 15, speaker: 7),
]

/// v0.3 写出的转写稿：没有说话人，第二句被人工改过。createdAt 取整秒，同从磁盘读回的值
private func legacyTranscript(createdAt: Date = at(700)) -> Transcript {
    Transcript(engine: "fake/1", createdAt: createdAt, hotwords: ["王总"], items: [
        .sentence(.init(id: "s1", start: 0, end: 5, text: "我们开始吧")),
        .sentence(.init(id: "s2", start: 6, end: 10, text: "好的我先说（改过）", original: "好的我先说")),
        .gap(.init(start: 16, end: 20, reason: .lidClosed)),
        .sentence(.init(id: "s5", start: 11, end: 15, text: "你接着讲")),
    ])
}

extension Fixture {
    /// 一场已转写好（v0.3 及更早、没区分过说话人）的会议
    @discardableResult
    func addTranscribedMeeting(_ id: String = "m1", transcript: Transcript = legacyTranscript()) -> Meeting {
        addMeeting(id, transcription: TranscriptionState(status: .done))
        try! store.saveTranscript(transcript, for: id)
        return host.meetings[id]!
    }
}

@MainActor @Suite struct DiarizationStepTests {
    @Test func 完整转写时区分说话人并写进转写稿() async throws {
        let f = Fixture(FakeTranscriber(twoPeople), diarizer: FakeDiarizer(twoPeopleSegments, voiceprints: [7: vp1, 3: vp2]))
        let m = f.addMeeting()

        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.sentences.map(\.speaker) == ["spk1", "spk2", "spk1", nil])
        #expect(t.sentences.map(\.text) == ["我们开始吧", "好的我先说", "你接着讲", "没人说话时的噪声"])
        let d = try #require(t.diarization)
        #expect(d.engine == "fake/diarizer")
        #expect(d.voiceprintModel == "fake/voiceprint")
        #expect(d.speakers.map(\.id) == ["spk1", "spk2"])
        #expect(d.speakers.map(\.voiceprint) == [vp1, vp2])
        #expect(d.speakers.map(\.speechDuration) == [11, 3])
        #expect(f.diarizer?.calls.map(\.speakerCount) == [nil])
        #expect(f.diarizer?.calls.map(\.audio) == [f.store.directory(m.id).appendingPathComponent("recording.m4a")])
        #expect(f.host.meetings[m.id]?.transcription == TranscriptionState(status: .done))
        #expect(f.host.meetings[m.id]?.diarization == DiarizationState(status: .done))
        #expect(f.store.loadAll().first?.diarization == DiarizationState(status: .done))
        #expect(f.finished.map(\.id) == [m.id])
    }

    @Test func 区分失败时转写稿照常保存_说话人状态记下原因() async throws {
        let diarizer = FakeDiarizer(twoPeopleSegments)
        diarizer.diarizeError = EngineError()
        let f = Fixture(FakeTranscriber(twoPeople), diarizer: diarizer)
        let m = f.addMeeting()

        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.sentences.map(\.text) == ["我们开始吧", "好的我先说", "你接着讲", "没人说话时的噪声"])
        #expect(t.diarization == nil)
        #expect(t.sentences.allSatisfy { $0.speaker == nil })
        #expect(f.host.meetings[m.id]?.transcription == TranscriptionState(status: .done))
        #expect(f.host.meetings[m.id]?.diarization == DiarizationState(status: .failed, error: "模型加载失败"))
        #expect(f.finished.map(\.id) == [m.id])
    }

    @Test func 准备区分引擎失败也只让说话人失败() async throws {
        let diarizer = FakeDiarizer(twoPeopleSegments)
        diarizer.prepareError = EngineError()
        let f = Fixture(FakeTranscriber(twoPeople), diarizer: diarizer)
        let m = f.addMeeting()

        f.pipeline.enqueue(m.id)
        try await f.drain()

        #expect(try f.store.loadTranscript(m.id)?.sentences.count == 4)
        #expect(f.host.meetings[m.id]?.transcription == TranscriptionState(status: .done))
        #expect(f.host.meetings[m.id]?.diarization == DiarizationState(status: .failed, error: "模型加载失败"))
    }

    @Test func 关闭开关时不调用区分引擎_说话人状态不变() async throws {
        let f = Fixture(FakeTranscriber(twoPeople), diarizer: FakeDiarizer(twoPeopleSegments))
        let m = f.addMeeting()
        f.host.setDiarization(DiarizationState(status: .failed, error: "上次的原因"), for: m.id)
        f.pipeline.diarizes = false

        f.pipeline.enqueue(m.id)
        try await f.drain()

        #expect(f.diarizer?.calls.isEmpty == true)
        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.diarization == nil)
        #expect(t.sentences.count == 4)
        #expect(f.host.meetings[m.id]?.diarization == DiarizationState(status: .failed, error: "上次的原因"))
        #expect(f.host.diarizationHistory[m.id] == [.failed])
    }

    @Test func 没有区分引擎时跳过这一步_不算失败() async throws {
        let f = Fixture(FakeTranscriber(twoPeople))
        let m = f.addMeeting()

        f.pipeline.enqueue(m.id)
        try await f.drain()

        #expect(try f.store.loadTranscript(m.id)?.diarization == nil)
        #expect(f.host.meetings[m.id]?.transcription == TranscriptionState(status: .done))
        #expect(f.host.meetings[m.id]?.diarization == nil)
    }

    @Test func 只区分说话人只写说话人_句子id文字修改记录都不动() async throws {
        let f = Fixture(diarizer: FakeDiarizer(twoPeopleSegments, voiceprints: [7: vp1, 3: vp2]))
        let m = f.addTranscribedMeeting()

        #expect(f.pipeline.enqueueDiarization(m.id, speakerCount: 2))
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.items == [
            .sentence(.init(id: "s1", start: 0, end: 5, text: "我们开始吧", speaker: "spk1")),
            .sentence(.init(id: "s2", start: 6, end: 10, text: "好的我先说（改过）", original: "好的我先说", speaker: "spk2")),
            .gap(.init(start: 16, end: 20, reason: .lidClosed)),
            .sentence(.init(id: "s5", start: 11, end: 15, text: "你接着讲", speaker: "spk1")),
        ])
        #expect(t.createdAt == at(700))
        #expect(t.engine == "fake/1")
        #expect(t.hotwords == ["王总"])
        #expect(t.textHash == legacyTranscript().textHash)
        #expect(t.speakers.map(\.id) == ["spk1", "spk2"])
        #expect(f.diarizer?.calls.map(\.speakerCount) == [2])
        #expect(f.engine.calls.isEmpty)
        #expect(f.host.history[m.id] == nil)
        #expect(f.host.meetings[m.id]?.transcription == TranscriptionState(status: .done))
        #expect(f.host.diarizationHistory[m.id] == [.queued, .running, .done])
        // 不是转写完成：不回调（App 据此自动生成纪要、发“转写完成”通知）
        #expect(f.finished.isEmpty)
    }

    @Test func 只区分说话人期间改了文字_结束时保留新文字() async throws {
        let diarizer = FakeDiarizer(twoPeopleSegments)
        let f = Fixture(diarizer: diarizer)
        let m = f.addTranscribedMeeting()
        var edited = legacyTranscript()
        edited.items[0] = .sentence(.init(id: "s1", start: 0, end: 5, text: "区分期间改的", original: "我们开始吧"))
        let store = f.store
        diarizer.onDiarize = { [edited] in try! store.saveTranscript(edited, for: m.id) }

        f.pipeline.enqueueDiarization(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.sentences.map(\.text) == ["区分期间改的", "好的我先说（改过）", "你接着讲"])
        #expect(t.sentences.map(\.original) == ["我们开始吧", "好的我先说", nil])
        #expect(t.sentences.map(\.speaker) == ["spk1", "spk2", "spk1"])
    }

    @Test func 只区分说话人期间转写稿被重新转写时丢弃结果() async throws {
        let diarizer = FakeDiarizer(twoPeopleSegments)
        let f = Fixture(diarizer: diarizer)
        let m = f.addTranscribedMeeting()
        // 引擎读完快照、还没返回时，转写稿换成了另一份
        let store = f.store
        diarizer.onDiarize = { try! store.saveTranscript(legacyTranscript(createdAt: at(1000)), for: m.id) }

        f.pipeline.enqueueDiarization(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t == legacyTranscript(createdAt: at(1000)))
        #expect(f.host.meetings[m.id]?.diarization?.status == .failed)
        #expect(f.host.meetings[m.id]?.transcription == TranscriptionState(status: .done))
    }

    @Test func 只区分说话人需要已有转写稿() async throws {
        let f = Fixture(diarizer: FakeDiarizer(twoPeopleSegments))
        let fresh = f.addMeeting("fresh")
        f.addMeeting("transcribing", transcription: TranscriptionState(status: .done))

        #expect(!f.pipeline.enqueueDiarization(fresh.id))
        // 状态是完成但转写稿文件不在
        #expect(!f.pipeline.enqueueDiarization("transcribing"))
        #expect(!f.pipeline.enqueueDiarization("不存在"))
        #expect(f.pipeline.isIdle)
        #expect(f.host.diarizationHistory.isEmpty)
    }

    @Test func 重新区分时新说话人按句子重合沿用旧名字_每个名字最多给一个() async throws {
        // 原来：张三说 s1、s3、s4，李四说 s2。张三是声纹认出的
        let old = Transcript(engine: "fake/1", createdAt: at(700), hotwords: [], items: [
            .sentence(.init(id: "s1", start: 0, end: 5, text: "一", speaker: "spk1")),
            .sentence(.init(id: "s2", start: 6, end: 10, text: "二", speaker: "spk2")),
            .sentence(.init(id: "s3", start: 11, end: 15, text: "三", speaker: "spk1")),
            .sentence(.init(id: "s4", start: 16, end: 20, text: "四", speaker: "spk1", originalSpeaker: .init(speaker: "spk2"))),
        ], diarization: Diarization(engine: "fake/diarizer", voiceprintModel: "fake/voiceprint",
                                    speakersCreatedAt: at(800), speakers: [
            Speaker(id: "spk1", name: "张三", nameSource: .voiceprint, personID: "p1", voiceprint: vp1, speechDuration: 13),
            Speaker(id: "spk2", name: "李四", nameSource: .user, voiceprint: vp2, speechDuration: 4),
        ]))
        // 重新区分：s1 归一个新人（新 spk1），s2–s4 归另一个人（新 spk2）。
        // 新 spk2 与张三重合 2 句、与李四 1 句；新 spk1 只与张三重合 1 句
        let f = Fixture(diarizer: FakeDiarizer([
            SpeakerSegment(start: 0, end: 5, speaker: 0),
            SpeakerSegment(start: 6, end: 20, speaker: 1),
        ]))
        let m = f.addTranscribedMeeting(transcript: old)

        f.pipeline.enqueueDiarization(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.sentences.map(\.speaker) == ["spk1", "spk2", "spk2", "spk2"])
        #expect(t.sentences.allSatisfy { $0.originalSpeaker == nil })
        #expect(t.speakers.map(\.id) == ["spk1", "spk2"])
        // 张三给了重合最多的新 spk2，连同来源和声纹库关联；李四只和已被张三占走的 spk2 重合，不给别人
        #expect(t.speakers.map(\.name) == [nil, "张三"])
        #expect(t.speakers.map(\.nameSource) == [nil, .voiceprint])
        #expect(t.speakers.map(\.personID) == [nil, "p1"])
    }

    @Test func 重新转写时按时间重合沿用旧名字() async throws {
        let f = Fixture(FakeTranscriber(twoPeople), diarizer: FakeDiarizer(twoPeopleSegments))
        let m = f.addMeeting()
        f.pipeline.enqueue(m.id)
        try await f.drain()
        var first = try #require(try f.store.loadTranscript(m.id))
        first.diarization?.speakers[0].name = "张三"
        first.diarization?.speakers[0].nameSource = .user
        first.diarization?.speakers[1].name = "李四"
        first.diarization?.speakers[1].nameSource = .user
        try f.store.saveTranscript(first, for: m.id)

        // 重新转写：句子切法、编号都变了。这次李四（引擎编号 3）先开口，成了新 spk1；
        // 他的第一句与张三的旧句子重合，但张三与新 spk2 重合更多
        f.engine.sentences = [
            .init(start: 0, end: 0.5, text: "嗯"),
            .init(start: 1, end: 5, text: "开始吧"),
            .init(start: 6, end: 10, text: "好的我先说"),
            .init(start: 11, end: 15, text: "你接着讲"),
        ]
        f.diarizer?.result = DiarizationResult(segments: [
            SpeakerSegment(start: 0, end: 0.5, speaker: 3),
            SpeakerSegment(start: 1, end: 5, speaker: 7),
            SpeakerSegment(start: 6, end: 10, speaker: 3),
            SpeakerSegment(start: 11, end: 15, speaker: 7),
        ], voiceprints: [:])
        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.sentences.map(\.speaker) == ["spk1", "spk2", "spk1", "spk2"])
        #expect(t.speakers.map(\.name) == ["李四", "张三"])
    }

    @Test func 区分说话人中开始录音时取消并放回队首_恢复后从头再转() async throws {
        let diarizer = FakeDiarizer(twoPeopleSegments)
        diarizer.block = true
        let f = Fixture(FakeTranscriber(twoPeople), diarizer: diarizer)
        let m = f.addMeeting()
        f.pipeline.enqueue(m.id)
        var started = diarizer.started.makeAsyncIterator()
        await started.next()
        try await f.until { f.pipeline.activity(for: m.id) == .diarizing(0.5) }

        f.pipeline.isSuspended = true
        #expect(f.pipeline.activeID == nil)
        #expect(f.pipeline.queue == [m.id])
        #expect(f.host.meetings[m.id]?.transcription?.status == .queued)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try f.store.loadTranscript(m.id) == nil)
        #expect(f.finished.isEmpty)

        diarizer.block = false
        f.pipeline.isSuspended = false
        try await f.drain()

        #expect(f.engine.calls.count == 2)
        #expect(diarizer.calls.count == 2)
        #expect(f.host.history[m.id] == [.queued, .running, .queued, .running, .done])
        #expect(f.host.diarizationHistory[m.id] == [.done])
        #expect(try f.store.loadTranscript(m.id)?.speakers.count == 2)
        #expect(f.finished.map(\.id) == [m.id])
    }

    @Test func 只区分说话人中开始录音时放回队首_不碰转写状态() async throws {
        let diarizer = FakeDiarizer(twoPeopleSegments)
        diarizer.block = true
        let f = Fixture(diarizer: diarizer)
        let m = f.addTranscribedMeeting()
        f.addTranscribedMeeting("m2")
        f.pipeline.enqueueDiarization(m.id, speakerCount: 3)
        f.pipeline.enqueueDiarization("m2")
        var started = diarizer.started.makeAsyncIterator()
        await started.next()

        f.pipeline.isSuspended = true
        #expect(f.pipeline.queue == [m.id, "m2"])
        #expect(f.host.meetings[m.id]?.diarization?.status == .queued)
        #expect(f.host.meetings[m.id]?.transcription == TranscriptionState(status: .done))

        diarizer.block = false
        f.pipeline.isSuspended = false
        try await f.drain()

        // 人数跟着任务放回队首
        #expect(diarizer.calls.map(\.speakerCount) == [3, 3, nil])
        #expect(f.host.diarizationHistory[m.id] == [.queued, .running, .queued, .running, .done])
        #expect(f.host.history[m.id] == nil)
        #expect(f.engine.calls.isEmpty)
        #expect(try f.store.loadTranscript(m.id)?.speakers.count == 2)
    }

    @Test func 只区分说话人中删除会议时取消且不写任何文件() async throws {
        let diarizer = FakeDiarizer(twoPeopleSegments)
        diarizer.block = true
        let f = Fixture(diarizer: diarizer)
        let m = f.addTranscribedMeeting()
        f.addTranscribedMeeting("m2")
        f.pipeline.enqueueDiarization(m.id)
        f.pipeline.enqueueDiarization("m2")
        var started = diarizer.started.makeAsyncIterator()
        await started.next()
        let historyBefore = f.host.diarizationHistory[m.id]

        diarizer.block = false
        f.pipeline.remove(m.id)
        try f.store.trash(m.id)
        f.host.meetings[m.id] = nil
        try await f.drain()

        #expect(!FileManager.default.fileExists(atPath: f.store.directory(m.id).path))
        #expect(f.host.diarizationHistory[m.id] == historyBefore)
        #expect(f.host.meetings["m2"]?.diarization?.status == .done)
    }

    @Test func 区分引擎不理会取消照常返回时结果作废() async throws {
        let diarizer = SlowToCancelDiarizer()
        let f = Fixture()
        let pipeline = TranscriptionPipeline(store: f.store, transcriber: f.engine, engine: "fake/1",
                                             diarizer: diarizer, host: f.host)
        let m = f.addTranscribedMeeting()
        let before = try f.store.loadTranscript(m.id)
        pipeline.enqueueDiarization(m.id)
        try await f.until { diarizer.continuation != nil }

        pipeline.isSuspended = true
        diarizer.continuation?.resume(returning: DiarizationResult(segments: twoPeopleSegments, voiceprints: [:]))
        try await Task.sleep(for: .milliseconds(50))

        #expect(try f.store.loadTranscript(m.id) == before)
        #expect(f.host.meetings[m.id]?.diarization?.status == .queued)
        #expect(pipeline.queue == [m.id])
    }

    @Test func 区分说话人期间转写不算空闲() async throws {
        let diarizer = FakeDiarizer(twoPeopleSegments)
        diarizer.block = true
        let f = Fixture(diarizer: diarizer)
        var idle: [Bool] = []
        f.pipeline.onIdleChange = { idle.append($0) }
        let m = f.addTranscribedMeeting()
        f.pipeline.enqueueDiarization(m.id)
        var started = diarizer.started.makeAsyncIterator()
        await started.next()

        #expect(!f.pipeline.isIdle)
        #expect(idle == [false])
        diarizer.block = false
        f.pipeline.remove(m.id)
        f.addTranscribedMeeting("m2")
        f.pipeline.enqueueDiarization("m2")
        try await f.drain()
        #expect(idle == [false, true])
    }

    @Test func 排队只区分说话人时又点重新转写_改成完整转写() async throws {
        let f = Fixture(FakeTranscriber(twoPeople), diarizer: FakeDiarizer(twoPeopleSegments))
        f.pipeline.isSuspended = true
        let m = f.addTranscribedMeeting()
        #expect(f.pipeline.enqueueDiarization(m.id))
        #expect(f.pipeline.enqueue(m.id))
        // 已在排队完整转写：完整转写里会区分，不再单独排
        #expect(!f.pipeline.enqueueDiarization(m.id))
        #expect(f.pipeline.queue == [m.id])

        f.pipeline.isSuspended = false
        try await f.drain()

        #expect(f.engine.calls.count == 1)
        #expect(try f.store.loadTranscript(m.id)?.sentences.count == 4)
        #expect(f.host.meetings[m.id]?.diarization?.status == .done)
    }

    @Test func 开关关闭时完整转写不留下排队中的说话人状态() async throws {
        let f = Fixture(FakeTranscriber(twoPeople), diarizer: FakeDiarizer(twoPeopleSegments))
        f.pipeline.isSuspended = true
        let m = f.addTranscribedMeeting()
        f.pipeline.enqueueDiarization(m.id)
        f.pipeline.enqueue(m.id)
        f.pipeline.diarizes = false

        f.pipeline.isSuspended = false
        try await f.drain()

        #expect(f.diarizer?.calls.isEmpty == true)
        // 排队中的说话人状态不会再有任务来完成它，否则下次启动会被当成只区分说话人的任务恢复
        #expect(f.host.meetings[m.id]?.diarization == nil)
    }

    /// 只区分说话人中退出，再在没有区分引擎（模型缺失、校验失败）时启动：任务恢复不了，
    /// 说话人状态按转写稿如实落定，不能一直停在排队、进行中（那样说话人编辑、重新转写、重试都被禁用）
    @Test func 启动时恢复不了只区分说话人的任务_说话人状态按转写稿落定() async throws {
        let f = Fixture(FakeTranscriber(twoPeople))
        let legacy = f.addTranscribedMeeting("legacy")
        f.host.setDiarization(DiarizationState(status: .running), for: legacy.id)
        var diarized = legacyTranscript()
        diarized.items[0] = .sentence(.init(id: "s1", start: 0, end: 5, text: "我们开始吧", speaker: "spk1"))
        diarized.diarization = Diarization(engine: "fake/diarizer", voiceprintModel: "fake/voiceprint",
                                           speakersCreatedAt: at(800), speakers: [
            Speaker(id: "spk1", name: "张三", nameSource: .user, voiceprint: vp1, speechDuration: 5),
        ])
        let rediarize = f.addTranscribedMeeting("rediarize", transcript: diarized)
        f.host.setDiarization(DiarizationState(status: .queued), for: rediarize.id)

        f.pipeline.restore([legacy, rediarize].map { f.host.meetings[$0.id]! })
        try await f.drain()

        // 旧会议从没区分成：退回没有说话人；重新区分没跑成：旧说话人还在
        #expect(f.host.meetings[legacy.id]?.diarization == nil)
        #expect(f.host.meetings[rediarize.id]?.diarization == DiarizationState(status: .done))
        #expect(f.store.loadAll().first { $0.id == legacy.id }?.diarization == nil)
        #expect(try f.store.loadTranscript(rediarize.id) == diarized)
    }

    @Test func 启动时恢复只区分说话人的任务() async throws {
        let f = Fixture(FakeTranscriber(twoPeople), diarizer: FakeDiarizer(twoPeopleSegments))
        f.pipeline.isSuspended = true
        let queued = f.addTranscribedMeeting("diarize-queued")
        f.host.setDiarization(DiarizationState(status: .queued), for: queued.id)
        var running = f.addTranscribedMeeting("diarize-running")
        running.endedAt = at(900)
        f.host.meetings[running.id] = running
        f.host.setDiarization(DiarizationState(status: .running), for: running.id)
        // 完整转写在区分说话人那一步时退出：转写和说话人状态都不是完成，按完整转写恢复
        f.addMeeting("full", transcription: TranscriptionState(status: .running))
        f.host.setDiarization(DiarizationState(status: .done), for: "full")
        let done = f.addTranscribedMeeting("done")
        f.host.setDiarization(DiarizationState(status: .done), for: done.id)
        let failed = f.addTranscribedMeeting("failed")
        f.host.setDiarization(DiarizationState(status: .failed, error: "x"), for: failed.id)

        f.pipeline.restore(["diarize-queued", "done", "full", "diarize-running", "failed"].map { f.host.meetings[$0]! })

        // 上次正在进行的排最前（不分任务种类），其余按结束时间
        #expect(f.pipeline.queue == ["full", "diarize-running", "diarize-queued"])
        f.pipeline.isSuspended = false
        try await f.drain()

        #expect(f.engine.calls.map { $0.audio.deletingLastPathComponent().lastPathComponent } == ["full"])
        #expect(f.diarizer?.calls.map { $0.audio.deletingLastPathComponent().lastPathComponent }
            == ["full", "diarize-running", "diarize-queued"])
        for id in ["diarize-queued", "diarize-running", "full"] {
            #expect(f.host.meetings[id]?.diarization?.status == .done)
            #expect(f.host.meetings[id]?.transcription?.status == .done)
        }
        #expect(f.host.meetings["failed"]?.diarization?.status == .failed)
    }
}


/// 声纹库里的一个人：一个样本，声纹模型默认与假引擎相同
private func person(_ id: String, _ name: String, _ vector: [Float],
                    model: String = "fake/voiceprint") -> VoiceprintPerson {
    VoiceprintPerson(id: id, name: name, voiceprintModel: model, samples: [
        VoiceprintSample(voiceprint: Voiceprint(vector), meetingID: "old", speechDuration: 30, addedAt: t0),
    ])
}

/// 临时目录里的声纹库，与会议存储分开放
@MainActor
private final class Library {
    let store = VoiceprintStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("FaymeeVoiceprints-\(UUID().uuidString)/voiceprints.json"))

    init(_ people: [VoiceprintPerson]) {
        try! store.save(VoiceprintLibrary(people: people))
    }

    deinit { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
}

@MainActor @Suite struct VoiceprintRecognitionTests {
    @Test func 完整转写后认出声纹库里的人并写上名字() async throws {
        let library = Library([person("p1", "张三", [0.9, 0.1, 0])])
        let f = Fixture(FakeTranscriber(twoPeople), diarizer: FakeDiarizer(twoPeopleSegments, voiceprints: [7: vp1, 3: vp2]),
                        voiceprints: library.store)
        let m = f.addMeeting()

        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.speakers.map(\.id) == ["spk1", "spk2"])
        #expect(t.speakers.map(\.name) == ["张三", nil])
        #expect(t.speakers.map(\.nameSource) == [.voiceprint, nil])
        #expect(t.speakers.map(\.personID) == ["p1", nil])
        #expect(f.host.meetings[m.id]?.diarization == DiarizationState(status: .done))
        // 识别只读声纹库，不加样本
        #expect(try library.store.load() == VoiceprintLibrary(people: [person("p1", "张三", [0.9, 0.1, 0])]))
    }

    /// 区分过一次的转写稿：spk1 说 s1，spk2 说 s2、s3
    private func diarizedTranscript(_ speakers: [Speaker]) -> Transcript {
        Transcript(engine: "fake/1", createdAt: at(700), hotwords: [], items: [
            .sentence(.init(id: "s1", start: 0, end: 5, text: "一", speaker: "spk1")),
            .sentence(.init(id: "s2", start: 6, end: 10, text: "二", speaker: "spk2")),
            .sentence(.init(id: "s3", start: 11, end: 15, text: "三", speaker: "spk2")),
        ], diarization: Diarization(engine: "fake/diarizer", voiceprintModel: "fake/voiceprint",
                                    speakersCreatedAt: at(800), speakers: speakers))
    }

    @Test func 只区分说话人后认出声纹库里的人() async throws {
        let library = Library([person("p1", "张三", [0, 1, 0])])
        let f = Fixture(diarizer: FakeDiarizer(twoPeopleSegments, voiceprints: [7: vp1, 3: vp2]),
                        voiceprints: library.store)
        let m = f.addTranscribedMeeting()

        f.pipeline.enqueueDiarization(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.sentences.map(\.speaker) == ["spk1", "spk2", "spk1"])
        #expect(t.speakers.map(\.name) == [nil, "张三"])
        #expect(t.speakers.map(\.nameSource) == [nil, .voiceprint])
        #expect(t.speakers.map(\.personID) == [nil, "p1"])
        #expect(f.host.meetings[m.id]?.diarization == DiarizationState(status: .done))
    }

    @Test func 沿用来的声纹名字被别的说话人认走时清掉_不出现两个同名的人() async throws {
        // 原来 spk1（s1）是声纹认出的张三。重新区分后 s1 归新 spk1，沿用张三；
        // 但声纹库认为新 spk2（s2、s3）才是张三
        let old = diarizedTranscript([
            Speaker(id: "spk1", name: "张三", nameSource: .voiceprint, personID: "p1", voiceprint: vp2, speechDuration: 5),
            Speaker(id: "spk2", voiceprint: vp1, speechDuration: 8),
        ])
        let library = Library([person("p1", "张三", [1, 0, 0])])
        let f = Fixture(diarizer: FakeDiarizer([
            SpeakerSegment(start: 0, end: 5, speaker: 0),
            SpeakerSegment(start: 6, end: 15, speaker: 1),
        ], voiceprints: [0: vp2, 1: vp1]), voiceprints: library.store)
        let m = f.addTranscribedMeeting(transcript: old)

        f.pipeline.enqueueDiarization(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.speakers.map(\.id) == ["spk1", "spk2"])
        #expect(t.speakers.map(\.name) == [nil, "张三"])
        #expect(t.speakers.map(\.nameSource) == [nil, .voiceprint])
        #expect(t.speakers.map(\.personID) == [nil, "p1"])
    }

    @Test func 沿用来的声纹名字没被别人认走时保留() async throws {
        // 张三已从声纹库删除：重新区分不改写已经显示的名字
        let old = diarizedTranscript([
            Speaker(id: "spk1", name: "张三", nameSource: .voiceprint, personID: "p1", voiceprint: vp1, speechDuration: 5),
            Speaker(id: "spk2", voiceprint: vp2, speechDuration: 8),
        ])
        let library = Library([])
        let f = Fixture(diarizer: FakeDiarizer([
            SpeakerSegment(start: 0, end: 5, speaker: 0),
            SpeakerSegment(start: 6, end: 15, speaker: 1),
        ], voiceprints: [0: vp1, 1: vp2]), voiceprints: library.store)
        let m = f.addTranscribedMeeting(transcript: old)

        f.pipeline.enqueueDiarization(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.speakers.map(\.name) == ["张三", nil])
        #expect(t.speakers.map(\.nameSource) == [.voiceprint, nil])
        #expect(t.speakers.map(\.personID) == ["p1", nil])
    }

    /// 完整转写一场两人对话，返回写盘的说话人
    private func transcribe(voiceprints: [Int: Voiceprint], library: Library,
                            threshold: Float? = nil) async throws -> [Speaker] {
        let f = Fixture(FakeTranscriber(twoPeople), diarizer: FakeDiarizer(twoPeopleSegments, voiceprints: voiceprints),
                        voiceprints: library.store)
        if let threshold { f.pipeline.voiceprintThreshold = threshold }
        let m = f.addMeeting()
        f.pipeline.enqueue(m.id)
        try await f.drain()
        #expect(f.host.meetings[m.id]?.diarization == DiarizationState(status: .done))
        return try #require(try f.store.loadTranscript(m.id)).speakers
    }

    @Test func 一个人只认给一个说话人_给最像的那个() async throws {
        // 两个说话人都像张三，spk2 更像
        let library = Library([person("p1", "张三", [0.9, 0.2, 0])])
        let speakers = try await transcribe(voiceprints: [7: Voiceprint([1, 0, 0]), 3: Voiceprint([0.9, 0.2, 0])],
                                            library: library)

        #expect(speakers.map(\.name) == [nil, "张三"])
        #expect(speakers.map(\.personID) == [nil, "p1"])
    }

    @Test func 相似度不超过阈值时不认() async throws {
        // 与 [1, 0, 0] 的余弦相似度约 0.707，低于默认阈值 0.75
        let library = Library([person("p1", "张三", [1, 1, 0])])
        let speakers = try await transcribe(voiceprints: [7: vp1, 3: vp2], library: library)

        #expect(speakers.map(\.name) == [nil, nil])
        #expect(speakers.map(\.nameSource) == [nil, nil])
        #expect(speakers.map(\.personID) == [nil, nil])
    }

    @Test func 阈值可以调低() async throws {
        let library = Library([person("p1", "张三", [1, 1, 0])])
        let speakers = try await transcribe(voiceprints: [7: vp1, 3: Voiceprint([0, 0, 1])], library: library,
                                            threshold: 0.7)

        #expect(speakers.map(\.name) == ["张三", nil])
    }

    @Test func 声纹模型不同的人不认() async throws {
        let library = Library([person("p1", "张三", [1, 0, 0], model: "old/voiceprint")])
        let speakers = try await transcribe(voiceprints: [7: vp1, 3: vp2], library: library)

        #expect(speakers.map(\.name) == [nil, nil])
        #expect(speakers.map(\.personID) == [nil, nil])
    }

    @Test func 不覆盖沿用来的手动名字() async throws {
        // 原来 spk1（s1）被手动改名为李四；声纹库认为他是张三
        let old = diarizedTranscript([
            Speaker(id: "spk1", name: "李四", nameSource: .user, voiceprint: vp1, speechDuration: 5),
            Speaker(id: "spk2", voiceprint: vp2, speechDuration: 8),
        ])
        let library = Library([person("p1", "张三", [1, 0, 0])])
        let f = Fixture(diarizer: FakeDiarizer([
            SpeakerSegment(start: 0, end: 5, speaker: 0),
            SpeakerSegment(start: 6, end: 15, speaker: 1),
        ], voiceprints: [0: vp1, 1: vp2]), voiceprints: library.store)
        let m = f.addTranscribedMeeting(transcript: old)

        f.pipeline.enqueueDiarization(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.speakers.map(\.name) == ["李四", nil])
        #expect(t.speakers.map(\.nameSource) == [.user, nil])
        #expect(t.speakers.map(\.personID) == [nil, nil])
    }

    @Test func 声纹库文件坏了时不识别_区分照常完成() async throws {
        let library = Library([])
        try Data("不是 JSON".utf8).write(to: library.store.url)
        let f = Fixture(FakeTranscriber(twoPeople), diarizer: FakeDiarizer(twoPeopleSegments, voiceprints: [7: vp1, 3: vp2]),
                        voiceprints: library.store)
        let m = f.addMeeting()

        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.speakers.map(\.id) == ["spk1", "spk2"])
        #expect(t.speakers.map(\.name) == [nil, nil])
        #expect(f.host.meetings[m.id]?.transcription == TranscriptionState(status: .done))
        #expect(f.host.meetings[m.id]?.diarization == DiarizationState(status: .done))
        // 坏文件原样留着，不被覆盖
        #expect(try Data(contentsOf: library.store.url) == Data("不是 JSON".utf8))
    }

    @Test func 沿用来的声纹名字与这次认出的人同名时也清掉() async throws {
        // 张三删掉后重新登记过，人员 id 变了；旧稿里 spk1 还关联着旧 id
        let old = diarizedTranscript([
            Speaker(id: "spk1", name: "张三", nameSource: .voiceprint, personID: "p-old", voiceprint: vp2, speechDuration: 5),
            Speaker(id: "spk2", voiceprint: vp1, speechDuration: 8),
        ])
        let library = Library([person("p-new", "张三", [1, 0, 0])])
        let f = Fixture(diarizer: FakeDiarizer([
            SpeakerSegment(start: 0, end: 5, speaker: 0),
            SpeakerSegment(start: 6, end: 15, speaker: 1),
        ], voiceprints: [0: vp2, 1: vp1]), voiceprints: library.store)
        let m = f.addTranscribedMeeting(transcript: old)

        f.pipeline.enqueueDiarization(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.speakers.map(\.name) == [nil, "张三"])
        #expect(t.speakers.map(\.nameSource) == [nil, .voiceprint])
        #expect(t.speakers.map(\.personID) == [nil, "p-new"])
    }
}
