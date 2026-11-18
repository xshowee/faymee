import Foundation
import Testing
@testable import FaymeeCore

private final class StubTranscriber: Transcriber, @unchecked Sendable {
    var sentences: [TranscribedSentence]
    private(set) var calls = 0
    /// 为 true 时转写停在中途，直到改回 false
    var block = false
    let started: AsyncStream<Void>
    private let startedCont: AsyncStream<Void>.Continuation

    init(sentences: [TranscribedSentence] = [TranscribedSentence(start: 0, end: 1, text: "本地参考")]) {
        self.sentences = sentences
        (started, startedCont) = AsyncStream.makeStream()
    }

    func prepare(progress: @escaping (Double) -> Void) async throws {
        progress(1)
    }

    func transcribe(audio: URL, hotwords: [String],
                    progress: @escaping (Double) -> Void) async throws -> [TranscribedSentence] {
        calls += 1
        startedCont.yield()
        while block { try await Task.sleep(for: .milliseconds(5)) }
        return sentences
    }
}

/// 假下载源：什么地址都回“abc”（`WiringFixture.fakeASR` 的内容）
private struct ABCTransport: ModelTransport {
    func get(_ url: URL, from offset: Int64) async throws -> ModelResponse {
        let data = Data(Data("abc".utf8).suffix(from: Int(offset)))
        let body = AsyncThrowingStream<Data, Error> { c in
            c.yield(data)
            c.finish()
        }
        return ModelResponse(status: offset == 0 ? 200 : 206,
                             contentRange: offset == 0 ? nil : "bytes \(offset)-2/3",
                             contentLength: Int64(data.count), body: body)
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
            local: { (localStub, "apple/speechanalyzer", nil) },
            reference: { referenceStub }
        )
        #expect(localResolved.name == "apple/speechanalyzer")
        #expect(localResolved.waitReason == nil)
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
            local: { (localStub, "apple/speechanalyzer", nil) },
            reference: { referenceStub }
        )
        #expect(openAIResolved.name == "openai/gpt-transcribe")
        #expect(openAIResolved.waitReason == nil)

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

    // MARK: - 纪要模型从目录选择

    @Test func 切换纪要模型_进行中的用旧模型跑完_排队的和之后的用新模型() async throws {
        let f = WiringFixture()
        f.minutes.isOnPower = true
        f.addMeeting("m1")
        f.addMeeting("m2")

        f.localGenerator.block = true
        f.minutes.enqueue("m1")
        var started = f.localGenerator.started.makeAsyncIterator()
        await started.next()
        f.minutes.enqueue("m2")

        // m1 生成中切到第二个模型
        f.selections.select(WiringFixture.secondMinutesID, for: .minutes)
        #expect(f.minutes.activeID == "m1")

        f.localGenerator.block = false
        try await f.drain()
        #expect(try f.store.loadMinutes("m1")?.model == "llama/qwen3-4b-q4km")
        #expect(try f.store.loadMinutes("m2")?.model == WiringFixture.secondMinutesID)
        #expect(f.localGenerator.generateCalls == 1)
        #expect(f.secondGenerator.generateCalls == 1)
        // 旧模型跑完后释放
        #expect(f.localGenerator.unloadCalls >= 1)

        // “重新生成”用当前选择
        f.minutes.enqueue("m1")
        try await f.drain()
        #expect(try f.store.loadMinutes("m1")?.model == WiringFixture.secondMinutesID)
        #expect(f.localGenerator.generateCalls == 1)
        #expect(f.secondGenerator.generateCalls == 2)
    }

    @Test func 切到未下载的纪要模型_排队等下载_下好后自动开始() async throws {
        let f = WiringFixture()
        f.minutes.isOnPower = true
        f.secondGenerator.downloaded = false
        f.selections.select(WiringFixture.secondMinutesID, for: .minutes)

        f.addMeeting("m1")
        f.minutes.enqueue("m1")
        #expect(f.minutes.waitReason(for: "m1") == .model)

        f.secondGenerator.downloaded = true
        f.minutes.modelAvailabilityChanged()
        try await f.drain()
        #expect(try f.store.loadMinutes("m1")?.model == WiringFixture.secondMinutesID)
    }

    @Test func 纪要模型选择不变不重建引擎_在线模式下切换等回到本机才生效() async throws {
        let f = WiringFixture()
        f.minutes.isOnPower = true
        let builds = f.localGeneratorBuildCount
        f.selections.select("llama/qwen3-4b-q4km", for: .minutes)
        #expect(f.localGeneratorBuildCount == builds)

        f.settings.minutesMode = .online
        let onlineBuilds = f.localGeneratorBuildCount
        f.selections.select(WiringFixture.secondMinutesID, for: .minutes)
        #expect(f.localGeneratorBuildCount == onlineBuilds)

        f.settings.minutesMode = .local
        f.addMeeting("m1")
        f.minutes.enqueue("m1")
        try await f.drain()
        #expect(try f.store.loadMinutes("m1")?.model == WiringFixture.secondMinutesID)
    }

    // MARK: 会后转写的本机模型

    @Test func 切换本机转写模型_进行中的用旧模型跑完_排队的和之后的用新模型() async throws {
        let f = WiringFixture()
        try await f.downloadFakeASR()
        f.addMeeting("m1")
        f.addMeeting("m2")

        f.localTranscriber.block = true
        f.transcription.enqueue("m1")
        var started = f.localTranscriber.started.makeAsyncIterator()
        await started.next()
        f.transcription.enqueue("m2")

        // m1 转写中切到假模型：不打断 m1
        f.selections.select(WiringFixture.fakeASRID, for: .transcription)
        #expect(f.transcription.activeID == "m1")

        f.localTranscriber.block = false
        try await f.drain()
        #expect(try f.store.loadTranscript("m1")?.engine == "apple/speechanalyzer")
        #expect(try f.store.loadTranscript("m2")?.engine == WiringFixture.fakeASRID)
        #expect(try f.store.loadTranscript("m2")?.onlineEngineLabel == nil)
        #expect(f.localTranscriber.calls == 1)
        #expect(f.fakeASRTranscriber.calls == 1)

        // “重新转写”用当前选择
        f.transcription.enqueue("m1")
        try await f.drain()
        #expect(try f.store.loadTranscript("m1")?.engine == WiringFixture.fakeASRID)
    }

    @Test func 选了没下载的转写模型_排队等下载这个模型_下载完成后自动开始() async throws {
        let f = WiringFixture()
        f.selections.select(WiringFixture.fakeASRID, for: .transcription)
        f.addMeeting("m1", transcribed: false)
        f.transcription.enqueue("m1")
        try await f.drain()
        #expect(f.transcription.waitReason(for: "m1") == .modelDownload(id: WiringFixture.fakeASRID))
        #expect(f.fakeASRTranscriber.calls == 0)

        // 用户点“下载”：下好后排队的会议自动开始，不用再碰设置
        try await f.downloadFakeASR()
        try await f.drain()
        #expect(f.host.meetings["m1"]?.transcription?.status == .done)
        #expect(try f.store.loadTranscript("m1")?.engine == WiringFixture.fakeASRID)

        // 删掉模型：之后的会议又排队等下载
        try await f.fakeASRDownloader.delete()
        f.addMeeting("m2", transcribed: false)
        f.transcription.enqueue("m2")
        #expect(f.transcription.waitReason(for: "m2") == .modelDownload(id: WiringFixture.fakeASRID))
    }

    @Test func 在线转写时本机模型下载完成或删除不影响在线引擎() async throws {
        let f = WiringFixture()
        f.selections.select(WiringFixture.fakeASRID, for: .transcription)

        // 在线未配置：下好本机模型也照样等配置，不会用没有密钥的在线引擎开始
        f.settings.transcriptionMode = .online
        f.settings.transcriptionProvider = .openAI
        f.addMeeting("m1", transcribed: false)
        f.transcription.enqueue("m1")
        try await f.downloadFakeASR()
        try await f.drain()
        #expect(f.transcription.waitReason(for: "m1") == .onlineConfig)
        #expect(f.fakeASRTranscriber.calls == 0)

        // 在线配好后：删掉本机模型不让在线转写排队
        try f.transport.enqueue(json: ["text": "这是在线转写结果。"])
        f.settings.transcriptionAPIKey = "sk-openai"
        try await f.drain()
        #expect(try f.store.loadTranscript("m1")?.engine == "openai/gpt-transcribe")
        try await f.fakeASRDownloader.delete()
        try f.transport.enqueue(json: ["text": "这是在线转写结果。"])
        f.addMeeting("m2", transcribed: false)
        f.transcription.enqueue("m2")
        #expect(f.transcription.waitReason(for: "m2") == nil)
        try await f.drain()
        #expect(try f.store.loadTranscript("m2")?.engine == "openai/gpt-transcribe")

        // 回到本机：所选模型没下载，排队等下载
        f.settings.transcriptionMode = .local
        f.addMeeting("m3", transcribed: false)
        f.transcription.enqueue("m3")
        #expect(f.transcription.waitReason(for: "m3") == .modelDownload(id: WiringFixture.fakeASRID))
    }
}

