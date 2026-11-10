import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-10T02:00:00Z", strategy: .iso8601)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private struct EngineError: LocalizedError {
    var errorDescription: String? { "内存不足，关闭一些应用后重试" }
}

/// 一条概要，出处是 s1
private let oneOverview = #"{"overview": [{"text": "讨论了发布时间", "refs": ["s1"]}]}"#

/// 假引擎：按 respond 现算输出，记下 load / generate / unload 的先后。
/// block 为 true 时 generate 一直等到被取消或 block 改回 false
private final class FakeGenerator: TextGenerator, @unchecked Sendable {
    var contextTokens = 100_000
    var isDownloaded = true
    var block = false
    var loadError: Error?
    var respond: (_ prompt: String) -> String = { _ in oneOverview }
    /// "load"、"generate"、"unload"
    private(set) var events: [String] = []
    private(set) var prompts: [String] = []
    /// 每次进入 generate 时 yield 一次，测试据此知道生成已经开始
    let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation

    init() {
        (started, startedContinuation) = AsyncStream.makeStream()
    }

    var loads: Int { events.count { $0 == "load" } }
    var unloads: Int { events.count { $0 == "unload" } }
    var generations: Int { events.count { $0 == "generate" } }

    func countTokens(_ text: String) -> Int { text.count }

    func load(progress: @escaping (Double) -> Void) async throws {
        events.append("load")
        progress(1)
        if let loadError { throw loadError }
    }

    func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        events.append("generate")
        prompts.append(prompt)
        startedContinuation.yield()
        while block { try await Task.sleep(for: .milliseconds(5)) }
        return respond(prompt)
    }

    func unload() { events.append("unload") }

    /// 别的假引擎（转写）也记进同一条时间线，便于断言先后
    func record(_ event: String) { events.append(event) }
}

/// 假转写引擎：返回一句话，记进 log 的时间线。block 为 true 时等到被取消或 block 改回 false；
/// ignoresCancellation 为 true 时被取消也照样等到 block 改回 false（真实引擎可能取消得不及时）
private final class FakeTranscriber: Transcriber, @unchecked Sendable {
    let log: FakeGenerator
    var block = false
    var ignoresCancellation = false
    /// 转写出来的那一句
    var text = "重新转写出来的一句话，内容足够长"
    private(set) var calls = 0

    init(log: FakeGenerator) { self.log = log }

    func prepare(progress: @escaping (Double) -> Void) async throws {}

    func transcribe(audio: URL, hotwords: [String],
                    progress: @escaping (Double) -> Void) async throws -> [TranscribedSentence] {
        calls += 1
        log.record("transcribe")
        while block {
            if ignoresCancellation { Thread.sleep(forTimeInterval: 0.005) } else { try await Task.sleep(for: .milliseconds(5)) }
        }
        return [.init(start: 0, end: 5, text: text)]
    }
}

/// 不理会取消的引擎：load 或 generate 挂起，直到测试手动放行
private final class SlowToCancelGenerator: TextGenerator, @unchecked Sendable {
    enum Step { case load, generate }
    let hangsIn: Step
    var contextTokens: Int { 100_000 }
    var isDownloaded: Bool { true }
    var continuation: CheckedContinuation<String, Error>?
    private(set) var unloads = 0
    private(set) var loadCalls = 0

    init(hangsIn: Step) { self.hangsIn = hangsIn }

    func countTokens(_ text: String) -> Int { text.count }
    /// 只有第一次 load 挂起
    func load(progress: @escaping (Double) -> Void) async throws {
        loadCalls += 1
        if hangsIn == .load && loadCalls == 1 {
            _ = try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }
    func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        hangsIn == .generate ? try await withCheckedThrowingContinuation { continuation = $0 } : oneOverview
    }
    func unload() { unloads += 1 }
}

/// 代替 AppModel：会议元数据的唯一写入者，记录纪要状态的每次变化
@MainActor
private final class FakeHost: MinutesHost, TranscriptionHost {
    let store: MeetingStore
    var meetings: [String: Meeting] = [:]
    private(set) var history: [String: [MinutesState.Status]] = [:]

    init(store: MeetingStore) { self.store = store }

    func meeting(_ id: String) -> Meeting? { meetings[id] }

    func setMinutes(_ state: MinutesState, for id: String) {
        guard var m = meetings[id] else { return }
        m.minutes = state
        meetings[id] = m
        history[id, default: []].append(state.status)
        try! store.save(m)
    }

    func setTranscription(_ state: TranscriptionState, for id: String) {
        guard var m = meetings[id] else { return }
        m.transcription = state
        meetings[id] = m
        try! store.save(m)
    }
}

