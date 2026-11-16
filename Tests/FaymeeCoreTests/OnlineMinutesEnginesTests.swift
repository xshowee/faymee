import Foundation
import Testing
@testable import FaymeeCore

private func makeOpenAIConfig(
    baseURL: String = "https://api.openai.com/v1",
    model: String = "gpt-4.1-mini",
    apiKey: String = "sk-test-key",
    requiresHTTPS: Bool = true,
    requiresAPIKey: Bool = true,
    providerID: String = "openai"
) -> OnlineEndpointConfig {
    OnlineEndpointConfig(
        baseURL: baseURL,
        model: model,
        apiKey: apiKey,
        requiresHTTPS: requiresHTTPS,
        requiresAPIKey: requiresAPIKey,
        providerID: providerID
    )
}

@Suite struct OpenAICompatibleTextGeneratorTests {
    @Test func 默认窗口与最大输出解耦_isDownloaded跟随配置就绪_load立即完成且unload无副作用() async throws {
        let readyConfig = makeOpenAIConfig()
        let unreadyConfig = makeOpenAIConfig(apiKey: "")
        let transport = FakeHTTPTransport()

        let ready = OpenAICompatibleTextGenerator(config: readyConfig, transport: transport)
        let unready = OpenAICompatibleTextGenerator(config: unreadyConfig, transport: transport)

        #expect(ready.contextTokens == 64_000)
        #expect(ready.maxOutputTokens == 8_192)
        #expect(ready.isDownloaded)
        #expect(!unready.isDownloaded)

        var progresses: [Double] = []
        try await ready.load { progresses.append($0) }
        #expect(progresses == [1.0])
        ready.unload()
    }