private final class StubGenerator: TextGenerator, @unchecked Sendable {
    let modelID: String
    let contextTokens = 8_192
    var block = false
    var downloaded = true
    private(set) var unloadCalls = 0
    private(set) var generateCalls = 0
    let started: AsyncStream<Void>
    private let startedCont: AsyncStream<Void>.Continuation

    init(modelID: String) {
        self.modelID = modelID
        (started, startedCont) = AsyncStream.makeStream()
    }

    var isDownloaded: Bool { downloaded }
    func countTokens(_ text: String) -> Int { max(1, text.count) }
    func load(progress: @escaping (Double) -> Void) async throws { progress(1) }
    func unload() { unloadCalls += 1 }
    func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        generateCalls += 1
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
    /// 目录里假的第二个纪要模型
    let secondGenerator = StubGenerator(modelID: WiringFixture.secondMinutesID)
    static let secondMinutesID = "llama/fake-2b"
    /// 两个 llamaGGUF 纪要模型的目录：Qwen3 4B（默认）和一个假的
    static let catalog = ModelCatalog(models: ModelCatalog.builtIn.models + [
        CatalogModel(id: secondMinutesID, roles: [.minutes], family: .llamaGGUF,
                     source: .download(LocalModel(id: secondMinutesID, fileName: "fake-2b.gguf", size: 3,
                                                  sha256: "", downloadURLs: [])),
                     name: "假模型 2B", parameters: ModelParameters(contextTokens: 4096)),
        CatalogModel(id: fakeASRID, roles: [.transcription], family: .sherpaParaformer,
                     source: .download(fakeASR), name: "假转写模型"),
    ])
    /// 假的本机转写模型（会后转写）：要下载，文件内容是“abc”（`ABCTransport` 给的）
    static let fakeASRID = "sherpa-onnx/fake-asr"
    static let fakeASR = LocalModel(id: fakeASRID, fileName: "fake-asr.bin", size: 3,
                                    sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                                    downloadURLs: [URL(string: "https://models.example/fake-asr.bin")!])
    /// 假转写模型的转写器
    let fakeASRTranscriber = StubTranscriber(sentences: [
        TranscribedSentence(start: 0.1, end: 0.9, text: "这是假转写模型的结果"),
    ])
    /// 本机模型目录（临时）和它的下载器
    let modelsDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FaymeeWiringModels-\(UUID().uuidString)", isDirectory: true)
    let downloads: ModelDownloads
    let selections: ModelSelections
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
        selections = ModelSelections(defaults: defaults, catalog: Self.catalog, isExistingInstall: { true })
        downloads = ModelDownloads(catalog: Self.catalog, directory: modelsDirectory, transport: ABCTransport())

