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
}
