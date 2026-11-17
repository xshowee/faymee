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
        while block { try await Task.sleep(for: .milliseconds(5)) }
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
    let voiceprintModel: String
    var result = DiarizationResult(segments: [], voiceprints: [:])
    var prepareError: Error?
    var diarizeError: Error?
    var block = false
    /// 在 diarize 返回前调用，模拟区分期间别处改了文件
    var onDiarize: (() -> Void)?
    private(set) var calls: [(audio: URL, sentences: [ClosedRange<TimeInterval>], speakerCount: Int?)] = []
    /// 每次进入 diarize 时 yield 一次
    let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation

    init(_ segments: [SpeakerSegment] = [], voiceprints: [Int: Voiceprint] = [:],
         voiceprintModel: String = "fake/voiceprint") {
        result = DiarizationResult(segments: segments, voiceprints: voiceprints)
        self.voiceprintModel = voiceprintModel
        (started, startedContinuation) = AsyncStream.makeStream()
    }

    func prepare(progress: @escaping (Double) -> Void) async throws {
        progress(1)
        if let prepareError { throw prepareError }
    }

    func diarize(audio: URL, sentences: [ClosedRange<TimeInterval>], speakerCount: Int?,
                 progress: @escaping (Double) -> Void) async throws -> DiarizationResult {
        calls.append((audio, sentences, speakerCount))
        startedContinuation.yield()
        progress(0.5)
        while block { try await Task.sleep(for: .milliseconds(5)) }
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

    func diarize(audio: URL, sentences: [ClosedRange<TimeInterval>], speakerCount: Int?,
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
         voiceprints: VoiceprintStore? = nil, isEngineReady: Bool = true) {
        host = FakeHost(store: store)
        self.engine = engine
        self.diarizer = diarizer
        pipeline = TranscriptionPipeline(store: store, transcriber: engine, engine: "fake/1",
                                         isEngineReady: isEngineReady, diarizer: diarizer,
                                         voiceprints: voiceprints, host: host)
        pipeline.onFinish = { [unowned self] in self.finished.append(($0, $1)) }
    }

    deinit { try? FileManager.default.removeItem(at: store.root) }

    /// 一场 10 分钟、已整理好的会议，可带合盖空白、系统声音时段、系统声音不可用时段
    @discardableResult
    func addMeeting(_ id: String = "m1", gaps: [Gap] = [], systemSound: [WallClockPeriod] = [],
                    unavailable: [WallClockPeriod] = [], transcription: TranscriptionState? = nil) -> Meeting {
        var m = Meeting(id: id, title: "会议", startedAt: t0, endedAt: at(600), status: .done,
                        segments: [Segment(file: "0001.caf", startedAt: t0, sampleRate: 48000, channels: 1,
                                           device: "MacBook Pro 麦克风", deviceUID: "BuiltIn",
                                           offset: 0, duration: 600)],
                        recording: "recording.m4a", duration: 600)
        m.lidGaps = gaps
        m.systemSoundPeriodList = systemSound
        m.systemSoundUnavailablePeriodList = unavailable
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

/// 转写稿里的空白由合盖、系统声音时段、系统声音不可用时段在转写时推出（spec 的五种组合）
@MainActor @Suite struct SystemSoundGapTests {
    /// 合盖 300–360 秒、全程开着系统声音：这段只录到系统声音，里面的句子是对方的发言，保留
    @Test func 合盖时系统声音正常标为只录到系统声音_句子保留() async throws {
        let f = Fixture(FakeTranscriber([
            .init(start: 295, end: 299, text: "合盖前"),
            .init(start: 320, end: 323, text: "对方在说"),
        ]))
        let m = f.addMeeting(gaps: [Gap(start: at(300), end: at(360), reason: .lidClosed)],
                             systemSound: [WallClockPeriod(start: t0, end: at(600))])

        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        let expected: [TranscriptItem] = [
            .sentence(.init(id: "s1", start: 295, end: 299, text: "合盖前")),
            .gap(.init(start: 300, end: 360, reason: .lidClosedSystemSoundOnly)),
            .sentence(.init(id: "s2", start: 320, end: 323, text: "对方在说")),
        ]
        #expect(t.items == expected)
        #expect(t.items.compactMap { if case let .gap(g) = $0 { g.label } else { nil } }
            == ["合盖，只录到系统声音（05:00–06:00，01:00）"])
    }

    /// 一场会里五种组合都出现：系统声音 0–100 开、100–200 关、200 秒后开，400–500 不可用；
    /// 合盖 150–180（关）、250–280（正常）、450–470（不可用）
    @Test func 五种组合推出的空白和句子() async throws {
        let f = Fixture(FakeTranscriber([
            .init(start: 50, end: 52, text: "开着系统声音"),
            .init(start: 120, end: 122, text: "关着系统声音"),
            .init(start: 160, end: 162, text: "合盖关着系统声音的幻觉"),
            .init(start: 260, end: 262, text: "合盖时对方在说"),
            .init(start: 420, end: 422, text: "系统声音不可用时我在说"),
            .init(start: 460, end: 462, text: "合盖又不可用的幻觉"),
            .init(start: 480, end: 482, text: "开盖后系统声音还不可用"),
        ]))
        let m = f.addMeeting(
            gaps: [Gap(start: at(150), end: at(180), reason: .lidClosed),
                   Gap(start: at(250), end: at(280), reason: .lidClosed),
                   Gap(start: at(450), end: at(470), reason: .lidClosed)],
            systemSound: [WallClockPeriod(start: t0, end: at(100)), WallClockPeriod(start: at(200), end: at(600))],
            unavailable: [WallClockPeriod(start: at(400), end: at(500))])

        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        let expected: [TranscriptItem] = [
            .sentence(.init(id: "s1", start: 50, end: 52, text: "开着系统声音")),
            .sentence(.init(id: "s2", start: 120, end: 122, text: "关着系统声音")),
            .gap(.init(start: 150, end: 180, reason: .lidClosed)),
            .gap(.init(start: 250, end: 280, reason: .lidClosedSystemSoundOnly)),
            .sentence(.init(id: "s3", start: 260, end: 262, text: "合盖时对方在说")),
            .gap(.init(start: 400, end: 450, reason: .systemSoundMissing)),
            .sentence(.init(id: "s4", start: 420, end: 422, text: "系统声音不可用时我在说")),
            .gap(.init(start: 450, end: 470, reason: .lidClosed)),
            .gap(.init(start: 470, end: 500, reason: .systemSoundMissing)),
            .sentence(.init(id: "s5", start: 480, end: 482, text: "开盖后系统声音还不可用")),
        ]
        #expect(t.items == expected)
        let labels: [String] = [
            "合盖，未录到声音（02:30–03:00，00:30）",
            "合盖，只录到系统声音（04:10–04:40，00:30）",
            "未录到系统声音（06:40–07:30，00:50）",
            "合盖，未录到声音（07:30–07:50，00:20）",
            "未录到系统声音（07:50–08:20，00:30）",
        ]
        #expect(t.items.compactMap { if case let .gap(g) = $0 { g.label } else { nil } } == labels)
    }

    /// 合盖 300–400：系统声音 330–350 关，370–420 不可用。合盖在每个变化时刻拆开，
    /// 不可用的那段被合盖从中间截走，合盖之后剩下的部分标“未录到系统声音”
    @Test func 合盖跨过开关切换和不可用的起止时拆开各标() async throws {
        let f = Fixture()
        let m = f.addMeeting(
            gaps: [Gap(start: at(300), end: at(400), reason: .lidClosed)],
            systemSound: [WallClockPeriod(start: t0, end: at(330)), WallClockPeriod(start: at(350), end: at(600))],
            unavailable: [WallClockPeriod(start: at(370), end: at(420))])

        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        let expected: [TranscriptItem] = [
            .gap(.init(start: 300, end: 330, reason: .lidClosedSystemSoundOnly)),
            .gap(.init(start: 330, end: 350, reason: .lidClosed)),
            .gap(.init(start: 350, end: 370, reason: .lidClosedSystemSoundOnly)),
            .gap(.init(start: 370, end: 400, reason: .lidClosed)),
            .gap(.init(start: 400, end: 420, reason: .systemSoundMissing)),
        ]
        #expect(t.items == expected)
    }

    /// 合盖 100–200：系统声音 120 秒起不可用，150 秒关掉。120–150 不可用和 150–200 关都是“合盖，未录到声音”，
    /// 合成一段，不出现两行一样的空白
    @Test func 拆开后相邻且原因相同的合成一段() async throws {
        let f = Fixture()
        let m = f.addMeeting(gaps: [Gap(start: at(100), end: at(200), reason: .lidClosed)],
                             systemSound: [WallClockPeriod(start: t0, end: at(150))],
                             unavailable: [WallClockPeriod(start: at(120), end: at(150))])

        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        let expected: [TranscriptItem] = [
            .gap(.init(start: 100, end: 120, reason: .lidClosedSystemSoundOnly)),
            .gap(.init(start: 120, end: 200, reason: .lidClosed)),
        ]
        #expect(t.items == expected)
    }

    /// 合盖空白和系统声音时段的起止由 App 各取各的当前时间：合着盖开始、停止录音时，系统声音时段比合盖晚一点开始、
    /// 早一点结束。拆出来的零碎段并进邻段，不多出几行几毫秒的“合盖，未录到声音”（同会议详情的合盖说明）
    @Test func 合盖拆出的零碎段并进邻段() async throws {
        let f = Fixture()
        let m = f.addMeeting(gaps: [Gap(start: t0, end: at(300), reason: .lidClosed),
                                    Gap(start: at(500), end: at(600), reason: .lidClosed)],
                             systemSound: [WallClockPeriod(start: at(0.5), end: at(599.9))])

        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        let expected: [TranscriptItem] = [
            .gap(.init(start: 0, end: 300, reason: .lidClosedSystemSoundOnly)),
            .gap(.init(start: 500, end: 600, reason: .lidClosedSystemSoundOnly)),
        ]
        #expect(t.items == expected)
    }

    /// 合盖 100–200：系统声音正常到 150，150–152 不可用，152 秒关掉。先把零碎的 150–152 并进前一段，
    /// 再合并相邻同原因的段，分界落在 152（与会议详情的合盖说明一致）
    @Test func 先并零碎段再合并同原因的段() async throws {
        let f = Fixture()
        let m = f.addMeeting(gaps: [Gap(start: at(100), end: at(200), reason: .lidClosed)],
                             systemSound: [WallClockPeriod(start: t0, end: at(152))],
                             unavailable: [WallClockPeriod(start: at(150), end: at(152))])

        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        let expected: [TranscriptItem] = [
            .gap(.init(start: 100, end: 152, reason: .lidClosedSystemSoundOnly)),
            .gap(.init(start: 152, end: 200, reason: .lidClosed)),
        ]
        #expect(t.items == expected)
    }

    /// 合着盖停止录音时，不可用时段比合盖晚几毫秒结束：去掉合盖后剩下的零碎一截不标；
    /// 本来就很短的不可用时段（100–102）照常标
    @Test func 不可用被合盖截剩的零碎一截不标_本来就短的照常标() async throws {
        let f = Fixture()
        let m = f.addMeeting(gaps: [Gap(start: at(500), end: at(600), reason: .lidClosed)],
                             systemSound: [WallClockPeriod(start: t0)],
                             unavailable: [WallClockPeriod(start: at(100), end: at(102)),
                                           WallClockPeriod(start: at(400), end: at(600.003))])

        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        let expected: [TranscriptItem] = [
            .gap(.init(start: 100, end: 102, reason: .systemSoundMissing)),
            .gap(.init(start: 400, end: 500, reason: .systemSoundMissing)),
            .gap(.init(start: 500, end: 600, reason: .lidClosed)),
        ]
        #expect(t.items == expected)
    }

    /// 开关关着时，不可用时段不算（只有开着的系统声音才谈得上没录到）
    @Test func 开关关着时不可用不标空白() async throws {
        let f = Fixture()
        let m = f.addMeeting(systemSound: [WallClockPeriod(start: t0, end: at(100))],
                             unavailable: [WallClockPeriod(start: at(50), end: at(300))])

        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.items == [.gap(.init(start: 50, end: 100, reason: .systemSoundMissing))])
    }

    /// 录音中断时仍在合盖、系统声音仍开着、仍不可用（时段没有结束时间）：延续到录音结束
    @Test func 没有结束时间的时段延续到录音结束() async throws {
        let f = Fixture()
        let m = f.addMeeting(gaps: [Gap(start: at(500), reason: .lidClosed)],
                             systemSound: [WallClockPeriod(start: t0)],
                             unavailable: [WallClockPeriod(start: at(400))])

        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        let expected: [TranscriptItem] = [
            .gap(.init(start: 400, end: 500, reason: .systemSoundMissing)),
            .gap(.init(start: 500, end: 600, reason: .lidClosed)),
        ]
        #expect(t.items == expected)
    }

    /// 合盖 100–200 只录到系统声音、300–400 系统声音不可用、500–550 两路都没录到：
    /// 前两段里的说话片段照常算，句子有说话人；最后一段里的片段剔除，句子本身也不进转写稿
    @Test func 新空白里的句子保留说话人_合盖未录到声音仍剔除() async throws {
        let f = Fixture(FakeTranscriber([
            .init(start: 150, end: 155, text: "对方在说"),
            .init(start: 350, end: 355, text: "我在说"),
            .init(start: 520, end: 525, text: "噪声"),
        ]), diarizer: FakeDiarizer([
            SpeakerSegment(start: 150, end: 155, speaker: 1),
            SpeakerSegment(start: 350, end: 355, speaker: 2),
            SpeakerSegment(start: 520, end: 525, speaker: 3),
        ]))
        let m = f.addMeeting(
            gaps: [Gap(start: at(100), end: at(200), reason: .lidClosed),
                   Gap(start: at(500), end: at(550), reason: .lidClosed)],
            systemSound: [WallClockPeriod(start: t0, end: at(450))],
            unavailable: [WallClockPeriod(start: at(300), end: at(400))])

        f.pipeline.enqueue(m.id)
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.sentences.map(\.text) == ["对方在说", "我在说"])
        #expect(t.sentences.map(\.speaker) == ["spk1", "spk2"])
        #expect(t.diarization?.speakers.map(\.speechDuration) == [5, 5])
        #expect(f.diarizer?.calls.map(\.sentences) == [[150...155, 350...355]])
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
        #expect(f.diarizer?.calls.map(\.sentences) == [[0...5, 6...10, 11...15, 30...33]])
        #expect(f.diarizer?.calls.map(\.audio) == [f.store.directory(m.id).appendingPathComponent("recording.m4a")])
        #expect(f.host.meetings[m.id]?.transcription == TranscriptionState(status: .done))
        #expect(f.host.meetings[m.id]?.diarization == DiarizationState(status: .done))
        #expect(f.store.loadAll().first?.diarization == DiarizationState(status: .done))
        #expect(f.finished.map(\.id) == [m.id])
    }

    /// 中点落在合盖空白里的句子不进转写稿，也不交给引擎
    @Test func 完整转写时交给引擎的是转写稿里的句子() async throws {
        let f = Fixture(FakeTranscriber([
            .init(start: 0, end: 5, text: "大家好"),
            .init(start: 320, end: 323, text: "合盖时的幻觉"),
            .init(start: 355, end: 370, text: "开盖后接着说"),
        ]), diarizer: FakeDiarizer())
        let m = f.addMeeting(gaps: [Gap(start: at(300), end: at(360), reason: .lidClosed)])

        f.pipeline.enqueue(m.id)
        try await f.drain()

        #expect(f.diarizer?.calls.map(\.sentences) == [[0...5, 355...370]])
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

    /// 开关关着重新转写：新稿没有说话人，说话人状态如实退回“从未区分”，不留着旧的完成或失败
    @Test func 关闭开关时不调用区分引擎_说话人状态退回从未区分() async throws {
        let f = Fixture(FakeTranscriber(twoPeople), diarizer: FakeDiarizer(twoPeopleSegments))
        let m = f.addMeeting()
        f.pipeline.enqueue(m.id)
        try await f.drain()
        #expect(try f.store.loadTranscript(m.id)?.speakers.count == 2)
        #expect(f.host.meetings[m.id]?.diarization == DiarizationState(status: .done))
        f.pipeline.diarizes = false

        f.pipeline.enqueue(m.id)
        try await f.drain()

        #expect(f.diarizer?.calls.count == 1)
        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.diarization == nil)
        #expect(t.sentences.count == 4)
        #expect(f.host.meetings[m.id]?.diarization == nil)
        #expect(f.store.loadAll().first?.diarization == nil)
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
        #expect(f.diarizer?.calls.map(\.sentences) == [[0...5, 6...10, 11...15]])
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

    /// 排队重新区分后改成完整转写：说话人状态在改的那一刻就按现有转写稿落定，不等转写结束。
    /// 转写失败时旧稿（带说话人）保留，说话人状态也还是完成
    @Test func 排队只区分说话人改成完整转写时说话人状态按现有转写稿落定() async throws {
        let engine = FakeTranscriber(twoPeople)
        engine.transcribeError = EngineError()
        let f = Fixture(engine, diarizer: FakeDiarizer(twoPeopleSegments))
        f.pipeline.isSuspended = true
        var diarized = legacyTranscript()
        diarized.items[0] = .sentence(.init(id: "s1", start: 0, end: 5, text: "我们开始吧", speaker: "spk1"))
        diarized.diarization = Diarization(engine: "fake/diarizer", voiceprintModel: "fake/voiceprint",
                                           speakersCreatedAt: at(800), speakers: [
            Speaker(id: "spk1", name: "张三", nameSource: .user, voiceprint: vp1, speechDuration: 5),
        ])
        let m = f.addTranscribedMeeting(transcript: diarized)
        f.host.setDiarization(DiarizationState(status: .done), for: m.id)
        f.pipeline.enqueueDiarization(m.id, speakerCount: 2)

        f.pipeline.enqueue(m.id)
        #expect(f.host.meetings[m.id]?.diarization == DiarizationState(status: .done))

        f.pipeline.isSuspended = false
        try await f.drain()

        #expect(f.host.meetings[m.id]?.transcription?.status == .failed)
        #expect(try f.store.loadTranscript(m.id) == diarized)
        #expect(f.host.meetings[m.id]?.diarization == DiarizationState(status: .done))
        #expect(f.diarizer?.calls.isEmpty == true)
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

@MainActor @Suite struct TranscriptionEngineHotswapTests {
    @Test func 在线引擎未就绪时完整转写保持排队_就绪后自动开始() async throws {
        let engine = FakeTranscriber([.init(start: 0, end: 5, text: "配置完成")])
        let f = Fixture(engine, isEngineReady: false)
        let m = f.addMeeting()

        #expect(!f.pipeline.isEngineReady)
        #expect(f.pipeline.enqueue(m.id))
        try await Task.sleep(for: .milliseconds(50))

        #expect(f.pipeline.activeID == nil)
        #expect(f.pipeline.queue == [m.id])
        #expect(f.pipeline.waitReason(for: m.id) == .onlineConfig)
        #expect(f.pipeline.isIdle)
        #expect(f.host.meetings[m.id]?.transcription == TranscriptionState(status: .queued))
        #expect(engine.calls.isEmpty)

        f.pipeline.engineAvailabilityChanged(true)
        #expect(f.pipeline.isEngineReady)
        #expect(f.pipeline.waitReason(for: m.id) == nil)
        try await f.drain()

        #expect(f.host.meetings[m.id]?.transcription == TranscriptionState(status: .done))
        #expect(try f.store.loadTranscript(m.id)?.sentences.map(\.text) == ["配置完成"])
    }

    @Test func 引擎未就绪时只区分说话人照常执行_不被前面排队的转写阻塞() async throws {
        let engine = FakeTranscriber([.init(start: 0, end: 5, text: "新转写")])
        let diarizer = FakeDiarizer(twoPeopleSegments, voiceprints: [7: vp1, 3: vp2])
        let f = Fixture(engine, diarizer: diarizer, isEngineReady: false)
        let idleChanges = LockBox<[Bool]>([])
        f.pipeline.onIdleChange = { idleChanges.value.append($0) }

        let parked = f.addMeeting("parked")
        let diarizeOnly = f.addTranscribedMeeting("diarize-only")

        #expect(f.pipeline.enqueue(parked.id))
        #expect(f.pipeline.waitReason(for: parked.id) == .onlineConfig)
        #expect(f.pipeline.isIdle)

        #expect(f.pipeline.enqueueDiarization(diarizeOnly.id))
        #expect(f.pipeline.waitReason(for: diarizeOnly.id) == nil)
        #expect(!f.pipeline.isIdle)

        try await f.drain()

        #expect(engine.calls.isEmpty)
        #expect(diarizer.calls.count == 1)
        #expect(f.host.meetings[diarizeOnly.id]?.diarization == DiarizationState(status: .done))
        #expect(f.pipeline.queue == [parked.id])
        #expect(f.pipeline.waitReason(for: parked.id) == .onlineConfig)
        #expect(f.pipeline.isIdle)
        #expect(idleChanges.value == [false, true])
    }

    @Test func 运行期切换引擎不中断进行中任务_下一场起用新引擎并写新标识() async throws {
        let local = FakeTranscriber([.init(start: 0, end: 5, text: "本机转写")])
        local.block = true
        let online = FakeTranscriber([.init(start: 0, end: 5, text: "在线转写")])
        let f = Fixture(local)
        f.addMeeting("m1")
        f.addMeeting("m2")

        f.pipeline.enqueue("m1")
        f.pipeline.enqueue("m2")
        var started = local.started.makeAsyncIterator()
        await started.next()

        f.pipeline.setEngine(transcriber: online, engine: "openai/gpt-transcribe", isReady: true)
        #expect(f.pipeline.activeID == "m1")
        #expect(online.calls.isEmpty)

        local.block = false
        try await f.drain()

        let t1 = try #require(try f.store.loadTranscript("m1"))
        let t2 = try #require(try f.store.loadTranscript("m2"))
        #expect(t1.engine == "fake/1")
        #expect(t1.sentences.map(\.text) == ["本机转写"])
        #expect(t2.engine == "openai/gpt-transcribe")
        #expect(t2.sentences.map(\.text) == ["在线转写"])
        #expect(local.calls.count == 1)
        #expect(online.calls.count == 1)
    }

    @Test func 运行期切到未就绪在线引擎_当前场按旧引擎跑完_下一场排队等配置() async throws {
        let local = FakeTranscriber([.init(start: 0, end: 5, text: "旧引擎完成")])
        local.block = true
        let online = FakeTranscriber([.init(start: 0, end: 5, text: "新引擎完成")])
        let f = Fixture(local)
        f.addMeeting("m1")
        f.addMeeting("m2")

        f.pipeline.enqueue("m1")
        f.pipeline.enqueue("m2")
        var started = local.started.makeAsyncIterator()
        await started.next()

        f.pipeline.setEngine(transcriber: online, engine: "dashscope/qwen3-asr-flash-filetrans", isReady: false)
        local.block = false
        try await f.drain()

        #expect(try f.store.loadTranscript("m1")?.engine == "fake/1")
        #expect(f.pipeline.queue == ["m2"])
        #expect(f.pipeline.waitReason(for: "m2") == .onlineConfig)
        #expect(online.calls.isEmpty)

        f.pipeline.engineAvailabilityChanged(true)
        try await f.drain()

        #expect(try f.store.loadTranscript("m2")?.engine == "dashscope/qwen3-asr-flash-filetrans")
        #expect(try f.store.loadTranscript("m2")?.sentences.map(\.text) == ["新引擎完成"])
    }

    @Test func 切到模型没下载完的本机引擎_排队原因是等待下载这个模型_下好后自动开始() async throws {
        let model = FakeTranscriber([.init(start: 0, end: 5, text: "本机新模型")])
        let f = Fixture()
        let m = f.addMeeting()

        f.pipeline.setEngine(transcriber: model, engine: "sherpa-onnx/fake", isReady: false,
                             waitReason: .modelDownload(id: "sherpa-onnx/fake"))
        #expect(f.pipeline.enqueue(m.id))
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.pipeline.waitReason(for: m.id) == .modelDownload(id: "sherpa-onnx/fake"))
        #expect(model.calls.isEmpty)

        f.pipeline.engineAvailabilityChanged(true)
        try await f.drain()
        #expect(try f.store.loadTranscript(m.id)?.engine == "sherpa-onnx/fake")

        // 再切回在线未配置：原因跟着变回等待配置
        f.pipeline.setEngine(transcriber: model, engine: "openai/gpt-transcribe", isReady: false)
        f.addMeeting("m2")
        f.pipeline.enqueue("m2")
        #expect(f.pipeline.waitReason(for: "m2") == .onlineConfig)
    }

    @Test func 在线转写失败时保留旧稿并记失败_不回退到旧引擎() async throws {
        let local = FakeTranscriber([.init(start: 0, end: 5, text: "本机旧稿")])
        let online = FakeTranscriber([.init(start: 0, end: 5, text: "不该出现")])
        online.transcribeError = EngineError()
        let f = Fixture(local)
        let m = f.addMeeting()
        f.pipeline.enqueue(m.id)
        try await f.drain()

        f.pipeline.setEngine(transcriber: online, engine: "openai/gpt-transcribe", isReady: true)
        f.pipeline.enqueue(m.id)
        try await f.drain()

        #expect(local.calls.count == 1)
        #expect(online.calls.count == 1)
        #expect(try f.store.loadTranscript(m.id)?.engine == "fake/1")
        #expect(try f.store.loadTranscript(m.id)?.sentences.map(\.text) == ["本机旧稿"])
        #expect(f.host.meetings[m.id]?.transcription == TranscriptionState(status: .failed, error: "模型加载失败"))
        #expect(f.finished.last?.outcome == .failed("模型加载失败"))
    }

    @Test func 引擎未就绪时启动恢复保持转写排队并照常恢复只区分说话人() async throws {
        let engine = FakeTranscriber([.init(start: 0, end: 5, text: "恢复转写")])
        let diarizer = FakeDiarizer(twoPeopleSegments)
        let f = Fixture(engine, diarizer: diarizer, isEngineReady: false)
        f.pipeline.isSuspended = true

        let pendingTranscription = f.addMeeting("pending-t", transcription: TranscriptionState(status: .running))
        let pendingDiarization = f.addTranscribedMeeting("pending-d")
        f.host.setDiarization(DiarizationState(status: .queued), for: pendingDiarization.id)

        f.pipeline.restore([pendingTranscription, f.host.meetings[pendingDiarization.id]!])
        f.pipeline.isSuspended = false
        try await f.drain()

        #expect(f.host.meetings[pendingDiarization.id]?.diarization == DiarizationState(status: .done))
        #expect(f.pipeline.queue == [pendingTranscription.id])
        #expect(f.pipeline.waitReason(for: pendingTranscription.id) == .onlineConfig)
        #expect(engine.calls.isEmpty)

        f.pipeline.engineAvailabilityChanged(true)
        try await f.drain()
        #expect(f.host.meetings[pendingTranscription.id]?.transcription == TranscriptionState(status: .done))
    }
}

/// 声纹模型从目录选择（model-catalog ticket 10）：运行期换区分引擎和匹配阈值
@MainActor @Suite struct DiarizerHotswapTests {
    /// 张三登记在旧模型、李四登记在新模型，声纹都是 [1, 0, 0]。两场会议里 spk1 的声纹与他们的相似度都是 0.8
    private let library = Library([
        person("p-old", "张三", [1, 0, 0], model: "fake/voiceprint"),
        person("p-new", "李四", [1, 0, 0], model: "new/voiceprint"),
    ])
    private let similar = Voiceprint([0.8, 0.6, 0])

    @Test func 运行期切换声纹模型_进行中的用旧模型和旧阈值跑完_之后的重新区分用新模型和新阈值() async throws {
        let old = FakeDiarizer(twoPeopleSegments, voiceprints: [7: similar, 3: vp2])
        old.block = true
        let new = FakeDiarizer(twoPeopleSegments, voiceprints: [7: similar, 3: vp2], voiceprintModel: "new/voiceprint")
        let f = Fixture(FakeTranscriber(twoPeople), diarizer: old, voiceprints: library.store)
        // 旧阈值 0.85：0.8 认不出；新阈值 0.7：0.8 认得出
        f.pipeline.voiceprintThreshold = 0.85
        f.addMeeting("m1")
        f.addTranscribedMeeting("m2")

        f.pipeline.enqueue("m1")
        f.pipeline.enqueueDiarization("m2")
        var started = old.started.makeAsyncIterator()
        await started.next()

        f.pipeline.setDiarizer(new, voiceprintThreshold: 0.7)
        #expect(f.pipeline.voiceprintModel == "new/voiceprint")
        #expect(f.pipeline.voiceprintThreshold == 0.7)
        old.block = false
        try await f.drain()

        let t1 = try #require(try f.store.loadTranscript("m1"))
        #expect(t1.diarization?.voiceprintModel == "fake/voiceprint")
        #expect(t1.speakers.map(\.name) == [nil, nil])
        let t2 = try #require(try f.store.loadTranscript("m2"))
        #expect(t2.diarization?.voiceprintModel == "new/voiceprint")
        // 只有登记在新模型上的李四参与识别；张三的声纹模型不同，相似度再高也不认
        #expect(t2.speakers.map(\.name) == ["李四", nil])
        #expect(t2.speakers.map(\.personID) == ["p-new", nil])
        #expect(old.calls.count == 1)
        #expect(new.calls.count == 1)
    }

    @Test func 运行期去掉区分引擎_进行中的只区分说话人照常落定_之后不能再区分() async throws {
        let old = FakeDiarizer(twoPeopleSegments, voiceprints: [7: vp1, 3: vp2])
        old.block = true
        let f = Fixture(diarizer: old)
        f.addTranscribedMeeting("m1")
        f.addTranscribedMeeting("m2")

        f.pipeline.enqueueDiarization("m1")
        var started = old.started.makeAsyncIterator()
        await started.next()

        f.pipeline.setDiarizer(nil, voiceprintThreshold: 0.7)
        #expect(!f.pipeline.canDiarize)
        #expect(f.pipeline.voiceprintModel == nil)
        #expect(!f.pipeline.enqueueDiarization("m2"))
        old.block = false
        try await f.drain()

        #expect(f.host.meetings["m1"]?.diarization == DiarizationState(status: .done))
        #expect(try f.store.loadTranscript("m1")?.diarization?.voiceprintModel == "fake/voiceprint")
    }

    @Test func 运行期去掉区分引擎_已排队的只区分说话人记为失败并说明原因() async throws {
        let old = FakeDiarizer(twoPeopleSegments, voiceprints: [7: vp1, 3: vp2])
        old.block = true
        let f = Fixture(diarizer: old)
        f.addTranscribedMeeting("m1")
        f.addTranscribedMeeting("m2")
        f.pipeline.enqueueDiarization("m1")
        f.pipeline.enqueueDiarization("m2")
        var started = old.started.makeAsyncIterator()
        await started.next()

        f.pipeline.setDiarizer(nil, voiceprintThreshold: 0.7)
        old.block = false
        try await f.drain()

        #expect(f.host.meetings["m2"]?.diarization
            == DiarizationState(status: .failed, error: "所选声纹模型还不能用，下载好后再区分说话人"))
        #expect(old.calls.count == 1)
    }

    @Test func 运行期去掉区分引擎_进行中的完整转写照常写上说话人() async throws {
        let old = FakeDiarizer(twoPeopleSegments, voiceprints: [7: vp1, 3: vp2])
        old.block = true
        let f = Fixture(FakeTranscriber(twoPeople), diarizer: old)
        f.addMeeting("m1")

        f.pipeline.enqueue("m1")
        var started = old.started.makeAsyncIterator()
        await started.next()

        f.pipeline.setDiarizer(nil, voiceprintThreshold: 0.7)
        old.block = false
        try await f.drain()

        #expect(f.host.meetings["m1"]?.diarization == DiarizationState(status: .done))
        #expect(try f.store.loadTranscript("m1")?.diarization?.voiceprintModel == "fake/voiceprint")
    }
}

