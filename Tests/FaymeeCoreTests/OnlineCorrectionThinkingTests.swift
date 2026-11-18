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
}
