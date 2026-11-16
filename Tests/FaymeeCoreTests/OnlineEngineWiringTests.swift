import Foundation
import Testing
@testable import FaymeeCore

private final class StubTranscriber: Transcriber, @unchecked Sendable {
    var sentences: [TranscribedSentence]
    private(set) var calls = 0

    init(sentences: [TranscribedSentence] = [TranscribedSentence(start: 0, end: 1, text: "本地参考")]) {
        self.sentences = sentences
    }

    func prepare(progress: @escaping (Double) -> Void) async throws {
        progress(1)
    }

    func transcribe(audio: URL, hotwords: [String],
                    progress: @escaping (Double) -> Void) async throws -> [TranscribedSentence] {
        calls += 1
        return sentences
    }
}

@MainActor
@Suite struct OnlineEngineWiringTests {
    private func makeSettings() -> (settings: OnlineModelSettings, cleanup: () -> Void) {
        let suite = "com.faymee.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = OnlineModelSettings(defaults: defaults, credentials: InMemoryCredentialStore())
        return (settings, { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func 在线转写工厂按模式与服务商分派_OpenAI兼容注入参考转写器() async throws {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }

        let localStub = StubTranscriber(sentences: [TranscribedSentence(start: 0, end: 1, text: "本地")])
        let referenceStub = StubTranscriber(sentences: [
            TranscribedSentence(start: 0.1, end: 0.9, text: "今天开会讨论新方案"),
        ])
        let transport = FakeHTTPTransport()

        // 默认本机模式
        let localResolved = OnlineTranscriptionEngine.makeEngine(
            settings: settings,
            transport: transport,
            local: { (localStub, "apple/speechanalyzer") },
            reference: { referenceStub }
        )
        #expect(localResolved.name == "apple/speechanalyzer")
        #expect(localResolved.isReady)
        let localOut = try await localResolved.transcriber.transcribe(audio: URL(fileURLWithPath: "/tmp/unused.wav"),
                                                                      hotwords: [], progress: { _ in })
        #expect(localOut.first?.text == "本地")
        #expect(transport.requests.isEmpty)

        // 切到 OpenAI 纯文本响应：会调用注入的 referenceTranscriber 完成本地时间轴对齐
        settings.transcriptionMode = .online
        settings.transcriptionProvider = .openAI
        settings.transcriptionAPIKey = "sk-openai"
        transport.enqueue(HTTPResponse.text(#"{"text":"今天开会讨论新方案。"}"#, status: 200))

        let openAIResolved = OnlineTranscriptionEngine.makeEngine(
            settings: settings,
            transport: transport,
            local: { (localStub, "apple/speechanalyzer") },
            reference: { referenceStub }
        )
        #expect(openAIResolved.name == "openai/gpt-transcribe")
        #expect(openAIResolved.isReady)

        try await ProbeAudio.withTemporaryWAV { wavURL in
            let sentences = try await openAIResolved.transcriber.transcribe(audio: wavURL, hotwords: [], progress: { _ in })
            #expect(sentences.map(\.text) == ["今天开会讨论新方案。"])
        }
        #expect(referenceStub.calls == 1)
        #expect(transport.requests.first?.url.path.hasSuffix("/audio/transcriptions") == true)
    }

    @Test func 在线转写连接测试按服务商分派() async throws {
        let transport = FakeHTTPTransport()
        // 百炼四步：policy -> upload -> submit -> poll(SUCCEEDED) -> result json
        try transport.enqueue(json: [
            "data": [
                "upload_host": "https://upload.example.com",
                "policy": "p",
                "signature": "s",
                "oss_access_key_id": "id",
                "upload_dir": "dir",
            ]
        ])
        transport.enqueue(HTTPResponse(status: 200))
        try transport.enqueue(json: ["output": ["task_id": "t1"]])
        try transport.enqueue(json: [
            "output": [
                "task_status": "SUCCEEDED",
                "results": [["transcription_url": "https://result.example.com/1.json"]],
            ]
        ])
        try transport.enqueue(json: [
            "transcripts": [[
                "sentences": [["begin_time": 0, "end_time": 500, "text": "你好。"]]
            ]]
        ])

        let dashConfig = OnlineEndpointConfig(
            baseURL: "https://dashscope.aliyuncs.com/api/v1",
            model: "qwen3-asr-flash-filetrans",
            apiKey: "sk-dash",
            requiresHTTPS: true,
            requiresAPIKey: true,
            providerID: "dashscope"
        )
        try await OnlineTranscriptionEngine.testConnection(
            provider: .dashScope,
            config: dashConfig,
            transport: transport,
            dashScopePollInterval: .milliseconds(1)
        )
        #expect(transport.requests.count == 5)

        // OpenAI / Groq / 自定义：走 /audio/transcriptions
        let groqTransport = FakeHTTPTransport()
        try groqTransport.enqueue(json: ["text": "ok"])
        let groqConfig = OnlineEndpointConfig(
            baseURL: "https://api.groq.com/openai/v1",
            model: "whisper-large-v3-turbo",
            apiKey: "gsk-test",
            requiresHTTPS: true,
            requiresAPIKey: true,
            providerID: "groq"
        )
        try await OnlineTranscriptionEngine.testConnection(
            provider: .groq,
            config: groqConfig,
            transport: groqTransport
        )
        #expect(groqTransport.requests.count == 1)
        #expect(groqTransport.requests.first?.url.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
    }

    @Test func 在线纪要工厂按模式分派() {
        let (settings, cleanup) = makeSettings()
        defer { cleanup() }
        let localGen = StubGenerator(modelID: "llama/qwen3-4b-q4km")
        let transport = FakeHTTPTransport()

        let localResolved = OnlineMinutesEngine.makeEngine(
            settings: settings,
            transport: transport,
            local: { (localGen, "llama/qwen3-4b-q4km") }
        )
        #expect(localResolved.name == "llama/qwen3-4b-q4km")
        #expect(localResolved.requiresPower)
        #expect(!localResolved.isOnline)

        settings.minutesMode = .online
        settings.minutesProvider = .anthropic
        settings.minutesAPIKey = "sk-ant"
        let onlineResolved = OnlineMinutesEngine.makeEngine(
            settings: settings,
            transport: transport,
            local: { (localGen, "llama/qwen3-4b-q4km") }
        )
        #expect(onlineResolved.name == "anthropic/claude-sonnet-4-5")
        #expect(!onlineResolved.requiresPower)
        #expect(onlineResolved.isOnline)
        #expect(onlineResolved.generator is AnthropicTextGenerator)
    }

    @Test func 协调器默认本机运行_切到未配置在线转写时排队等待并放行区分说话人_补齐后热生效() async throws {
        let f = WiringFixture()
        f.addMeeting("m1")

        // 默认本机模式，不发任何 HTTP 请求，且本机转写与本机区分说话人正常跑完
        f.transcription.enqueue("m1")
        try await f.drain()

        let t1 = try #require(try f.store.loadTranscript("m1"))
        #expect(t1.engine == "apple/speechanalyzer")
        #expect(t1.onlineEngineLabel == nil)
        #expect(t1.diarization?.engine == "fake/diarizer")
        #expect(f.transport.requests.isEmpty)

        // 切到在线转写但未填 API Key：完整转写排队等待在线配置，只区分说话人不受阻塞
        f.settings.transcriptionMode = .online
        f.settings.transcriptionProvider = .openAI

        f.addMeeting("m2", transcribed: false)
        f.transcription.enqueue("m2")
        f.transcription.enqueueDiarization("m1")
        try await f.drain()

        #expect(f.transcription.waitReason(for: "m2") == .onlineConfig)
        #expect(f.host.meetings["m2"]?.transcription?.status == .queued)
        #expect(f.host.meetings["m1"]?.diarization?.status == .done)
        #expect(f.diarizer.calls == 2)
        // 本地纪要引擎未受转写配置修改影响（未触发重建/卸载）
        #expect(f.localGeneratorBuildCount == 1)
        #expect(f.localGenerator.unloadCalls == 0)

        // 补齐 API Key 后自动启动排队中的 m2，并保留本机说话人区分
        try f.transport.enqueue(json: ["text": "这是在线转写结果。"])
        f.settings.transcriptionAPIKey = "sk-openai"
        try await f.drain()

        let t2 = try #require(try f.store.loadTranscript("m2"))
        #expect(t2.engine == "openai/gpt-transcribe")
        #expect(t2.onlineEngineLabel == "openai/gpt-transcribe")
        #expect(t2.diarization?.engine == "fake/diarizer")
    }

    @Test func 协调器切到在线纪要卸载空闲本机模型_共用百炼密钥后电池下自动生成() async throws {
        let f = WiringFixture()
        f.minutes.isOnPower = false
        f.addMeeting("m1")

        // 先在本机下（now: true）跑一次并保持模拟已加载状态，验证切离本机时会卸载模型
        f.localGenerator.block = true
        f.minutes.enqueue("m1", now: true)
        var started = f.localGenerator.started.makeAsyncIterator()
        await started.next()

        // 在本地纪要运行中切到在线阿里云百炼（密钥留空）
        f.settings.minutesMode = .online
        f.settings.minutesProvider = .dashScope

        // 本场仍使用启动时的本机引擎跑完写盘，结束后卸载旧本机引擎
        f.localGenerator.block = false
        try await f.drain()
        #expect(try f.store.loadMinutes("m1")?.model == "llama/qwen3-4b-q4km")
        #expect(f.localGenerator.unloadCalls >= 1)

        // 电池下入队第二场：等待配置在线模型
        f.addMeeting("m2")
        f.minutes.enqueue("m2")
        #expect(f.minutes.waitReason(for: "m2") == .onlineConfig)

        // 从转写侧填入阿里云百炼密钥：纪要侧因共享槽位即时就绪，电池下直接自动开始生成
        try f.transport.enqueue(json: [
            "choices": [[
                "message": [
                    "content": #"{"overview":[{"text":"讨论完成","refs":["s1"]}],"decisions":[],"actions":[],"questions":[]}"#
                ]
            ]]
        ])
        f.settings.transcriptionProvider = .dashScope
        f.settings.transcriptionAPIKey = "sk-dash-shared"
        try await f.drain()

        let m2 = try #require(try f.store.loadMinutes("m2"))
        #expect(m2.model == "dashscope/qwen-plus")
        #expect(m2.onlineModelLabel == "dashscope/qwen-plus")
        #expect(f.host.meetings["m2"]?.minutes == MinutesState(status: .done))
    }

    @Test func 连接测试状态管理_切预设或重复触发取消过期请求并隔离结果() async throws {
        let f = WiringFixture()
        f.settings.minutesMode = .online
        f.settings.minutesProvider = .deepSeek
        f.settings.minutesAPIKey = "sk-ds"

        // 第一次请求挂起等待
        let firstStarted = AsyncStream<Void>.makeStream()
        let firstGate = AsyncStream<Void>.makeStream()
        f.transport.enqueue { _ in
            firstStarted.continuation.yield()
            for await _ in firstGate.stream {}
            return try HTTPResponse.json([
                "choices": [["message": ["content": #"{"ok":true}"#]]]
            ])
        }

        let staleTask = f.coordinator.testMinutesConnection()
        var startedIter = firstStarted.stream.makeAsyncIterator()
        await startedIter.next()
        #expect(f.coordinator.minutesTestState == .testing)

        // 切预设或改模型应立即取消过期测试并将状态复位为 .idle
        f.settings.minutesModel = "deepseek-reasoner"
        #expect(f.coordinator.minutesTestState == .idle)
        firstGate.continuation.finish()
        await staleTask.value
        #expect(f.coordinator.minutesTestState == .idle)
        #expect(f.transport.cancelledRequests.count == 1)

        // 返回 401 鉴权失败：报错文本可见
        try f.transport.enqueue(json: ["error": ["message": "Invalid key"]], status: 401)
        await f.coordinator.testMinutesConnection().value
        if case let .failed(msg) = f.coordinator.minutesTestState {
            #expect(msg.contains("401"))
        } else {
            Issue.record("预期为 failed 状态，实际为 \(f.coordinator.minutesTestState)")
        }

        // 转写侧独立测试：连续触发两次应取消前一次，以第二次结果为准
        f.settings.transcriptionMode = .online
        f.settings.transcriptionProvider = .openAI
        f.settings.transcriptionAPIKey = "sk-oa"

        let firstTStarted = AsyncStream<Void>.makeStream()
        let firstTGate = AsyncStream<Void>.makeStream()
        f.transport.enqueue { _ in
            firstTStarted.continuation.yield()
            for await _ in firstTGate.stream {}
            return HTTPResponse.text(#"{"error":{"message":"stale failure"}}"#, status: 500)
        }
        try f.transport.enqueue(json: ["text": "测试"])

        let staleT = f.coordinator.testTranscriptionConnection()
        var firstTIter = firstTStarted.stream.makeAsyncIterator()
        await firstTIter.next()
        #expect(f.coordinator.transcriptionTestState == .testing)

        let freshT = f.coordinator.testTranscriptionConnection()
        firstTGate.continuation.finish()
        await staleT.value
        await freshT.value
        #expect(f.coordinator.transcriptionTestState == .succeeded)

        // 验证四个 URL/模型字段修改都能安全同步并复位测试状态
        f.settings.transcriptionBaseURL = "https://proxy.example.com/v1"
        #expect(f.coordinator.transcriptionTestState == .idle)
        f.settings.minutesBaseURL = "https://ds-proxy.example.com/v1"
        #expect(f.coordinator.minutesTestState == .idle)

        // 正在测试时调用 cancelInFlightConnectionTests 会立即取消并复位
        let hangStarted = AsyncStream<Void>.makeStream()
        let hangGate = AsyncStream<Void>.makeStream()
        f.transport.enqueue { _ in
            hangStarted.continuation.yield()
            for await _ in hangGate.stream {}
            return try HTTPResponse.json(["text": "late"])
        }
        let cancelledTask = f.coordinator.testTranscriptionConnection()
        var hangIter = hangStarted.stream.makeAsyncIterator()
        await hangIter.next()
        f.coordinator.cancelInFlightConnectionTests()
        #expect(f.coordinator.transcriptionTestState == .idle)
        hangGate.continuation.finish()
        await cancelledTask.value
        #expect(f.coordinator.transcriptionTestState == .idle)
    }

    @Test func 防抖同步在停止输入后自动生效_flushSync立即同步() async throws {
        let f = WiringFixture(syncDebounce: .milliseconds(40))
        f.settings.transcriptionMode = .online
        f.settings.transcriptionProvider = .openAI
        f.addMeeting("m1", transcribed: false)
        f.transcription.enqueue("m1")
        #expect(f.transcription.waitReason(for: "m1") == .onlineConfig)

        // 连续写入两次文本配置：未到防抖时间且未 flush 前仍排队
        f.settings.transcriptionAPIKey = "sk-a"
        f.settings.transcriptionModel = "gpt-4o-transcribe"
        #expect(f.transcription.waitReason(for: "m1") == .onlineConfig)

        // 等待防抖自动触发后无需手动 flush 即开始转写
        try f.transport.enqueue(json: ["text": "自动防抖完成。"])
        for _ in 0..<50 where !f.transcription.isEngineReady {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.transcription.isEngineReady)
        try await f.drain()

        let transcript = try #require(try f.store.loadTranscript("m1"))
        #expect(transcript.engine == "openai/gpt-4o-transcribe")

        // flushSync 立即同步不等待防抖
        f.settings.transcriptionModel = "gpt-transcribe"
        f.coordinator.flushSync()
        try f.transport.enqueue(json: ["text": "立即同步完成。"])
        f.transcription.enqueue("m1")
        try await f.drain()
        let reloaded = try #require(try f.store.loadTranscript("m1"))
        #expect(reloaded.engine == "openai/gpt-transcribe")
    }
}

private final class StubGenerator: TextGenerator, @unchecked Sendable {
    let modelID: String
    let contextTokens = 8_192
    var block = false
    private(set) var unloadCalls = 0
    let started: AsyncStream<Void>
    private let startedCont: AsyncStream<Void>.Continuation

    init(modelID: String) {
        self.modelID = modelID
        (started, startedCont) = AsyncStream.makeStream()
    }

    var isDownloaded: Bool { true }
    func countTokens(_ text: String) -> Int { max(1, text.count) }
    func load(progress: @escaping (Double) -> Void) async throws { progress(1) }
    func unload() { unloadCalls += 1 }
    func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        startedCont.yield()
        while block { try await Task.sleep(for: .milliseconds(5)) }
        return #"{"overview":[{"text":"本机纪要","refs":["s1"]}],"decisions":[],"actions":[],"questions":[]}"#
    }
}

private final class StubDiarizer: SpeakerDiarizer, @unchecked Sendable {
    let engine = "fake/diarizer"
    let voiceprintModel = "fake/vp"
    private(set) var calls = 0

    func prepare(progress: @escaping (Double) -> Void) async throws { progress(1) }
    func diarize(audio: URL, sentences: [ClosedRange<TimeInterval>], speakerCount: Int?,
                 progress: @escaping (Double) -> Void) async throws -> DiarizationResult {
        calls += 1
        return DiarizationResult(
            segments: sentences.map { SpeakerSegment(start: $0.lowerBound, end: $0.upperBound, speaker: 0) },
            voiceprints: [:]
        )
    }
}

@MainActor
private final class WiringHost: TranscriptionHost, MinutesHost {
    let store: MeetingStore
    var meetings: [String: Meeting] = [:]

    init(store: MeetingStore) { self.store = store }
    func meeting(_ id: String) -> Meeting? { meetings[id] }
    func setTranscription(_ state: TranscriptionState, for id: String) {
        guard var m = meetings[id] else { return }
        m.transcription = state
        meetings[id] = m
        try! store.save(m)
    }
    func setDiarization(_ state: DiarizationState?, for id: String) {
        guard var m = meetings[id] else { return }
        m.diarization = state
        meetings[id] = m
        try! store.save(m)
    }
    func setMinutes(_ state: MinutesState, for id: String) {
        guard var m = meetings[id] else { return }
        m.minutes = state
        meetings[id] = m
        try! store.save(m)
    }
}

@MainActor
private final class WiringFixture {
    let suiteName = "com.faymee.wiring.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: MeetingStore
    let host: WiringHost
    let settings: OnlineModelSettings
    let transport = FakeHTTPTransport()
    let localTranscriber = StubTranscriber(sentences: [
        TranscribedSentence(start: 0.1, end: 0.9, text: String(repeating: "今天开会讨论项目进度和安排", count: 5)),
    ])
    let referenceTranscriber = StubTranscriber(sentences: [
        TranscribedSentence(start: 0.1, end: 0.9, text: "这是在线转写结果"),
    ])
    let diarizer = StubDiarizer()
    let localGenerator = StubGenerator(modelID: "llama/qwen3-4b-q4km")
    private final class Counter { var value = 0 }
    private let buildCounter = Counter()
    var localGeneratorBuildCount: Int { buildCounter.value }
    let transcription: TranscriptionPipeline
    let minutes: MinutesPipeline
    let coordinator: OnlineEngineCoordinator

    init(syncDebounce: Duration = .zero) {
        defaults = UserDefaults(suiteName: suiteName)!
        store = MeetingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("FaymeeWiringTests-\(UUID().uuidString)", isDirectory: true))
        host = WiringHost(store: store)
        settings = OnlineModelSettings(defaults: defaults, credentials: InMemoryCredentialStore())

        let localT = localTranscriber
        let refT = referenceTranscriber
        let localG = localGenerator
        let counter = buildCounter

        let makeT: @MainActor (OnlineModelSettings, any HTTPTransport) -> (transcriber: any Transcriber, name: String, isReady: Bool) = { s, t in
            OnlineTranscriptionEngine.makeEngine(
                settings: s,
                transport: t,
                local: { (localT, "apple/speechanalyzer") },
                reference: { refT }
            )
        }
        let makeM: @MainActor (OnlineModelSettings, any HTTPTransport) -> (generator: any TextGenerator, name: String, requiresPower: Bool, isOnline: Bool) = { s, t in
            OnlineMinutesEngine.makeEngine(
                settings: s,
                transport: t,
                local: {
                    counter.value += 1
                    return (localG, localG.modelID)
                }
            )
        }

        let initialT = makeT(settings, transport)
        transcription = TranscriptionPipeline(
            store: store,
            transcriber: initialT.transcriber,
            engine: initialT.name,
            isEngineReady: initialT.isReady,
            diarizer: diarizer,
            host: host
        )
        let initialM = makeM(settings, transport)
        minutes = MinutesPipeline(
            store: store,
            generator: initialM.generator,
            model: initialM.name,
            requiresPower: initialM.requiresPower,
            isOnlineEngine: initialM.isOnline,
            host: host
        )
        minutes.coordinate(with: transcription)

        coordinator = OnlineEngineCoordinator(
            settings: settings,
            transport: transport,
            makeTranscription: makeT,
            makeMinutes: makeM,
            syncDebounce: syncDebounce,
            dashScopeTestPollInterval: .milliseconds(1)
        )
        coordinator.bind(transcription: transcription, minutes: minutes)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: store.root)
    }

    func addMeeting(_ id: String, transcribed: Bool = true) {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var m = Meeting(
            id: id,
            title: "会议 \(id)",
            startedAt: t0,
            endedAt: t0.addingTimeInterval(60),
            status: .done,
            segments: [Segment(file: "0001.caf", startedAt: t0, sampleRate: 48_000, channels: 1,
                               device: "Mic", deviceUID: "BuiltIn", offset: 0, duration: 60)],
            recording: "recording.m4a",
            duration: 60
        )
        m.transcription = transcribed ? TranscriptionState(status: .done) : nil
        let dir = store.directory(id)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wavURL = dir.appendingPathComponent("recording.m4a")
        try! ProbeAudio.wavData().write(to: wavURL)
        if transcribed {
            let transcript = Transcript(
                engine: "apple/speechanalyzer",
                createdAt: t0,
                hotwords: [],
                items: [.sentence(TranscriptSentence(id: "s1", start: 0, end: 1,
                                                    text: String(repeating: "足够长的测试文本内容用于生成纪要", count: 5)))]
            )
            try! store.saveTranscript(transcript, for: id)
        }
        try! store.save(m)
        host.meetings[id] = m
    }

    func drain() async throws {
        for _ in 0..<200 {
            if transcription.activeID == nil && minutes.activeID == nil && !minutes.isEngineInUse {
                let pendingT = transcription.queue.contains { transcription.waitReason(for: $0) == nil }
                let pendingM = minutes.queue.contains { minutes.waitReason(for: $0) == nil }
                if !pendingT && !pendingM { return }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
