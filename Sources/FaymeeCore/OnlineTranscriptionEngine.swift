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

/// 在线语音转写共用的音频文件 MIME 类型推断
enum AudioMIMEType {
    static func forURL(_ url: URL) -> String {
        forExtension(url.pathExtension)
    }

    static func forExtension(_ ext: String) -> String {
        switch ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "wav": "audio/wav"
        case "m4a", "mp4": "audio/mp4"
        case "mp3", "mpeg", "mpga": "audio/mpeg"
        case "flac": "audio/flac"
        case "ogg": "audio/ogg"
        case "opus": "audio/opus"
        case "aac": "audio/aac"
        case "webm": "audio/webm"
        default: "application/octet-stream"
        }
    }
}