    @Test func 配置无效时generate直接报错不发网络请求() async {
        let transport = FakeHTTPTransport()
        let generator = OpenAICompatibleTextGenerator(
            config: makeOpenAIConfig(baseURL: "http://api.openai.com/v1"),
            transport: transport
        )

        await #expect(throws: OnlineAPIError.self) {
            _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 100)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func 发送标准ChatCompletions请求并剥离前导think标签() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: [
            "choices": [
                ["message": ["role": "assistant", "content": "<think>\n思考过程\n</think>\n{\"overview\":[]}"]]
            ]
        ])

        let generator = OpenAICompatibleTextGenerator(
            config: makeOpenAIConfig(baseURL: "https://api.deepseek.com/v1/", model: "deepseek-chat", apiKey: "sk-ds", providerID: "deepseek"),
            transport: transport
        )

        let result = try await generator.generate(system: "系统提示", prompt: "用户输入", maxTokens: 512, grammar: "root ::= \"x\"")

        #expect(result == #"{"overview":[]}"#)
        let recorded = try #require(transport.recordedRequests.first)
        #expect(recorded.request.method == "POST")
        #expect(recorded.request.url.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(recorded.header("authorization") == "Bearer sk-ds")
        #expect(recorded.header("content-type") == "application/json")

        let body = try #require(recorded.bodyJSONObject())
        #expect(body["model"] as? String == "deepseek-chat")
        #expect(body["max_tokens"] as? Int == 512)
        let responseFormat = try #require(body["response_format"] as? [String: String])
        #expect(responseFormat == ["type": "json_object"])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [
            ["role": "system", "content": "系统提示"],
            ["role": "user", "content": "用户输入"],
        ])
    }

    @Test func 自定义免密模式不附带Authorization请求头() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: [
            "choices": [["message": ["content": #"{"overview":[]}"#]]]
        ])

        let generator = OpenAICompatibleTextGenerator(
            config: makeOpenAIConfig(
                baseURL: "http://192.168.1.50:11434/v1",
                model: "qwen2.5:14b",
                apiKey: "   ",
                requiresHTTPS: false,
                requiresAPIKey: false,
                providerID: "openai-compatible"
            ),
            transport: transport
        )

        let result = try await generator.generate(system: "s", prompt: "p", maxTokens: 128)
        #expect(result == #"{"overview":[]}"#)
        let recorded = try #require(transport.recordedRequests.first)
        #expect(recorded.header("authorization") == nil)
        #expect(recorded.request.url.absoluteString == "http://192.168.1.50:11434/v1/chat/completions")
    }

    @Test func 服务端因json_object返回400时自动去掉response_format重试一次() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: ["error": ["message": "response_format is not supported"]], status: 400)
        try transport.enqueue(json: ["choices": [["message": ["content": #"{"overview":[{"text":"ok","refs":["s1"]}]}"#]]]])

        let generator = OpenAICompatibleTextGenerator(config: makeOpenAIConfig(), transport: transport)
        let result = try await generator.generate(system: "s", prompt: "p", maxTokens: 256)

        #expect(result == #"{"overview":[{"text":"ok","refs":["s1"]}]}"#)
        #expect(transport.recordedRequests.count == 2)
        let firstBody = try #require(transport.recordedRequests[0].bodyJSONObject())
        let secondBody = try #require(transport.recordedRequests[1].bodyJSONObject())
        #expect(firstBody["response_format"] != nil)
        #expect(secondBody["response_format"] == nil)
        #expect(secondBody["model"] as? String == "gpt-4.1-mini")
        #expect(secondBody["max_tokens"] as? Int == 256)
    }

    @Test func 去掉response_format重试仍返回400时抛出badRequest() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: ["error": ["message": "bad model"]], status: 400)
        try transport.enqueue(json: ["error": ["message": "bad model"]], status: 400)

        let generator = OpenAICompatibleTextGenerator(config: makeOpenAIConfig(), transport: transport)
        await #expect(throws: OnlineAPIError.badRequest(400, "bad model")) {
            _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 128)
        }
        #expect(transport.recordedRequests.count == 2)
    }

    @Test func HTTP错误状态_空内容与损坏JSON均转换为对应OnlineAPIError() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: ["error": ["message": "Invalid key"]], status: 401)
        try transport.enqueue(json: ["error": ["message": "Model missing"]], status: 404)
        try transport.enqueue(json: ["error": ["message": "Too many requests"]], status: 429)
        transport.enqueue(text: "Internal error", status: 500)
        try transport.enqueue(json: ["choices": [["message": ["content": "   "]]]])
        transport.enqueue(text: "not json", status: 200)

        let generator = OpenAICompatibleTextGenerator(config: makeOpenAIConfig(), transport: transport)

        await #expect(throws: OnlineAPIError.unauthorized(401, "Invalid key")) {
            _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 64)
        }
        await #expect(throws: OnlineAPIError.notFound("Model missing")) {
            _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 64)
        }
        await #expect(throws: OnlineAPIError.rateLimited("Too many requests")) {
            _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 64)
        }
        await #expect(throws: OnlineAPIError.serverError(500, "Internal error")) {
            _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 64)
        }
        await #expect(throws: OnlineAPIError.emptyResponse) {
            _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 64)
        }
        await #expect(throws: OnlineAPIError.self) {
            _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 64)
        }
    }

    @Test func 任务取消时立即传播CancellationError() async {
        let started = AsyncStream<Void>.makeStream()
        let transport = FakeHTTPTransport { _ in
            started.continuation.yield()
            try await Task.sleep(for: .seconds(10))
            return HTTPResponse(status: 200)
        }
        let generator = OpenAICompatibleTextGenerator(config: makeOpenAIConfig(), transport: transport)

        let task = Task {
            try await generator.generate(system: "s", prompt: "p", maxTokens: 64)
        }
        for await _ in started.stream { break }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(transport.cancelledRequests.count == 1)
    }
}

private func makeAnthropicConfig(
    baseURL: String = "https://api.anthropic.com/v1",
    model: String = "claude-sonnet-4-5",
    apiKey: String = "sk-ant-test"
) -> OnlineEndpointConfig {
    OnlineEndpointConfig(
        baseURL: baseURL,
        model: model,
        apiKey: apiKey,
        requiresHTTPS: true,
        requiresAPIKey: true,
        providerID: "anthropic"
    )
}

@Suite struct AnthropicTextGeneratorTests {
    @Test func 发送原生Messages请求并解析文本块_跳过thinking块() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: [
            "id": "msg_1",
            "content": [
                ["type": "thinking", "thinking": "先推理"],
                ["type": "text", "text": #"{"overview":[{"text":"讨论完成","refs":["s1"]}]}"#],
            ],
        ])

        let generator = AnthropicTextGenerator(
            config: makeAnthropicConfig(baseURL: "https://api.anthropic.com/v1/"),
            transport: transport
        )
        #expect(generator.contextTokens == 64_000)
        #expect(generator.maxOutputTokens == 8_192)
        #expect(generator.isDownloaded)

        let result = try await generator.generate(system: "系统约束", prompt: "会议内容", maxTokens: 1_024, grammar: "ignored")