/// 所选声纹模型还没下载完（spec「切换的语义」）：区分说话人排队「等待下载声纹模型」，下好后自动开始；
/// 转写本身不等声纹模型
@MainActor @Suite struct DiarizerDownloadWaitTests {
    private let waiting = TranscriptionWaitReason.modelDownload(id: "new/voiceprint")

    @Test func 完整转写照常保存_说话人排队等下载_不挡纪要_下好后自动区分() async throws {
        let f = Fixture(FakeTranscriber(twoPeople))
        f.pipeline.setDiarizer(nil, voiceprintThreshold: 0.7, waitReason: waiting)
        #expect(f.pipeline.canDiarize)
        #expect(!f.pipeline.transcriptionDiarizes)
        let m = f.addMeeting()

        f.pipeline.enqueue(m.id)
        // 挂起的区分说话人不算忙：纪要照常开始
        try await f.drain()

        let t = try #require(try f.store.loadTranscript(m.id))
        #expect(t.sentences.map(\.text) == ["我们开始吧", "好的我先说", "你接着讲", "没人说话时的噪声"])
        #expect(t.diarization == nil)
        #expect(f.host.meetings[m.id]?.transcription == TranscriptionState(status: .done))
        #expect(f.host.meetings[m.id]?.diarization == DiarizationState(status: .queued))
        #expect(f.store.loadAll().first?.diarization == DiarizationState(status: .queued))
        #expect(f.finished.map(\.id) == [m.id])
        #expect(f.pipeline.queue == [m.id])
        #expect(f.pipeline.diarizationWaitReason(for: m.id) == waiting)
        #expect(f.pipeline.waitReason(for: m.id) == nil)

        let new = FakeDiarizer(twoPeopleSegments, voiceprints: [7: vp1, 3: vp2], voiceprintModel: "new/voiceprint")
        f.pipeline.setDiarizer(new, voiceprintThreshold: 0.7)
        try await f.until { f.host.meetings[m.id]?.diarization == DiarizationState(status: .done) }
        try await f.drain()

        let diarized = try #require(try f.store.loadTranscript(m.id))
        #expect(diarized.diarization?.voiceprintModel == "new/voiceprint")
        #expect(diarized.sentences.map(\.speaker) == ["spk1", "spk2", "spk1", nil])
        #expect(f.pipeline.queue.isEmpty)
        #expect(f.pipeline.diarizationWaitReason(for: m.id) == nil)
        #expect(f.finished.map(\.id) == [m.id])
    }