/// 转写稿：两句一段合盖空白。createdAt 带小数秒，和真实转写一样（写盘后会丢掉小数）
private func makeTranscript(_ texts: [String] = ["我们今天讨论 v2.3 的发布时间，支付接口还没准备好", "那就推迟一周发布，张三你下周三之前把报价单发给客户，海外版的预算还没定"],
                            createdAt: Date = at(3600.6)) -> Transcript {
    var items: [TranscriptItem] = []
    for (i, text) in texts.enumerated() {
        items.append(.sentence(TranscriptSentence(id: "s\(i + 1)", start: Double(i) * 100 + 3.2,
                                                  end: Double(i) * 100 + 9, text: text)))
        if i == 0 { items.append(.gap(TranscriptGap(start: 50, end: 80, reason: .lidClosed))) }
    }
    return Transcript(engine: "fake/transcriber", createdAt: createdAt, hotwords: [], items: items)
}

@MainActor
private final class Fixture {
    let store = MeetingStore(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("FaymeeCoreTests-\(UUID().uuidString)", isDirectory: true))
    let host: FakeHost
    let engine: FakeGenerator
    let pipeline: MinutesPipeline

    init(_ engine: FakeGenerator = FakeGenerator()) {
        host = FakeHost(store: store)
        self.engine = engine
        pipeline = MinutesPipeline(store: store, generator: engine, model: "fake/generator", host: host)
    }

    /// 和纪要管线协调好的转写管线，同 App 里的接法
    func makeTranscription() -> (TranscriptionPipeline, FakeTranscriber) {
        let transcriber = FakeTranscriber(log: engine)
        let transcription = TranscriptionPipeline(store: store, transcriber: transcriber, engine: "fake/transcriber",
                                                  host: host)
        pipeline.coordinate(with: transcription)
        return (transcription, transcriber)
    }

    deinit { try? FileManager.default.removeItem(at: store.root) }

    /// 一场已转写好的会议
    @discardableResult
    func addMeeting(_ id: String = "m1", transcript: Transcript? = makeTranscript(),
                    minutes: MinutesState? = nil) -> Meeting {
        var m = Meeting(id: id, title: "产品周会", startedAt: t0, endedAt: at(600), status: .done,
                        recording: "recording.m4a", duration: 600)
        m.transcription = TranscriptionState(status: .done)
        m.minutes = minutes
        try! FileManager.default.createDirectory(at: store.directory(id), withIntermediateDirectories: true)
        try! store.save(m)
        if let transcript { try! store.saveTranscript(transcript, for: id) }
        host.meetings[id] = m
        return m
    }

    /// 等到队列空、没有正在生成的会议
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

@MainActor @Suite struct MinutesPipelineTests {
    @Test func 按读回的转写稿生成并写出纪要() async throws {
        let f = Fixture()
        f.addMeeting()

        #expect(f.pipeline.enqueue("m1"))
        try await f.drain()

        let minutes = try #require(try f.store.loadMinutes("m1"))
        let snapshot = try #require(try f.store.loadTranscript("m1"))
        #expect(minutes.model == "fake/generator")
        #expect(minutes.template == "general")
        #expect(minutes.source == MinutesSource(transcriptCreatedAt: snapshot.createdAt, textHash: snapshot.textHash))
        #expect(minutes.sections.first { $0.kind == .overview }?.items.map(\.refs) == [[MinutesRef(id: "s1", start: 3.2)]])
        // 输入是磁盘上的转写稿：合盖空白以标记行出现
        #expect(f.engine.prompts.first?.contains("[合盖") == true)
        #expect(f.host.history["m1"] == [.queued, .running, .done])
        #expect(f.store.loadAll().first?.minutes == MinutesState(status: .done))
    }

    @Test func 生成失败时保留旧纪要并记下原因() async throws {
        let f = Fixture()
        f.addMeeting()
        f.pipeline.enqueue("m1")
        try await f.drain()
        let url = f.store.directory("m1").appendingPathComponent("minutes.json")
        let before = try Data(contentsOf: url)

        // 解析失败重试一次，再失败整场失败
        f.engine.respond = { _ in "抱歉，我无法完成" }
        #expect(f.pipeline.enqueue("m1"))
        try await f.drain()

        #expect(try Data(contentsOf: url) == before)
        #expect(f.engine.generations == 3)
        #expect(f.host.meetings["m1"]?.minutes == MinutesState(status: .failed, error: "模型输出无法解析"))
        #expect(f.host.history["m1"] == [.queued, .running, .done, .queued, .running, .failed])
    }