        #expect(result == #"{"overview":[{"text":"讨论完成","refs":["s1"]}]}"#)
        let recorded = try #require(transport.recordedRequests.first)
        #expect(recorded.request.method == "POST")
        #expect(recorded.request.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(recorded.header("x-api-key") == "sk-ant-test")
        #expect(recorded.header("anthropic-version") == "2023-06-01")
        #expect(recorded.header("authorization") == nil)

        let body = try #require(recorded.bodyJSONObject())
        #expect(body["model"] as? String == "claude-sonnet-4-5")
        #expect(body["max_tokens"] as? Int == 1_024)
        #expect(body["system"] as? String == "系统约束")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "会议内容"]])
    }

    @Test func 鉴权失败_缺少content与空文本均抛出明确OnlineAPIError() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: ["error": ["message": "invalid x-api-key"]], status: 401)
        try transport.enqueue(json: ["id": "msg_bad"])
        try transport.enqueue(json: ["content": [["type": "thinking", "thinking": "only thinking"]]])

        let generator = AnthropicTextGenerator(config: makeAnthropicConfig(), transport: transport)

        await #expect(throws: OnlineAPIError.unauthorized(401, "invalid x-api-key")) {
            _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 128)
        }
        await #expect(throws: OnlineAPIError.self) {
            _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 128)
        }
        await #expect(throws: OnlineAPIError.emptyResponse) {
            _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 128)
        }
    }
}

private func makeGeminiConfig(
    baseURL: String = "https://generativelanguage.googleapis.com/v1beta",
    model: String = "gemini-2.5-flash",
    apiKey: String = "AIza-test-key"
) -> OnlineEndpointConfig {
    OnlineEndpointConfig(
        baseURL: baseURL,
        model: model,
        apiKey: apiKey,
        requiresHTTPS: true,
        requiresAPIKey: true,
        providerID: "gemini"
    )
}

@Suite struct GeminiTextGeneratorTests {
    @Test func 发送原生GenerateContent请求并剥离models前缀_跳过thought分片() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: [
            "candidates": [
                [
                    "content": [
                        "parts": [
                            ["text": "思考中", "thought": true],
                            ["text": #"{"overview":[{"text":"Gemini总结","refs":["s2"]}]}"#],
                        ]
                    ],
                    "finishReason": "STOP",
                ]
            ]
        ])

        let generator = GeminiTextGenerator(
            config: makeGeminiConfig(
                baseURL: "https://generativelanguage.googleapis.com/v1beta/",
                model: "models/gemini-2.5-flash"
            ),
            transport: transport
        )
        #expect(generator.contextTokens == 64_000)
        #expect(generator.maxOutputTokens == 8_192)
        #expect(generator.isDownloaded)

        let result = try await generator.generate(system: "系统指令", prompt: "转写内容", maxTokens: 2_048, grammar: "ignored")

        #expect(result == #"{"overview":[{"text":"Gemini总结","refs":["s2"]}]}"#)
        let recorded = try #require(transport.recordedRequests.first)
        #expect(recorded.request.method == "POST")
        #expect(recorded.request.url.absoluteString
            == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        #expect(recorded.header("x-goog-api-key") == "AIza-test-key")
        #expect(recorded.header("authorization") == nil)

        let body = try #require(recorded.bodyJSONObject())
        let systemInstruction = try #require(body["systemInstruction"] as? [String: Any])
        let systemParts = try #require(systemInstruction["parts"] as? [[String: String]])
        #expect(systemParts == [["text": "系统指令"]])

        let contents = try #require(body["contents"] as? [[String: Any]])
        #expect(contents.count == 1)
        #expect(contents[0]["role"] as? String == "user")
        let userParts = try #require(contents[0]["parts"] as? [[String: String]])
        #expect(userParts == [["text": "转写内容"]])

        let genConfig = try #require(body["generationConfig"] as? [String: Any])
        #expect(genConfig["maxOutputTokens"] as? Int == 2_048)
        #expect(genConfig["responseMimeType"] as? String == "application/json")
    }

    @Test func 安全拦截_空候选与HTTP错误转换为对应OnlineAPIError() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: ["promptFeedback": ["blockReason": "SAFETY"]])
        try transport.enqueue(json: ["candidates": []])
        try transport.enqueue(json: ["error": ["message": "API key not valid"]], status: 403)

        let generator = GeminiTextGenerator(config: makeGeminiConfig(), transport: transport)

        await #expect(throws: OnlineAPIError.remoteTaskFailed("内容被安全策略拦截（SAFETY）")) {
            _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 64)
        }
        await #expect(throws: OnlineAPIError.emptyResponse) {
            _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 64)
        }
        await #expect(throws: OnlineAPIError.unauthorized(403, "API key not valid")) {
            _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 64)
        }
    }
}