    @Test func 开关关着时不排队区分说话人() async throws {
        let f = Fixture(FakeTranscriber(twoPeople))
        f.pipeline.setDiarizer(nil, voiceprintThreshold: 0.7, waitReason: waiting)
        f.pipeline.diarizes = false
        let m = f.addMeeting()

        f.pipeline.enqueue(m.id)
        try await f.drain()

        #expect(f.host.meetings[m.id]?.diarization == nil)
        #expect(f.pipeline.queue.isEmpty)
    }

    @Test func 运行期切到没下载的模型_进行中的照常跑完_排队的和新入队的只区分说话人等下载_不失败() async throws {
        let old = FakeDiarizer(twoPeopleSegments, voiceprints: [7: vp1, 3: vp2])
        old.block = true
        let f = Fixture(diarizer: old)
        for id in ["m1", "m2", "m3"] { f.addTranscribedMeeting(id) }
        f.pipeline.enqueueDiarization("m1")
        f.pipeline.enqueueDiarization("m2", speakerCount: 2)
        var started = old.started.makeAsyncIterator()
        await started.next()

        f.pipeline.setDiarizer(nil, voiceprintThreshold: 0.7, waitReason: waiting)
        #expect(f.pipeline.canDiarize)
        #expect(f.pipeline.voiceprintModel == nil)
        #expect(f.pipeline.enqueueDiarization("m3"))
        old.block = false
        try await f.drain()

        #expect(f.host.meetings["m1"]?.diarization == DiarizationState(status: .done))
        #expect(try f.store.loadTranscript("m1")?.diarization?.voiceprintModel == "fake/voiceprint")
        for id in ["m2", "m3"] {
            #expect(f.host.meetings[id]?.diarization == DiarizationState(status: .queued))
            #expect(f.pipeline.diarizationWaitReason(for: id) == waiting)
        }
        #expect(f.pipeline.queue == ["m2", "m3"])

        let new = FakeDiarizer(twoPeopleSegments, voiceprints: [7: vp1, 3: vp2], voiceprintModel: "new/voiceprint")
        f.pipeline.setDiarizer(new, voiceprintThreshold: 0.7)
        try await f.until { f.pipeline.queue.isEmpty && f.pipeline.activeID == nil }

        for id in ["m2", "m3"] {
            #expect(f.host.meetings[id]?.diarization == DiarizationState(status: .done))
            #expect(try f.store.loadTranscript(id)?.diarization?.voiceprintModel == "new/voiceprint")
        }
        // 排队时指定的人数还在
        #expect(new.calls.map(\.speakerCount) == [2, nil])
        #expect(old.calls.count == 1)
    }

