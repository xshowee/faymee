import Foundation

/// 在线会后转写引擎工厂与连接测试入口
public enum OnlineTranscriptionEngine {
    public static func makeTranscriber(
        provider: OnlineTranscriptionProvider,
        config: OnlineEndpointConfig,
        transport: any HTTPTransport,
        referenceTranscriber: (any Transcriber)? = nil
    ) -> any Transcriber {
        switch provider {
        case .dashScope:
            DashScopeTranscriber(config: config, transport: transport)
        case .openAI, .groq, .custom:
            OpenAITranscriber(
                config: config,
                transport: transport,
                referenceTranscriber: referenceTranscriber
            )
        }
    }

    @MainActor
    public static func makeEngine(
        settings: OnlineModelSettings,
        transport: any HTTPTransport,
        local: () -> (transcriber: any Transcriber, name: String),
        reference: () -> (any Transcriber)?
    ) -> (transcriber: any Transcriber, name: String, isReady: Bool) {
        switch settings.transcriptionMode {
        case .local:
            let resolved = local()
            return (resolved.transcriber, resolved.name, true)
        case .online:
            let config = settings.activeTranscriptionConfig
            let transcriber = makeTranscriber(
                provider: settings.transcriptionProvider,
                config: config,
                transport: transport,
                referenceTranscriber: reference()
            )
            return (transcriber, config.sourceIdentifier, config.isReady)
        }
    }

    public static func testConnection(
        provider: OnlineTranscriptionProvider,
        config: OnlineEndpointConfig,
        transport: any HTTPTransport,
        dashScopePollInterval: Duration = .seconds(1)
    ) async throws {
        switch provider {
        case .dashScope:
            try await DashScopeTranscriber.testConnection(
                config: config,
                transport: transport,
                pollInterval: dashScopePollInterval
            )
        case .openAI, .groq, .custom:
            try await OpenAITranscriber.testConnection(
                config: config,
                transport: transport
            )
        }
    }
}