    @Test func 加载模型失败时会议标为失败_队列继续() async throws {
        let engine = FakeGenerator()
        engine.loadError = EngineError()
        let f = Fixture(engine)
        f.addMeeting("m1")
        f.addMeeting("m2")

        f.pipeline.enqueue("m1")
        f.pipeline.enqueue("m2")
        try await f.drain()

        #expect(try f.store.loadMinutes("m1") == nil)
        #expect(f.engine.generations == 0)
        #expect(f.host.meetings["m1"]?.minutes == MinutesState(status: .failed, error: "内存不足，关闭一些应用后重试"))
        #expect(f.host.meetings["m2"]?.minutes?.status == .failed)
    }

    @Test func 一次一场按入队先后_连续排队时保持加载_队列空了才释放() async throws {
        let engine = FakeGenerator()
        engine.block = true
        let f = Fixture(engine)
        for id in ["m1", "m2", "m3"] { f.addMeeting(id) }

        f.pipeline.enqueue("m1")
        f.pipeline.enqueue("m2")
        f.pipeline.enqueue("m3")
        // 重复入队不会排两次
        f.pipeline.enqueue("m2")
        var started = f.engine.started.makeAsyncIterator()
        await started.next()

        #expect(f.pipeline.activeID == "m1")
        #expect(f.pipeline.queue == ["m2", "m3"])
        #expect(f.host.meetings["m3"]?.minutes?.status == .queued)

        f.engine.block = false
        f.pipeline.remove("m1")
        try await f.drain()

        #expect(f.host.meetings["m2"]?.minutes?.status == .done)
        #expect(f.host.meetings["m3"]?.minutes?.status == .done)
        #expect(f.engine.unloads == 1)
        #expect(f.engine.events.last == "unload")
        #expect(f.engine.events.dropLast().allSatisfy { $0 != "unload" })
    }

    @Test func 没有转写稿时失败() async throws {
        let f = Fixture()
        f.addMeeting(transcript: nil)

        f.pipeline.enqueue("m1")
        try await f.drain()

        #expect(f.host.meetings["m1"]?.minutes == MinutesState(status: .failed, error: "没有转写稿，无法生成纪要"))
    }

    @Test func 只接受转写过的会议() async throws {
        let f = Fixture()
        var m = f.addMeeting()
        m.transcription = nil
        f.host.meetings[m.id] = m

        #expect(!f.pipeline.enqueue(m.id))
        #expect(!f.pipeline.enqueue("不存在"))
        #expect(f.pipeline.isIdle)
        #expect(f.host.history.isEmpty)
    }

    @Test func 暂停时取消正在生成的纪要并放回队首_释放模型_恢复后从头再生成() async throws {
        let engine = FakeGenerator()
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
        #expect(f.host.meetings["m1"]?.minutes?.status == .queued)
        // 被取消的任务退出后释放模型
        try await f.until { f.engine.unloads == 1 }
        #expect(f.engine.events == ["load", "generate", "unload"])
        // 暂停期间入队的照样排在后面，但不开始
        f.addMeeting("m3")
        f.pipeline.enqueue("m3")
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.pipeline.activeID == nil)
        #expect(f.engine.generations == 1)
        #expect(try f.store.loadMinutes("m1") == nil)

        // 录音结束、整理完成
        f.engine.block = false
        f.pipeline.isSuspended = false
        try await f.drain()

