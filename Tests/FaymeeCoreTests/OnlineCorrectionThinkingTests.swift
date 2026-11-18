import Foundation
import Testing
@testable import FaymeeCore

/// 在线纠错按服务商默认的思考设置发请求（默认思考的照常思考，不思考的不强开），和纪要同一个引擎、同样的请求
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

    private func reply(_ provider: OnlineMinutesProvider, _ text: String) -> [String: Any] {
        switch provider.protocolKind {
        case .openAICompatible: ["choices": [["message": ["content": text], "finish_reason": "stop"]]]
        case .anthropic: ["content": [["type": "text", "text": text]], "stop_reason": "end_turn"]
        case .gemini: ["candidates": [["content": ["parts": [["text": text]]], "finishReason": "STOP"]]]
        }
    }

    /// 纠错和纪要各发一次，返回两次请求的 body
    private func requests(_ provider: OnlineMinutesProvider, model: String? = nil) async throws
        -> (correction: [String: Any], minutes: [String: Any]) {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: reply(provider, edits))
        try transport.enqueue(json: reply(provider, #"{"overview":[]}"#))
        let generator = OnlineMinutesEngine.makeGenerator(provider: provider, config: config(provider, model: model),
                                                          transport: transport)
        let review = try await correct(generator)
        _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 8192, grammar: nil)
        #expect(review.texts == ["s1": "我们要避免被动的局面"])
        let bodies = transport.recordedRequests.compactMap { $0.bodyJSONObject() }
        try #require(bodies.count == 2)
        return (bodies[0], bodies[1])
    }

    @Test func 纠错请求不带关思考的开关_各服务商按默认思考() async throws {
        for provider in [OnlineMinutesProvider.deepSeek, .dashScope, .openAI, .custom] {
            let (correction, _) = try await requests(provider, model: provider == .deepSeek ? "deepseek-flash" : nil)
            #expect(Set(correction.keys) == ["model", "messages", "max_tokens", "response_format"], "\(provider)")
        }
        let (anthropic, _) = try await requests(.anthropic)
        #expect(Set(anthropic.keys) == ["model", "max_tokens", "messages", "system"])
        for model in ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-3-flash-preview", "gemini-2.0-flash"] {
            let (gemini, _) = try await requests(.gemini, model: model)
            let generation = try #require(gemini["generationConfig"] as? [String: Any])
            #expect(Set(generation.keys) == ["maxOutputTokens", "responseMimeType"], "\(model)")
        }
    }

    private let starved: [String: Any] = ["choices": [["message": ["content": "", "reasoning_content": "想了很久"],
                                                       "finish_reason": "length"]]]

    @Test func 自定义网关思考吃光上限时放大上限再试一次_纪要也一样() async throws {
        for call in ["纠错", "纪要"] {
            let transport = FakeHTTPTransport()
            try transport.enqueue(json: starved)
            try transport.enqueue(json: reply(.custom, edits))
            let generator = OnlineMinutesEngine.makeGenerator(provider: .custom, config: config(.custom),
                                                              transport: transport)
            if call == "纠错" {
                #expect(try await correct(generator).texts == ["s1": "我们要避免被动的局面"])
            } else {
                _ = try await generator.generate(system: "s", prompt: "p", maxTokens: 8192, grammar: nil)
            }
            let bodies = transport.recordedRequests.compactMap { $0.bodyJSONObject() }
            #expect(bodies.map { $0["max_tokens"] as? Int } == [8_192, 32_768], "\(call)")
            #expect(bodies.map { $0["response_format"] != nil } == [true, true], "\(call)")
        }
    }

    @Test func 已按模型上限发的请求思考吃光上限时不再试_正文为空算失败() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: starved)
        try transport.enqueue(json: starved)
        let generator = OnlineMinutesEngine.makeGenerator(provider: .deepSeek, config: config(.deepSeek, model: "deepseek-flash"),
                                                          transport: transport)
        await #expect(throws: OnlineAPIError.emptyResponse) { _ = try await correct(generator) }
        #expect(transport.recordedRequests.count == 1)

        let custom = FakeHTTPTransport()
        try custom.enqueue(json: starved)
        try custom.enqueue(json: starved)
        let gateway = OnlineMinutesEngine.makeGenerator(provider: .custom, config: config(.custom), transport: custom)
        await #expect(throws: OnlineAPIError.emptyResponse) { _ = try await correct(gateway) }
        #expect(custom.recordedRequests.count == 2)
    }

    @Test func 分段按正文预算留输出_思考的余量只加在请求的上限上() async throws {
        let items = (1...3_000).map { i in
            TranscriptItem.sentence(TranscriptSentence(id: "s\(i)", start: Double(i * 6), end: Double(i * 6 + 5),
                                                       text: "第\(i)句是会议里关于接口联调和交付计划的讨论"))
        }
        let long = Transcript(engine: "apple/speechanalyzer", createdAt: Date(timeIntervalSince1970: 0), hotwords: [],
                              items: items)
        let transport = FakeHTTPTransport { _ in
            try HTTPResponse.json(["choices": [["message": ["content": #"{"edits": []}"#], "finish_reason": "stop"]]])
        }
        let generator = OnlineMinutesEngine.makeGenerator(provider: .deepSeek, config: config(.deepSeek, model: "deepseek-flash"),
                                                          transport: transport)
        _ = try await correctTranscript(long, title: "周会", hotwords: [], method: .sentenceRewrite, generator: generator)

        let bodies = transport.recordedRequests.compactMap { $0.bodyJSONObject() }
        #expect(bodies.count > 1)
        let used = bodies.map { body in
            (body["messages"] as? [[String: String]] ?? []).reduce(0) { $0 + generator.countTokens($1["content"] ?? "") }
        }
        // 正文预算 8192：一段的提示词能用到 64000 − 8192 附近，不会因为请求的上限 65536 而缩小
        #expect(used.allSatisfy { $0 + 8_192 <= 64_000 })
        #expect(used.first.map { $0 > 64_000 - 16_000 } == true)
        #expect(bodies.allSatisfy { $0["max_tokens"] as? Int == 65_536 })
    }

    private func sentLimit(_ body: [String: Any]) -> Int? {
        body["max_tokens"] as? Int ?? (body["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int
    }

    /// 输出上限含思考，按各家文档（2026-11）里模型接受的最大输出取，超了会 400；纪要和纠错一样
    @Test(arguments: [
        // DeepSeek：接受 1–393216，思考模式不传时默认 64K（api-docs.deepseek.com create-chat-completion）
        (OnlineMinutesProvider.deepSeek, "deepseek-flash", 65_536),
        (.deepSeek, "deepseek-chat", 65_536),
        (.deepSeek, "deepseek-v4-pro", 65_536),
        // 百炼：qwen-plus 32768，qwen-max 8192（上下文 32K），qwen-turbo 查不到按 8192；其他按 32768
        (.dashScope, "qwen-plus", 32_768),
        (.dashScope, "qwen-max", 8_192),
        (.dashScope, "qwen-max-latest", 8_192),
        (.dashScope, "qwen-turbo", 8_192),
        (.dashScope, "qwen3.5-plus", 32_768),
        // OpenAI：gpt-4.1 系 32768，gpt-4o 系 16384；其他按 16384
        (.openAI, "gpt-4.1-mini", 32_768),
        (.openAI, "gpt-4.1", 32_768),
        (.openAI, "gpt-4o", 16_384),
        (.openAI, "gpt-4o-mini", 16_384),
        (.openAI, "gpt-5", 16_384),
        // Anthropic：Sonnet 4.5、Haiku 4.5 64000；其他按 32000（Opus 4 / 4.1 的上限）
        (.anthropic, "claude-sonnet-4-5", 64_000),
        (.anthropic, "claude-haiku-4-5-20251001", 64_000),
        (.anthropic, "claude-opus-4-1", 32_000),
        // Gemini：2.5 起 65536；2.0 及更早 8192
        (.gemini, "gemini-2.5-flash", 65_536),
        (.gemini, "models/gemini-2.5-pro", 65_536),
        (.gemini, "gemini-3-flash-preview", 65_536),
        (.gemini, "gemini-2.0-flash", 8_192),
        (.gemini, "gemini-1.5-pro", 8_192),
        // 自定义网关：后面是什么模型不知道，用以前一直被接受的 8192
        (.custom, "my-model", 8_192),
    ])
    func 请求的输出上限按服务商和模型取_含思考_纪要和纠错一样(provider: OnlineMinutesProvider, model: String,
                                                         limit: Int) async throws {
        let (correction, minutes) = try await requests(provider, model: model)
        #expect(sentLimit(correction) == limit)
        #expect(sentLimit(minutes) == limit)
    }
}
