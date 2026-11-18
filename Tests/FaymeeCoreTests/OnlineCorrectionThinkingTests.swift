import Foundation
import Testing
@testable import FaymeeCore

/// 在线纠错关思考：纠错是机械活，各家接口能关就关；关不掉（服务端拒收）时去掉开关重发，
/// 并给输出上限留出思考的余量，免得思考吃光上限、正文为空。纪要的请求不变
@Suite struct OnlineCorrectionThinkingTests {
    private let transcript: Transcript = {
        let items = ["我们要避免对动的局面", "好的"].enumerated().map { i, text in
            TranscriptItem.sentence(TranscriptSentence(id: "s\(i + 1)", start: Double(i * 10), end: Double(i * 10 + 5),
                                                       text: text))
        }
        return Transcript(engine: "apple/speechanalyzer", createdAt: Date(timeIntervalSince1970: 0), hotwords: [],
                          items: items)
    }()

    private func config(_ provider: OnlineMinutesProvider, model: String? = nil) -> OnlineEndpointConfig {
        OnlineEndpointConfig(baseURL: provider == .custom ? "https://gateway.example.com/v1" : provider.defaultBaseURL,
                             model: model ?? (provider == .custom ? "my-model" : provider.defaultModel),
                             apiKey: "sk-test-key", requiresHTTPS: true, requiresAPIKey: true,
                             providerID: provider.providerID)
    }

    private func correct(_ generator: TextGenerator) async throws -> CorrectionReview {
        try await correctTranscript(transcript, title: "周会", hotwords: [], method: .sentenceRewrite,
                                    generator: generator)
    }

    private let edits = #"{"edits": [{"id": "s1", "text": "我们要避免被动的局面"}]}"#

    private func openAIReply(_ content: String) -> [String: Any] {
        ["choices": [["message": ["content": content]]]]
    }