        let transcribers = [ModelCatalog.speechAnalyzerID: localTranscriber, Self.fakeASRID: fakeASRTranscriber]
        let downloads = downloads
        let refT = referenceTranscriber
        let generators = [localGenerator.modelID: localGenerator, secondGenerator.modelID: secondGenerator]
        let selections = selections
        let counter = buildCounter

        let makeT: @MainActor (OnlineModelSettings, any HTTPTransport) -> (transcriber: any Transcriber, name: String, waitReason: TranscriptionWaitReason?) = { s, t in
            OnlineTranscriptionEngine.makeEngine(
                settings: s,
                transport: t,
                local: {
                    // 和 LocalTranscriptionEngine.make 一样：所选目录项，没下完时等下载它
                    let model = selections.selected(for: .transcription)!
                    return (transcribers[model.id]!, model.id,
                            downloads.isReady(model) ? nil : .modelDownload(id: model.id))
                },
                reference: { refT }
            )
        }
        let makeM: @MainActor (OnlineModelSettings, any HTTPTransport) -> (generator: any TextGenerator, name: String, requiresPower: Bool, isOnline: Bool) = { s, t in
            OnlineMinutesEngine.makeEngine(
                settings: s,
                transport: t,
                local: {
                    counter.value += 1
                    let id = selections.selectedID(for: .minutes)!
                    return (generators[id]!, id)
                }
            )
        }

        let initialT = makeT(settings, transport)
        transcription = TranscriptionPipeline(
            store: store,
            transcriber: initialT.transcriber,
            engine: initialT.name,
            isEngineReady: initialT.waitReason == nil,
            engineWaitReason: initialT.waitReason ?? .onlineConfig,
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
            selections: selections,
            downloads: downloads,
            syncDebounce: syncDebounce,
            dashScopeTestPollInterval: .milliseconds(1)
        )
        coordinator.bind(transcription: transcription, minutes: minutes)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: store.root)
        try? FileManager.default.removeItem(at: modelsDirectory)
    }

    var fakeASRDownloader: ModelDownloader {
        downloads.downloader(for: Self.catalog.model(id: Self.fakeASRID)!)!
    }

    /// 点“下载”并等它下完
    func downloadFakeASR() async throws {
        fakeASRDownloader.start()
        await fakeASRDownloader.waitUntilFinished()
        #expect(fakeASRDownloader.isReady)
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