@Suite struct OnlineMinutesEngineFactoryAndConnectionTests {
    @Test func 工厂按服务商协议族返回对应引擎实例() {
        let transport = FakeHTTPTransport()
        let config = makeOpenAIConfig()

        #expect(OnlineMinutesEngine.makeGenerator(provider: .deepSeek, config: config, transport: transport)
            is OpenAICompatibleTextGenerator)
        #expect(OnlineMinutesEngine.makeGenerator(provider: .dashScope, config: config, transport: transport)
            is OpenAICompatibleTextGenerator)
        #expect(OnlineMinutesEngine.makeGenerator(provider: .openAI, config: config, transport: transport)
            is OpenAICompatibleTextGenerator)
        #expect(OnlineMinutesEngine.makeGenerator(provider: .custom, config: config, transport: transport)
            is OpenAICompatibleTextGenerator)
        #expect(OnlineMinutesEngine.makeGenerator(provider: .anthropic, config: makeAnthropicConfig(), transport: transport)
            is AnthropicTextGenerator)
        #expect(OnlineMinutesEngine.makeGenerator(provider: .gemini, config: makeGeminiConfig(), transport: transport)
            is GeminiTextGenerator)
    }

    @Test func 连接测试对三套协议发送极短消息与极小输出上限并在合法响应下通过() async throws {
        // 1) OpenAI 兼容（含自定义免密 http://localhost）
        let openAITransport = FakeHTTPTransport()
        try openAITransport.enqueue(json: ["choices": [["message": ["content": #"{"ok":true}"#]]]])
        let customConfig = makeOpenAIConfig(
            baseURL: "http://localhost:11434/v1",
            model: "qwen2.5:14b",
            apiKey: "",
            requiresHTTPS: false,
            requiresAPIKey: false,
            providerID: "openai-compatible"
        )
        try await OnlineMinutesEngine.testConnection(provider: .custom, config: customConfig, transport: openAITransport)
        let openAIBody = try #require(openAITransport.recordedRequests.first?.bodyJSONObject())
        let openAIMaxTokens = try #require(openAIBody["max_tokens"] as? Int)
        #expect(openAIMaxTokens > 0 && openAIMaxTokens <= 256)

        // 2) Anthropic
        let anthropicTransport = FakeHTTPTransport()
        try anthropicTransport.enqueue(json: ["content": [["type": "text", "text": "OK"]]])
        try await OnlineMinutesEngine.testConnection(
            provider: .anthropic,
            config: makeAnthropicConfig(),
            transport: anthropicTransport
        )
        let anthropicBody = try #require(anthropicTransport.recordedRequests.first?.bodyJSONObject())
        let anthropicMaxTokens = try #require(anthropicBody["max_tokens"] as? Int)
        #expect(anthropicMaxTokens > 0 && anthropicMaxTokens <= 256)

        // 3) Gemini
        let geminiTransport = FakeHTTPTransport()
        try geminiTransport.enqueue(json: ["candidates": [["content": ["parts": [["text": #"{"ok":true}"#]]]]]])
        try await OnlineMinutesEngine.testConnection(
            provider: .gemini,
            config: makeGeminiConfig(),
            transport: geminiTransport
        )
        let geminiBody = try #require(geminiTransport.recordedRequests.first?.bodyJSONObject())
        let genConfig = try #require(geminiBody["generationConfig"] as? [String: Any])
        let geminiMaxTokens = try #require(genConfig["maxOutputTokens"] as? Int)
        #expect(geminiMaxTokens > 0 && geminiMaxTokens <= 256)
    }

    @Test func 连接测试在配置无效_401_404与网络异常时抛出可读中文错误() async throws {
        // 无效配置（内置服务商使用 http://）直接拦截
        let idleTransport = FakeHTTPTransport()
        let badURL = makeOpenAIConfig(baseURL: "http://api.deepseek.com/v1")
        let configErr = await #expect(throws: OnlineAPIError.self) {
            try await OnlineMinutesEngine.testConnection(provider: .deepSeek, config: badURL, transport: idleTransport)
        }
        #expect(configErr?.localizedDescription.isEmpty == false)
        #expect(idleTransport.requests.isEmpty)

        // 401 / 404 / 网络失败
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: ["error": ["message": "bad api key"]], status: 401)
        try transport.enqueue(json: ["error": ["message": "model not found"]], status: 404)
        transport.enqueue(error: OnlineAPIError.networkUnavailable("离线"))

        let err401 = await #expect(throws: OnlineAPIError.unauthorized(401, "bad api key")) {
            try await OnlineMinutesEngine.testConnection(provider: .openAI, config: makeOpenAIConfig(), transport: transport)
        }
        #expect(err401?.localizedDescription.contains("鉴权失败") == true)

        let err404 = await #expect(throws: OnlineAPIError.notFound("model not found")) {
            try await OnlineMinutesEngine.testConnection(provider: .openAI, config: makeOpenAIConfig(), transport: transport)
        }
        #expect(err404?.localizedDescription.contains("404") == true)

        let errNet = await #expect(throws: OnlineAPIError.networkUnavailable("离线")) {
            try await OnlineMinutesEngine.testConnection(provider: .openAI, config: makeOpenAIConfig(), transport: transport)
        }
        #expect(errNet?.localizedDescription.contains("网络连接失败") == true)
    }
}

@Suite struct OnlineTokenEstimatorAndMinutesIntegrationTests {
    private func date(_ iso: String) -> Date {
        try! Date(iso, strategy: .iso8601)
    }

    @Test func 启发式countTokens对空串为0_追加任意内容单调不减_中日韩权重高于西文() {
        let generator = OnlineMinutesEngine.makeGenerator(
            provider: .deepSeek,
            config: makeOpenAIConfig(),
            transport: FakeHTTPTransport()
        )

        #expect(generator.countTokens("") == 0)

        let samples = [
            "[s1 00:03 说话人 1] 我们今天讨论 v2.3 的发布时间，预计下周三完成。",
            "The quick brown fox jumps over the lazy dog 12345.",
            #"{"overview":[{"text":"推进项目上线","refs":["s1","s2"]}],"actions":[]}"#,
            "混合文本 Mixed Chinese and English with punctuation！？",
        ]
        for sample in samples {
            var prefix = ""
            var previous = 0
            for scalar in sample.unicodeScalars {
                prefix.unicodeScalars.append(scalar)
                let current = generator.countTokens(prefix)
                #expect(current >= previous)
                previous = current
            }
        }

        // 等长汉字与纯英文字母相比，汉字估算 token 显著更高，且对西文含安全余量
        let chinese = String(repeating: "会", count: 100)
        let english = String(repeating: "a", count: 100)
        #expect(generator.countTokens(chinese) > generator.countTokens(english) * 2)
        #expect(generator.countTokens(chinese) >= 120)
        #expect(generator.countTokens("a b c d e f g h i j") >= 12)
    }

    @Test func 一小时常规会议在64K窗口一次整场提取跳过合并_原样保留说话人与笔记并忽略文法() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: [
            "choices": [[
                "message": [
                    "content": #"""
                    ```json
                    {
                      "overview": [{"text": "确认版本发布节奏", "refs": ["s1", "s600"]}],
                      "decisions": [{"text": "按计划在下周三发布", "refs": ["s1"]}],
                      "actions": [{"text": "完成支付联调", "owner": "王总", "due": "下周三", "dueDate": "2026-11-18", "refs": ["s3"]}],
                      "questions": []
                    }
                    ```
                    """#
                ]
            ]]
        ])
        try transport.enqueue(json: [
            "choices": [[
                "message": [
                    "content": #"{"text": "王总确认预算额度不变", "refs": ["s3"]}"#
                ]
            ]]
        ])

        var items: [TranscriptItem] = []
        for i in 1...600 {
            let start = Double(i - 1) * 6
            let text = i == 3 ? "王总负责支付联调，下周三前完成" : "第\(i)句讨论了版本上线排期与测试计划"
            items.append(.sentence(TranscriptSentence(
                id: "s\(i)",
                start: start,
                end: start + 5,
                text: text,
                speaker: i == 3 ? "spk1" : "spk2"
            )))
        }
        let transcript = Transcript(
            engine: "apple/speechanalyzer",
            createdAt: date("2026-11-10T03:01:00Z"),
            hotwords: [],
            items: items,
            diarization: Diarization(
                engine: "sherpa-onnx",
                voiceprintModel: "cam++",
                speakersCreatedAt: date("2026-11-10T03:02:00Z"),
                speakers: [
                    Speaker(id: "spk1", name: "王总", nameSource: .user, voiceprint: Voiceprint([1]), speechDuration: 30),
                    Speaker(id: "spk2", voiceprint: Voiceprint([2]), speechDuration: 60),
                ]
            )
        )
        let annotations = MinutesAnnotations(
            spans: [AnnotationSpan(kind: .note, annotationIDs: ["n1"], at: 15, start: 0, end: 40,
                                   noteText: "预算→王总确认", sentenceIDs: ["s1", "s2", "s3", "s4"])],
            hash: "ann-hash-1"
        )

        let config = makeOpenAIConfig(
            baseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat",
            apiKey: "sk-ds-key",
            providerID: "deepseek"
        )
        let generator = OnlineMinutesEngine.makeGenerator(provider: .deepSeek, config: config, transport: transport)
        let minutes = try await generateMinutes(
            transcript: transcript,
            title: "版本发布评审会",
            startedAt: date("2026-11-10T02:00:00Z"),
            template: .general,
            annotations: annotations,
            generator: generator,
            model: config.sourceIdentifier,
            createdAt: date("2026-11-10T03:10:00Z"),
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )

        // 1 次整场提取（跳过合并）+ 1 次笔记展开 = 2 次 HTTP 调用
        #expect(transport.recordedRequests.count == 2)
        let extractBody = try #require(transport.recordedRequests[0].bodyJSONObject())
        #expect(extractBody["max_tokens"] as? Int == 8_192)
        let extractMessages = try #require(extractBody["messages"] as? [[String: String]])
        let userPrompt = try #require(extractMessages.last?["content"])
        #expect(userPrompt.contains("版本发布评审会"))
        #expect(userPrompt.contains("2026-11-10（星期二）"))
        #expect(userPrompt.contains("[s3 00:12 王总 ★] 王总负责支付联调，下周三前完成"))
        #expect(userPrompt.contains("[s600 "))

        let expandBody = try #require(transport.recordedRequests[1].bodyJSONObject())
        #expect(expandBody["max_tokens"] as? Int == 8_192)
        let expandPrompt = try #require((expandBody["messages"] as? [[String: String]])?.last?["content"])
        #expect(expandPrompt.contains("预算→王总确认"))

        #expect(minutes.model == "deepseek/deepseek-chat")
        let actions = try #require(minutes.sections.first { $0.kind == .actions })
        #expect(actions.items.first?.owner == "王总")
        #expect(actions.items.first?.ownerSpeaker == "spk1")
        #expect(actions.items.first?.dueDate == CalendarDate(year: 2026, month: 11, day: 18))
        let noteSection = try #require(minutes.sections.first { $0.kind == .annotations })
        #expect(noteSection.items.first?.text == "王总确认预算额度不变")
        #expect(noteSection.items.first?.refs == [MinutesRef(id: "s3", start: 12)])
    }

    @Test func 超长会议超出64K预算时自动分段提取并合并_每次请求均在窗口内() async throws {
        let transport = FakeHTTPTransport { request in
            let body = try JSONSerialization.jsonObject(with: request.body.flatMap {
                guard case let .data(data) = $0 else { return nil }
                return data
            } ?? Data()) as? [String: Any]
            let messages = body?["messages"] as? [[String: String]] ?? []
            let prompt = messages.last?["content"] ?? ""
            let lines = transcriptLines(in: prompt)
            let content: String
            if let first = lines.first(where: { $0.hasPrefix("[s") }) {
                let id = first.dropFirst().prefix { $0 != " " }
                content = #"{"overview":[{"text":"\#(id) 段讨论","refs":["\#(id)"]}]}"#
            } else {
                content = #"{"overview":[{"text":"全场合并概要","refs":["s1"]}]}"#
            }
            return try HTTPResponse.json(["choices": [["message": ["content": content]]]])
        }

        // 2,000 句长中文转写稿，经启发式分词必超出 64K - 8_192 预算
        let items: [TranscriptItem] = (1...2_000).map { i in
            .sentence(TranscriptSentence(
                id: "s\(i)",
                start: Double(i - 1) * 8,
                end: Double(i - 1) * 8 + 6,
                text: "这是第\(i)句非常详细的会议讨论内容，涉及多个模块的技术细节与交付计划安排"
            ))
        }
        let transcript = Transcript(
            engine: "apple/speechanalyzer",
            createdAt: date("2026-11-10T03:01:00Z"),
            hotwords: [],
            items: items
        )

        let generator = OnlineMinutesEngine.makeGenerator(
            provider: .openAI,
            config: makeOpenAIConfig(),
            transport: transport
        )
        let minutes = try await generateMinutes(
            transcript: transcript,
            title: "超长研讨会",
            startedAt: date("2026-11-10T02:00:00Z"),
            template: .general,
            generator: generator,
            model: "openai/gpt-4.1-mini",
            timeZone: TimeZone(identifier: "Asia/Shanghai")!
        )

        #expect(transport.recordedRequests.count >= 3)
        for recorded in transport.recordedRequests {
            let body = try #require(recorded.bodyJSONObject())
            let maxTokens = try #require(body["max_tokens"] as? Int)
            #expect(maxTokens == 8_192)
            let messages = try #require(body["messages"] as? [[String: String]])
            let usedTokens = messages.reduce(0) { $0 + generator.countTokens($1["content"] ?? "") }
            #expect(usedTokens + maxTokens <= 64_000)
        }
        #expect(minutes.sections.first { $0.kind == .overview }?.items.map(\.text) == ["全场合并概要"])
    }

    @Test func Anthropic与Gemini引擎均可通过generateMinutes端到端产出校验后的纪要() async throws {
        let shortTranscript = Transcript(
            engine: "apple/speechanalyzer",
            createdAt: date("2026-11-10T03:01:00Z"),
            hotwords: [],
            items: [
                .sentence(TranscriptSentence(id: "s1", start: 2, end: 5, text: "下周五前完成接口联调")),
            ]
        )

        let anthropicTransport = FakeHTTPTransport()
        try anthropicTransport.enqueue(json: [
            "content": [[
                "type": "text",
                "text": #"{"overview":[{"text":"明确联调时间","refs":["s1","s99"]}],"decisions":[],"actions":[],"questions":[]}"#,
            ]],
        ])
        let anthropicGen = OnlineMinutesEngine.makeGenerator(
            provider: .anthropic,
            config: makeAnthropicConfig(),
            transport: anthropicTransport
        )
        let anthropicMinutes = try await generateMinutes(
            transcript: shortTranscript,
            title: "联调对齐",
            startedAt: date("2026-11-10T02:00:00Z"),
            template: .general,
            generator: anthropicGen,
            model: "anthropic/claude-sonnet-4-5"
        )
        #expect(anthropicMinutes.sections[0].items.first?.refs == [MinutesRef(id: "s1", start: 2)])

        let geminiTransport = FakeHTTPTransport()
        try geminiTransport.enqueue(json: [
            "candidates": [[
                "content": [
                    "parts": [[
                        "text": #"{"overview":[{"text":"明确联调时间","refs":["s1"]}],"decisions":[],"actions":[],"questions":[]}"#
                    ]]
                ]
            ]]
        ])
        let geminiGen = OnlineMinutesEngine.makeGenerator(
            provider: .gemini,
            config: makeGeminiConfig(),
            transport: geminiTransport
        )
        let geminiMinutes = try await generateMinutes(
            transcript: shortTranscript,
            title: "联调对齐",
            startedAt: date("2026-11-10T02:00:00Z"),
            template: .general,
            generator: geminiGen,
            model: "gemini/gemini-2.5-flash"
        )
        #expect(geminiMinutes.sections[0].items.first?.refs == [MinutesRef(id: "s1", start: 2)])
    }
}

private let onlineContractEnv = ProcessInfo.processInfo.environment
private let onlineContractEnabled = onlineContractEnv["FAYMEE_ONLINE_CONTRACT"] == "1"

/// 可选真实网络契约测试：仅当显式设置 `FAYMEE_ONLINE_CONTRACT=1` 且提供对应平台测试密钥时运行
@Suite(.enabled(if: onlineContractEnabled, "设 FAYMEE_ONLINE_CONTRACT=1 且提供对应平台密钥才跑"))
struct OnlineMinutesContractTests {
    @Test(.enabled(if: onlineContractEnabled && !(onlineContractEnv["FAYMEE_DEEPSEEK_API_KEY"] ?? "").isEmpty,
                   "设 FAYMEE_DEEPSEEK_API_KEY 才跑"))
    func DeepSeek连接测试真实请求() async throws {
        let key = onlineContractEnv["FAYMEE_DEEPSEEK_API_KEY"] ?? ""
        let config = OnlineEndpointConfig(
            baseURL: onlineContractEnv["FAYMEE_DEEPSEEK_BASE_URL"] ?? OnlineMinutesProvider.deepSeek.defaultBaseURL,
            model: onlineContractEnv["FAYMEE_DEEPSEEK_MODEL"] ?? OnlineMinutesProvider.deepSeek.defaultModel,
            apiKey: key,
            requiresHTTPS: true,
            requiresAPIKey: true,
            providerID: OnlineMinutesProvider.deepSeek.providerID
        )
        try await OnlineMinutesEngine.testConnection(
            provider: .deepSeek,
            config: config,
            transport: URLSessionHTTPTransport()
        )
    }

    @Test(.enabled(if: onlineContractEnabled && !(onlineContractEnv["FAYMEE_DASHSCOPE_API_KEY"] ?? "").isEmpty,
                   "设 FAYMEE_DASHSCOPE_API_KEY 才跑"))
    func 阿里云百炼连接测试真实请求() async throws {
        let key = onlineContractEnv["FAYMEE_DASHSCOPE_API_KEY"] ?? ""
        let config = OnlineEndpointConfig(
            baseURL: onlineContractEnv["FAYMEE_DASHSCOPE_BASE_URL"] ?? OnlineMinutesProvider.dashScope.defaultBaseURL,
            model: onlineContractEnv["FAYMEE_DASHSCOPE_MODEL"] ?? OnlineMinutesProvider.dashScope.defaultModel,
            apiKey: key,
            requiresHTTPS: true,
            requiresAPIKey: true,
            providerID: OnlineMinutesProvider.dashScope.providerID
        )
        try await OnlineMinutesEngine.testConnection(
            provider: .dashScope,
            config: config,
            transport: URLSessionHTTPTransport()
        )
    }

    @Test(.enabled(if: onlineContractEnabled && !(onlineContractEnv["FAYMEE_OPENAI_API_KEY"] ?? "").isEmpty,
                   "设 FAYMEE_OPENAI_API_KEY 才跑"))
    func OpenAI连接测试真实请求() async throws {
        let key = onlineContractEnv["FAYMEE_OPENAI_API_KEY"] ?? ""
        let config = OnlineEndpointConfig(
            baseURL: onlineContractEnv["FAYMEE_OPENAI_BASE_URL"] ?? OnlineMinutesProvider.openAI.defaultBaseURL,
            model: onlineContractEnv["FAYMEE_OPENAI_MODEL"] ?? OnlineMinutesProvider.openAI.defaultModel,
            apiKey: key,
            requiresHTTPS: true,
            requiresAPIKey: true,
            providerID: OnlineMinutesProvider.openAI.providerID
        )
        try await OnlineMinutesEngine.testConnection(
            provider: .openAI,
            config: config,
            transport: URLSessionHTTPTransport()
        )
    }

    @Test(.enabled(if: onlineContractEnabled && !(onlineContractEnv["FAYMEE_ANTHROPIC_API_KEY"] ?? "").isEmpty,
                   "设 FAYMEE_ANTHROPIC_API_KEY 才跑"))
    func Anthropic连接测试真实请求() async throws {
        let key = onlineContractEnv["FAYMEE_ANTHROPIC_API_KEY"] ?? ""
        let config = OnlineEndpointConfig(
            baseURL: onlineContractEnv["FAYMEE_ANTHROPIC_BASE_URL"] ?? OnlineMinutesProvider.anthropic.defaultBaseURL,
            model: onlineContractEnv["FAYMEE_ANTHROPIC_MODEL"] ?? OnlineMinutesProvider.anthropic.defaultModel,
            apiKey: key,
            requiresHTTPS: true,
            requiresAPIKey: true,
            providerID: OnlineMinutesProvider.anthropic.providerID
        )
        try await OnlineMinutesEngine.testConnection(
            provider: .anthropic,
            config: config,
            transport: URLSessionHTTPTransport()
        )
    }

    @Test(.enabled(if: onlineContractEnabled && !(onlineContractEnv["FAYMEE_GEMINI_API_KEY"] ?? "").isEmpty,
                   "设 FAYMEE_GEMINI_API_KEY 才跑"))
    func Gemini连接测试真实请求() async throws {
        let key = onlineContractEnv["FAYMEE_GEMINI_API_KEY"] ?? ""
        let config = OnlineEndpointConfig(
            baseURL: onlineContractEnv["FAYMEE_GEMINI_BASE_URL"] ?? OnlineMinutesProvider.gemini.defaultBaseURL,
            model: onlineContractEnv["FAYMEE_GEMINI_MODEL"] ?? OnlineMinutesProvider.gemini.defaultModel,
            apiKey: key,
            requiresHTTPS: true,
            requiresAPIKey: true,
            providerID: OnlineMinutesProvider.gemini.providerID
        )
        try await OnlineMinutesEngine.testConnection(
            provider: .gemini,
            config: config,
            transport: URLSessionHTTPTransport()
        )
    }
}