    @Test func DeepSeek纠错请求关思考_纪要请求不带开关() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: openAIReply(edits))
        try transport.enqueue(json: openAIReply(#"{"overview":[]}"#))
        let generator = OnlineMinutesEngine.makeGenerator(provider: .deepSeek, config: config(.deepSeek, model: "deepseek-flash"),
                                                          transport: transport)

        let review = try await correct(generator)
        _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 8192, grammar: nil)

        #expect(review.texts == ["s1": "我们要避免被动的局面"])
        let correction = try #require(transport.recordedRequests[0].bodyJSONObject())
        #expect(correction["thinking"] as? [String: String] == ["type": "disabled"])
        #expect(correction["max_tokens"] as? Int == 8192)
        let minutes = try #require(transport.recordedRequests[1].bodyJSONObject())
        #expect(Set(minutes.keys) == ["model", "messages", "max_tokens", "response_format"])
    }

    @Test func 百炼纠错请求关思考_OpenAI和自定义网关不加开关() async throws {
        var bodies: [OnlineMinutesProvider: [String: Any]] = [:]
        for provider in [OnlineMinutesProvider.dashScope, .openAI, .custom] {
            let transport = FakeHTTPTransport()
            try transport.enqueue(json: openAIReply(edits))
            let generator = OnlineMinutesEngine.makeGenerator(provider: provider, config: config(provider),
                                                              transport: transport)
            _ = try await correct(generator)
            bodies[provider] = try #require(transport.recordedRequests.first?.bodyJSONObject())
        }
        #expect(bodies[.dashScope]?["enable_thinking"] as? Bool == false)
        for provider in [OnlineMinutesProvider.openAI, .custom] {
            #expect(Set(bodies[provider]?.keys ?? [:].keys) == ["model", "messages", "max_tokens", "response_format"])
        }
    }

    @Test func 关思考的开关被拒时_先去掉JSON模式_再去掉开关并留出思考余量() async throws {
        let transport = FakeHTTPTransport()
        let rejected: [String: Any] = ["error": ["message": "enable_thinking is not supported for this model"]]
        try transport.enqueue(json: rejected, status: 400)
        try transport.enqueue(json: rejected, status: 400)
        try transport.enqueue(json: openAIReply(edits))
        let generator = OnlineMinutesEngine.makeGenerator(provider: .dashScope, config: config(.dashScope),
                                                          transport: transport)

        let review = try await correct(generator)

        #expect(review.texts == ["s1": "我们要避免被动的局面"])
        let bodies = transport.recordedRequests.compactMap { $0.bodyJSONObject() }
        #expect(bodies.count == 3)
        #expect(bodies.map { $0["response_format"] != nil } == [true, false, false])
        #expect(bodies.map { $0["enable_thinking"] as? Bool } == [false, false, nil])
        #expect(bodies.map { $0["max_tokens"] as? Int } == [8192, 8192, 8192 + 16_384])
    }

    @Test func 正文为空仍算失败_不当成没有修改() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: ["choices": [["message": ["content": "", "reasoning_content": "想了很久"],
                                                  "finish_reason": "length"]]])
        let generator = OnlineMinutesEngine.makeGenerator(provider: .deepSeek, config: config(.deepSeek),
                                                          transport: transport)
        await #expect(throws: OnlineAPIError.emptyResponse) { _ = try await correct(generator) }
    }

    private func anthropicReply(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
    }

    @Test func Anthropic纠错请求关思考_被拒时去掉开关并留出思考余量_纪要请求不变() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: anthropicReply(edits))
        try transport.enqueue(json: ["error": ["message": #""thinking.type.disabled" is not supported for this model."#]],
                              status: 400)
        try transport.enqueue(json: anthropicReply(edits))
        try transport.enqueue(json: anthropicReply(#"{"overview":[]}"#))
        let generator = OnlineMinutesEngine.makeGenerator(provider: .anthropic, config: config(.anthropic),
                                                          transport: transport)

        _ = try await correct(generator)
        let review = try await correct(generator)
        _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 8192, grammar: nil)

        #expect(review.texts == ["s1": "我们要避免被动的局面"])
        let bodies = transport.recordedRequests.compactMap { $0.bodyJSONObject() }
        #expect(bodies.count == 4)
        #expect(bodies.map { $0["thinking"] as? [String: String] }
            == [["type": "disabled"], ["type": "disabled"], nil, nil])
        #expect(bodies.map { $0["max_tokens"] as? Int } == [8192, 8192, 8192 + 16_384, 8192])
        #expect(Set(bodies[3].keys) == ["model", "max_tokens", "messages", "system"])
    }

    private func geminiReply(_ text: String) -> [String: Any] {
        ["candidates": [["content": ["parts": [["text": text]]], "finishReason": "STOP"]]]
    }

    private func geminiRequest(model: String) async throws -> [String: Any] {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: geminiReply(edits))
        let generator = OnlineMinutesEngine.makeGenerator(provider: .gemini, config: config(.gemini, model: model),
                                                          transport: transport)
        _ = try await correct(generator)
        let body = try #require(transport.recordedRequests.first?.bodyJSONObject())
        return try #require(body["generationConfig"] as? [String: Any])
    }

    @Test func Gemini纠错请求按模型代际关思考或调到最低_关不掉的留出思考余量() async throws {
        // 2.5 Flash 预算 0 即关；2.5 Pro 关不掉，最低 128
        let flash25 = try await geminiRequest(model: "gemini-2.5-flash")
        #expect(flash25["thinkingConfig"] as? [String: Int] == ["thinkingBudget": 0])
        #expect(flash25["maxOutputTokens"] as? Int == 8192)
        let pro25 = try await geminiRequest(model: "models/gemini-2.5-pro")
        #expect(pro25["thinkingConfig"] as? [String: Int] == ["thinkingBudget": 128])
        #expect(pro25["maxOutputTokens"] as? Int == 8192 + 16_384)
        // 3 代起用思考等级，Flash 有 minimal，Pro 最低 low
        let flash3 = try await geminiRequest(model: "gemini-3-flash-preview")
        #expect(flash3["thinkingConfig"] as? [String: String] == ["thinkingLevel": "minimal"])
        #expect(flash3["maxOutputTokens"] as? Int == 8192 + 16_384)
        let pro3 = try await geminiRequest(model: "gemini-3-pro-preview")
        #expect(pro3["thinkingConfig"] as? [String: String] == ["thinkingLevel": "low"])
        #expect(pro3["maxOutputTokens"] as? Int == 8192 + 16_384)
        // 2.0 及更早不思考，带 thinkingConfig 反而报错
        let flash20 = try await geminiRequest(model: "gemini-2.0-flash")
        #expect(flash20["thinkingConfig"] == nil)
        #expect(flash20["maxOutputTokens"] as? Int == 8192)
    }

    @Test func Gemini思考设置被拒时去掉并留出思考余量_纪要请求不变() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: ["error": ["message": "Thinking level MINIMAL is not supported for this model."]],
                              status: 400)
        try transport.enqueue(json: geminiReply(edits))
        try transport.enqueue(json: geminiReply(#"{"overview":[]}"#))
        let generator = OnlineMinutesEngine.makeGenerator(provider: .gemini,
                                                          config: config(.gemini, model: "gemini-4-flash"),
                                                          transport: transport)

        let review = try await correct(generator)
        _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 8192, grammar: nil)

        #expect(review.texts == ["s1": "我们要避免被动的局面"])
        let configs = transport.recordedRequests.compactMap { $0.bodyJSONObject()?["generationConfig"] as? [String: Any] }
        #expect(configs.count == 3)
        #expect(configs.map { $0["thinkingConfig"] != nil } == [true, false, false])
        #expect(configs.map { $0["maxOutputTokens"] as? Int } == [8192 + 16_384, 8192 + 16_384, 8192])
        #expect(configs.map { $0["responseMimeType"] as? String } == Array(repeating: "application/json", count: 3))
    }
}