    @Test func 等下载时转写不受影响_排在前面的等待区分不挡后面的转写() async throws {
        let f = Fixture(FakeTranscriber(twoPeople))
        f.pipeline.setDiarizer(nil, voiceprintThreshold: 0.7, waitReason: waiting)
        f.addTranscribedMeeting("waiting")
        #expect(f.pipeline.enqueueDiarization("waiting"))
        f.addMeeting("new")

        f.pipeline.enqueue("new")
        try await f.drain()

        #expect(f.host.meetings["new"]?.transcription == TranscriptionState(status: .done))
        #expect(f.pipeline.queue == ["waiting", "new"])
    }

    @Test func 启动时恢复等下载的只区分说话人_保持排队() async throws {
        let f = Fixture(FakeTranscriber(twoPeople))
        f.pipeline.setDiarizer(nil, voiceprintThreshold: 0.7, waitReason: waiting)
        f.pipeline.isSuspended = true
        let queued = f.addTranscribedMeeting("queued")
        f.host.setDiarization(DiarizationState(status: .queued), for: queued.id)

        f.pipeline.restore([f.host.meetings[queued.id]!])
        f.pipeline.isSuspended = false
        try await f.drain()

        #expect(f.host.meetings[queued.id]?.diarization == DiarizationState(status: .queued))
        #expect(f.pipeline.diarizationWaitReason(for: queued.id) == waiting)
    }

    @Test func 建管线时就在等下载() async throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("FaymeeCoreTests-\(UUID().uuidString)", isDirectory: true))
        let host = FakeHost(store: store)
        let pipeline = TranscriptionPipeline(store: store, transcriber: FakeTranscriber(), engine: "fake/1",
                                             diarizer: nil, diarizerWaitReason: waiting, host: host)
        #expect(pipeline.canDiarize)
        #expect(pipeline.diarizerWaitReason == waiting)
        try? FileManager.default.removeItem(at: store.root)
    }
}

private final class LockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