        #expect(f.host.history["m1"] == [.queued, .running, .queued, .running, .done])
        #expect(f.engine.events == ["load", "generate", "unload",
                                    "load", "generate", "load", "generate", "load", "generate", "unload"])
        for id in ["m1", "m2", "m3"] {
            #expect(try f.store.loadMinutes(id) != nil)
        }
    }

    @Test func 引擎不理会取消照常返回时结果作废() async throws {
        // 真实引擎可能取消得不及时：被取消后仍返回结果，这份结果不能写进已删除或已重新排队的会议
        let engine = SlowToCancelGenerator(hangsIn: .generate)
        let f = Fixture()
        let pipeline = MinutesPipeline(store: f.store, generator: engine, model: "slow", host: f.host)
        f.addMeeting("m1")
        pipeline.enqueue("m1")
        try await f.until { engine.continuation != nil }

        pipeline.isSuspended = true
        // 引擎还在用模型，等它退出再释放
        #expect(engine.unloads == 0)
        engine.continuation?.resume(returning: oneOverview)
        try await f.until { engine.unloads == 1 }

        #expect(try f.store.loadMinutes("m1") == nil)
        #expect(f.host.meetings["m1"]?.minutes?.status == .queued)
        #expect(pipeline.queue == ["m1"])
    }

    @Test func 取消时还没加载完的模型在加载完后释放_之后的任务等它退出再开始() async throws {
        let engine = SlowToCancelGenerator(hangsIn: .load)
        let f = Fixture()
        let pipeline = MinutesPipeline(store: f.store, generator: engine, model: "slow", host: f.host)
        f.addMeeting("m1")
        pipeline.enqueue("m1")
        try await f.until { engine.continuation != nil }

        pipeline.isSuspended = true
        pipeline.isSuspended = false
        let first = engine.continuation
        try await Task.sleep(for: .milliseconds(50))
        // 重新开始的任务等还在加载的旧任务退出，不同时用引擎
        #expect(pipeline.activeID == "m1")
        #expect(engine.loadCalls == 1)
        #expect(engine.unloads == 0)

        first?.resume(returning: "")
        try await f.until { pipeline.isIdle }
        #expect(engine.loadCalls == 2)
        #expect(f.host.meetings["m1"]?.minutes?.status == .done)
        #expect(engine.unloads == 1)
    }

    /// 加载模型时可能不理会取消，删除会议后引擎仍在用模型文件，这时不能删模型
    @Test func 取消后任务还没退出时引擎仍算占用() async throws {
        let engine = SlowToCancelGenerator(hangsIn: .load)
        let f = Fixture()
        let pipeline = MinutesPipeline(store: f.store, generator: engine, model: "slow", host: f.host)
        f.addMeeting("m1")
        #expect(!pipeline.isEngineInUse)
        pipeline.enqueue("m1")
        try await f.until { engine.continuation != nil }
        #expect(pipeline.isEngineInUse)

        pipeline.remove("m1")
        #expect(pipeline.activeID == nil)
        #expect(pipeline.isEngineInUse)

        engine.continuation?.resume(returning: "")
        try await f.until { !pipeline.isEngineInUse }
        #expect(engine.unloads == 1)
    }

    @Test func 生成中删除会议时取消且不写任何文件() async throws {
        let engine = FakeGenerator()
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
        #expect(f.host.meetings["m2"]?.minutes?.status == .done)
    }

    @Test func 以开始时的转写稿为准_生成期间修改转写稿不影响本次结果() async throws {
        let engine = FakeGenerator()
        engine.block = true
        let f = Fixture(engine)
        f.addMeeting()
        let snapshot = try #require(try f.store.loadTranscript("m1"))
        f.pipeline.enqueue("m1")
        var started = f.engine.started.makeAsyncIterator()
        await started.next()

        // 生成期间重新转写：只剩一句，s1 之外的出处都不存在了
        try f.store.saveTranscript(makeTranscript(["重新转写的一句"], createdAt: at(7200)), for: "m1")
        f.engine.respond = { _ in #"{"overview": [{"text": "讨论了发布时间", "refs": ["s1", "s2"]}]}"# }
        f.engine.block = false
        try await f.drain()

        let minutes = try #require(try f.store.loadMinutes("m1"))
        #expect(minutes.source == MinutesSource(transcriptCreatedAt: snapshot.createdAt, textHash: snapshot.textHash))
        #expect(minutes.sections.first?.items.first?.refs.map(\.id) == ["s1", "s2"])
    }

    @Test func 用电池时自动任务保持排队_接上电源后开始() async throws {
        let f = Fixture()
        f.pipeline.isOnPower = false
        f.addMeeting()

        f.pipeline.enqueue("m1")
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.pipeline.activeID == nil)
        #expect(f.pipeline.waitReason(for: "m1") == .power)
        #expect(f.engine.loads == 0)

        f.pipeline.isOnPower = true
        try await f.drain()
        #expect(f.host.meetings["m1"]?.minutes?.status == .done)
    }

    @Test func 现在生成不等接通电源_越过排在前面的自动任务() async throws {
        let f = Fixture()
        f.pipeline.isOnPower = false
        f.addMeeting("auto")
        f.addMeeting("now")
        f.addMeeting("later")
        f.pipeline.enqueue("auto")
        f.pipeline.enqueue("now")
        f.pipeline.enqueue("later")

        // 已在排队的任务点了“现在生成”
        #expect(f.pipeline.enqueue("now", now: true))
        try await f.until { f.host.meetings["now"]?.minutes?.status == .done }

        #expect(f.pipeline.queue == ["auto", "later"])
        #expect(f.pipeline.waitReason(for: "auto") == .power)
        #expect(f.host.meetings["auto"]?.minutes?.status == .queued)
        // 剩下的都开始不了，释放模型
        #expect(f.engine.events == ["load", "generate", "unload"])
    }

    @Test func 拔掉电源不取消正在生成的纪要_之后的自动任务等接通电源() async throws {
        let engine = FakeGenerator()
        engine.block = true
        let f = Fixture(engine)
        f.addMeeting("m1")
        f.addMeeting("m2")
        f.pipeline.enqueue("m1")
        f.pipeline.enqueue("m2")
        var started = f.engine.started.makeAsyncIterator()
        await started.next()

        f.pipeline.isOnPower = false
        f.engine.block = false
        try await f.until { f.host.meetings["m1"]?.minutes?.status == .done }

        #expect(f.engine.generations == 1)
        #expect(f.pipeline.queue == ["m2"])
        #expect(f.engine.events.last == "unload")
    }

    @Test func 模型未下载时不开始_下载完成后开始() async throws {
        let engine = FakeGenerator()
        engine.isDownloaded = false
        let f = Fixture(engine)
        f.addMeeting()

        // 用户点的“现在生成”也得等模型
        f.pipeline.enqueue("m1", now: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.pipeline.activeID == nil)
        #expect(f.pipeline.waitReason(for: "m1") == .model)
        #expect(!f.pipeline.isModelDownloaded)
        #expect(f.engine.events.isEmpty)

        engine.isDownloaded = true
        f.pipeline.modelAvailabilityChanged()
        #expect(f.pipeline.isModelDownloaded)
        try await f.drain()
        #expect(f.host.meetings["m1"]?.minutes?.status == .done)
    }

    @Test func 排队说明按需要用户处理的先后派生() async throws {
        let engine = FakeGenerator()
        engine.isDownloaded = false
        let f = Fixture(engine)
        f.pipeline.isOnPower = false
        f.addMeeting("m1")
        f.addMeeting("m2")
        f.pipeline.enqueue("m1")
        f.pipeline.enqueue("m2", now: true)

        #expect(f.pipeline.waitReason(for: "m1") == .model)
        #expect(f.pipeline.waitReason(for: "m2") == .model)
        #expect(f.pipeline.waitReason(for: "不存在") == nil)

        // 录音中暂停不另派生说明，其余条件照常
        f.pipeline.isSuspended = true
        engine.isDownloaded = true
        f.pipeline.modelAvailabilityChanged()
        #expect(f.pipeline.waitReason(for: "m1") == .power)
        #expect(f.pipeline.waitReason(for: "m2") == nil)
    }

    @Test func 转写不空闲时不开始_转写完成后开始() async throws {
        let f = Fixture()
        let (transcription, transcriber) = f.makeTranscription()
        transcriber.block = true
        f.addMeeting("m1")
        f.addMeeting("m2")
        transcription.enqueue("m2")
        try await f.until { transcriber.calls == 1 }

        f.pipeline.enqueue("m1")
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.pipeline.activeID == nil)
        #expect(f.pipeline.waitReason(for: "m1") == .transcription)

        transcriber.block = false
        try await f.drain()
        #expect(transcription.isIdle)
        #expect(f.engine.events == ["transcribe", "load", "generate", "unload"])
    }

    @Test func 转写入队不取消正在生成的纪要_转写等它完成后先于排队的纪要() async throws {
        let engine = FakeGenerator()
        engine.block = true
        let f = Fixture(engine)
        let (transcription, transcriber) = f.makeTranscription()
        for id in ["m1", "m2", "m3"] { f.addMeeting(id) }
        f.pipeline.enqueue("m1")
        f.pipeline.enqueue("m3")
        var started = f.engine.started.makeAsyncIterator()
        await started.next()

        // 重新转写 m2
        transcription.enqueue("m2")
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.pipeline.activeID == "m1")
        #expect(transcription.activeID == nil)
        #expect(transcriber.calls == 0)
        #expect(f.pipeline.waitReason(for: "m3") == .transcription)

        f.engine.block = false
        try await f.drain()
        try await f.until { transcription.isIdle }
        // 让转写时释放模型，转写完再加载
        #expect(f.engine.events == ["load", "generate", "unload", "transcribe", "load", "generate", "unload"])
        #expect(f.host.meetings["m1"]?.minutes?.status == .done)
        #expect(f.host.meetings["m2"]?.transcription?.status == .done)
    }

    /// 删除正在转写的会议：转写被取消，但引擎可能还没退出，这时纪要不能开始用引擎
    @Test func 转写被取消但引擎还没退出时_纪要等它退出再开始() async throws {
        let f = Fixture()
        let (transcription, transcriber) = f.makeTranscription()
        transcriber.block = true
        transcriber.ignoresCancellation = true
        f.addMeeting("m1")
        f.addMeeting("m2")
        transcription.enqueue("m2")
        try await f.until { transcriber.calls == 1 }
        f.pipeline.enqueue("m1")

        transcription.remove("m2")
        try await Task.sleep(for: .milliseconds(50))
        #expect(!transcription.isIdle)
        #expect(f.pipeline.activeID == nil)
        #expect(f.pipeline.waitReason(for: "m1") == .transcription)
        #expect(f.engine.loads == 0)

        transcriber.block = false
        try await f.drain()
        #expect(transcription.isIdle)
        #expect(f.engine.events == ["transcribe", "load", "generate", "unload"])
        #expect(f.host.meetings["m1"]?.minutes?.status == .done)
    }

    @Test func 录音打断后恢复时转写先于纪要() async throws {
        let engine = FakeGenerator()
        engine.block = true
        let f = Fixture(engine)
        let (transcription, _) = f.makeTranscription()
        f.addMeeting("m1")
        f.addMeeting("m2")
        f.pipeline.enqueue("m1")
        var started = f.engine.started.makeAsyncIterator()
        await started.next()
        transcription.enqueue("m2")

        // 开始录音：两条管线都暂停；整理完成后恢复，纪要先恢复也不抢在转写前面
        transcription.isSuspended = true
        f.pipeline.isSuspended = true
        f.engine.block = false
        f.pipeline.isSuspended = false
        transcription.isSuspended = false
        try await f.drain()
        try await f.until { transcription.isIdle }

        #expect(f.engine.events == ["load", "generate", "unload", "transcribe", "load", "generate", "unload"])
        #expect(f.host.meetings["m1"]?.minutes?.status == .done)
    }

    /// 停止录音后整理完成：解除暂停的瞬间新会议的转写还没入队，排队的纪要不能抢在它前面
    @Test func 预定了转写时不算空闲_解除暂停时纪要不抢在新会议的转写前面() async throws {
        let f = Fixture()
        let (transcription, _) = f.makeTranscription()
        f.addMeeting("m1")
        f.addMeeting("m2")
        transcription.isSuspended = true
        f.pipeline.isSuspended = true
        f.pipeline.enqueue("m1")
        // 整理 m2：整理完就要排队转写
        transcription.reserve("m2")

        transcription.isSuspended = false
        f.pipeline.isSuspended = false
        try await Task.sleep(for: .milliseconds(50))
        #expect(!transcription.isIdle)
        #expect(f.pipeline.activeID == nil)
        #expect(f.pipeline.waitReason(for: "m1") == .transcription)

        transcription.enqueue("m2")
        try await f.drain()
        try await f.until { transcription.isIdle }
        #expect(f.engine.events == ["transcribe", "load", "generate", "unload"])
    }

    /// 整理失败、会议被删除时预定作废，纪要照常开始
    @Test func 取消预定或删除会议后转写回到空闲() async throws {
        let f = Fixture()
        let (transcription, _) = f.makeTranscription()
        f.addMeeting("m1")
        transcription.reserve("m2")
        transcription.reserve("m3")
        f.pipeline.enqueue("m1")
        #expect(f.pipeline.waitReason(for: "m1") == .transcription)

        transcription.unreserve("m2")
        #expect(!transcription.isIdle)
        transcription.remove("m3")
        #expect(transcription.isIdle)
        try await f.drain()
        #expect(f.host.meetings["m1"]?.minutes?.status == .done)
    }

    @Test func 启动时把排队中和生成中的会议重新排队() async throws {
        let f = Fixture()
        f.pipeline.isSuspended = true
        // endedAt 近似入队的先后；上次正在生成的排最前
        var queuedLate = f.addMeeting("queued-late", minutes: MinutesState(status: .queued))
        queuedLate.endedAt = at(900)
        f.host.meetings[queuedLate.id] = queuedLate
        let queuedEarly = f.addMeeting("queued-early", minutes: MinutesState(status: .queued))
        f.addMeeting("running", minutes: MinutesState(status: .running))
        let done = f.addMeeting("done", minutes: MinutesState(status: .done))
        let failed = f.addMeeting("failed", minutes: MinutesState(status: .failed, error: "x"))
        let legacy = f.addMeeting("legacy")
        // 上次生成中的会议原来有一份周会纪要：沿用周会模板
        f.pipeline.enqueue("running", template: MinutesTemplate(key: "weekly"))
        f.pipeline.isSuspended = false
        try await f.drain()
        f.host.setMinutes(MinutesState(status: .running), for: "running")
        f.pipeline.isSuspended = true

        f.pipeline.restore([queuedLate, done, queuedEarly, legacy, f.host.meetings["running"]!, failed])

        #expect(f.pipeline.queue == ["running", "queued-early", "queued-late"])
        f.pipeline.isSuspended = false
        try await f.drain()
        for id in ["running", "queued-early", "queued-late"] {
            #expect(f.host.meetings[id]?.minutes?.status == .done)
        }
        #expect(try f.store.loadMinutes("running")?.template == "weekly")
        #expect(try f.store.loadMinutes("queued-early")?.template == "general")
        #expect(f.host.meetings["legacy"]?.minutes == nil)
        #expect(f.host.meetings["done"]?.minutes?.status == .done)
        #expect(f.host.meetings["failed"]?.minutes?.status == .failed)
    }

    @Test func 转写完成后_内容够长且自动生成开着才自动排队() async throws {
        let f = Fixture()
        f.pipeline.isSuspended = true
        f.addMeeting("long")
        // 49 个有效字：标点和空白不算
        f.addMeeting("short", transcript: makeTranscript([String(repeating: "嗯", count: 40) + "，。 ！",
                                                          String(repeating: "好", count: 9)]))
        f.addMeeting("off")

        #expect(f.pipeline.transcriptionFinished("long"))
        #expect(!f.pipeline.transcriptionFinished("short"))
        f.pipeline.autoGenerate = false
        #expect(!f.pipeline.transcriptionFinished("off"))

        #expect(f.pipeline.queue == ["long"])
        #expect(try f.store.loadTranscript("short")?.effectiveTextCount == 49)
        let long = try #require(try f.store.loadTranscript("long"))
        #expect(long.effectiveTextCount == 56)
    }

    @Test func 重新转写后_没有人工改动的纪要沿用原模板自动重新排队_有改动的不动() async throws {
        let f = Fixture()
        f.addMeeting("clean")
        f.addMeeting("edited")
        f.addMeeting("broken")
        f.pipeline.enqueue("clean", template: MinutesTemplate(key: "review"))
        f.pipeline.enqueue("edited")
        try await f.drain()
        var edited = try #require(try f.store.loadMinutes("edited"))
        edited.sections[0].items[0].deleted = true
        try f.store.saveMinutes(edited, for: "edited")
        try Data("坏了".utf8).write(to: f.store.directory("broken").appendingPathComponent("minutes.json"))
        f.pipeline.isSuspended = true

        for id in ["clean", "edited", "broken"] {
            try f.store.saveTranscript(makeTranscript(createdAt: at(7200)), for: id)
        }
        #expect(f.pipeline.transcriptionFinished("clean"))
        #expect(!f.pipeline.transcriptionFinished("edited"))
        #expect(!f.pipeline.transcriptionFinished("broken"))
        f.pipeline.isSuspended = false
        try await f.drain()

        let clean = try #require(try f.store.loadMinutes("clean"))
        #expect(clean.template == "review")
        #expect(clean.source.transcriptCreatedAt == at(7200))
        #expect(try f.store.loadMinutes("edited") == edited)
    }

    /// 人工改动按修改数算：加了又删的手动条目等于没改，重新转写后照样自动重新生成
    @Test func 重新转写后_修改数为零的纪要自动重新排队() async throws {
        let f = Fixture()
        f.addMeeting("m1")
        f.pipeline.enqueue("m1")
        try await f.drain()
        var minutes = try #require(try f.store.loadMinutes("m1"))
        let id = minutes.addItem(to: .overview, text: "写错了")
        minutes.delete(item: try #require(id))
        try f.store.saveMinutes(minutes, for: "m1")
        f.pipeline.isSuspended = true

        try f.store.saveTranscript(makeTranscript(createdAt: at(7200)), for: "m1")

        #expect(f.pipeline.transcriptionFinished("m1"))
    }

    /// 用户“按周会重新生成”后排队等转写，转写完成自动排队（不带模板）时保留用户选的模板
    @Test func 已排队时再次排队不带模板_保留排队时选的模板() async throws {
        let f = Fixture()
        f.addMeeting("m1")
        f.pipeline.enqueue("m1")
        try await f.drain()
        #expect(try f.store.loadMinutes("m1")?.template == "general")
        f.pipeline.isSuspended = true

        f.pipeline.enqueue("m1", template: MinutesTemplate(key: "weekly"), now: true)
        try f.store.saveTranscript(makeTranscript(createdAt: at(7200)), for: "m1")
        #expect(f.pipeline.transcriptionFinished("m1"))
        f.pipeline.isSuspended = false
        try await f.drain()

        #expect(try f.store.loadMinutes("m1")?.template == "weekly")
    }

    @Test func 进度只在内存里_完成和失败时回调() async throws {
        let engine = FakeGenerator()
        engine.block = true
        let f = Fixture(engine)
        var finished: [(String, MinutesOutcome)] = []
        f.pipeline.onFinish = { finished.append(($0, $1)) }
        f.addMeeting("m1")
        f.addMeeting("m2")
        f.pipeline.enqueue("m1")
        var started = f.engine.started.makeAsyncIterator()
        await started.next()

        try await f.until { f.pipeline.activity(for: "m1") == .generating(0) }
        #expect(f.pipeline.activity(for: "m2") == nil)

        engine.block = false
        try await f.drain()
        #expect(f.pipeline.activity == nil)
        engine.respond = { _ in "{}" }
        f.pipeline.enqueue("m2")
        try await f.drain()

        let minutes = try #require(try f.store.loadMinutes("m1"))
        #expect(finished.map(\.0) == ["m1", "m2"])
        #expect(finished.map(\.1) == [.done(minutes), .failed("模型输出无法解析")])
    }

    @Test func 等转写的纪要用的是这次转写写出的转写稿() async throws {
        // 重新转写时这场会议的纪要排在后面等：转写稿写好之后纪要才能读快照
        let f = Fixture()
        let (transcription, transcriber) = f.makeTranscription()
        transcriber.block = true
        f.addMeeting("m1")
        transcription.enqueue("m1")
        try await f.until { transcriber.calls == 1 }
        f.pipeline.enqueue("m1")

        transcriber.block = false
        try await f.drain()

        let minutes = try #require(try f.store.loadMinutes("m1"))
        let transcript = try #require(try f.store.loadTranscript("m1"))
        #expect(transcript.sentences.map(\.text) == ["重新转写出来的一句话，内容足够长"])
        #expect(minutes.sync(with: transcript) == .inSync)
    }

    // MARK: - 转写完成后纪要的去向（决定转写通知）

    /// 同 App 的接法：在转写管线的 onFinish 里自动排队，紧接着问纪要接下来会怎样
    private func followUpAfterTranscription(modelDownloaded: Bool, onPower: Bool,
                                            autoGenerate: Bool = true) async throws -> MinutesFollowUp? {
        let engine = FakeGenerator()
        engine.isDownloaded = modelDownloaded
        let f = Fixture(engine)
        f.pipeline.isOnPower = onPower
        f.pipeline.autoGenerate = autoGenerate
        let (transcription, transcriber) = f.makeTranscription()
        transcriber.text = String(repeating: "张三下周三之前把报价单发给客户。", count: 4)
        var followUp: MinutesFollowUp?
        transcription.onFinish = { id, _ in
            f.pipeline.transcriptionFinished(id)
            followUp = f.pipeline.followUp(for: id)
        }
        f.addMeeting("m1", transcript: nil)
        transcription.enqueue("m1")
        try await f.until { followUp != nil }
        // 能开始的纪要等它生成完再结束，免得测试结束时还在后台跑；在等电源、模型的排不空
        try await f.until { transcription.isIdle }
        if modelDownloaded && onPower && autoGenerate { try await f.drain() }
        return followUp
    }

    /// 模型就绪且接着电源：只等这场转写收尾，马上就开始，不发转写通知
    @Test func 转写完成时_模型就绪且接电_纪要马上开始() async throws {
        #expect(try await followUpAfterTranscription(modelDownloaded: true, onPower: true)
            == .queued(waitingFor: .transcription))
    }

    @Test func 转写完成时_用电池_纪要等接通电源() async throws {
        #expect(try await followUpAfterTranscription(modelDownloaded: true, onPower: false)
            == .queued(waitingFor: .power))
    }

    /// 两项都不满足时先说模型：要用户动手下载，接上电源也开始不了
    @Test(arguments: [true, false])
    func 转写完成时_模型未下载_纪要等下载模型(onPower: Bool) async throws {
        #expect(try await followUpAfterTranscription(modelDownloaded: false, onPower: onPower)
            == .queued(waitingFor: .model))
    }

    @Test func 转写完成时_自动生成关着_纪要不排队() async throws {
        #expect(try await followUpAfterTranscription(modelDownloaded: false, onPower: false, autoGenerate: false)
            == .notQueued)
    }

    @Test func 正在生成的会议算已排队且不用等() async throws {
        let engine = FakeGenerator()
        engine.block = true
        let f = Fixture(engine)
        f.addMeeting("m1")
        f.addMeeting("m2")
        f.pipeline.enqueue("m1")
        var started = f.engine.started.makeAsyncIterator()
        await started.next()

        #expect(f.pipeline.followUp(for: "m1") == .queued(waitingFor: nil))
        #expect(f.pipeline.followUp(for: "m2") == .notQueued)
        f.engine.block = false
        try await f.drain()
    }
}
