import Foundation
import Observation

/// 引擎运行模式：本机模型或在线模型
public enum EngineMode: String, Codable, CaseIterable, Hashable, Sendable {
    case local
    case online
}

/// 在线会后转写服务商预设
public enum OnlineTranscriptionProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case dashScope
    case openAI
    case groq
    case custom

    public var displayName: String {
        switch self {
        case .dashScope: "阿里云百炼"
        case .openAI: "OpenAI"
        case .groq: "Groq"
        case .custom: "自定义（OpenAI 兼容）"
        }
    }

    public var providerID: String {
        switch self {
        case .dashScope: "dashscope"
        case .openAI: "openai"
        case .groq: "groq"
        case .custom: "openai-compatible"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .dashScope: "https://dashscope.aliyuncs.com/api/v1"
        case .openAI: "https://api.openai.com/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .custom: ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .dashScope: "qwen3-asr-flash-filetrans"
        case .openAI: "gpt-transcribe"
        case .groq: "whisper-large-v3-turbo"
        case .custom: ""
        }
    }

    public var suggestedModels: [String] {
        switch self {
        case .dashScope: ["qwen3-asr-flash-filetrans", "fun-asr", "paraformer-v2"]
        case .openAI: ["gpt-transcribe", "gpt-4o-transcribe", "whisper-1"]
        case .groq: ["whisper-large-v3-turbo", "whisper-large-v3"]
        case .custom: []
        }
    }

    public var credentialSlot: CredentialSlot {
        switch self {
        case .dashScope: .dashScope
        case .openAI: .openAI
        case .groq: .groq
        case .custom: .customTranscription
        }
    }

    public var requiresHTTPS: Bool {
        self != .custom
    }

    public var requiresAPIKey: Bool {
        self != .custom
    }
}

/// 在线纪要接口协议族
public enum OnlineMinutesProtocol: String, Codable, Hashable, Sendable {
    case openAICompatible
    case anthropic
    case gemini
}

/// 在线纪要生成服务商预设
public enum OnlineMinutesProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case deepSeek
    case dashScope
    case openAI
    case anthropic
    case gemini
    case custom

    public var displayName: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .dashScope: "阿里云百炼"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .custom: "自定义（OpenAI 兼容）"
        }
    }

    public var providerID: String {
        switch self {
        case .deepSeek: "deepseek"
        case .dashScope: "dashscope"
        case .openAI: "openai"
        case .anthropic: "anthropic"
        case .gemini: "gemini"
        case .custom: "openai-compatible"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .deepSeek: "https://api.deepseek.com/v1"
        case .dashScope: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .custom: ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .deepSeek: "deepseek-chat"
        case .dashScope: "qwen-plus"
        case .openAI: "gpt-4.1-mini"
        case .anthropic: "claude-sonnet-4-5"
        case .gemini: "gemini-2.5-flash"
        case .custom: ""
        }
    }

    public var suggestedModels: [String] {
        switch self {
        case .deepSeek: ["deepseek-chat", "deepseek-reasoner"]
        case .dashScope: ["qwen-plus", "qwen-max", "qwen-turbo"]
        case .openAI: ["gpt-4.1-mini", "gpt-4.1", "gpt-4o"]
        case .anthropic: ["claude-sonnet-4-5", "claude-haiku-4-5"]
        case .gemini: ["gemini-2.5-flash", "gemini-2.5-pro"]
        case .custom: []
        }
    }

    public var protocolKind: OnlineMinutesProtocol {
        switch self {
        case .deepSeek, .dashScope, .openAI, .custom: .openAICompatible
        case .anthropic: .anthropic
        case .gemini: .gemini
        }
    }

    public var credentialSlot: CredentialSlot {
        switch self {
        case .deepSeek: .deepSeek
        case .dashScope: .dashScope
        case .openAI: .openAI
        case .anthropic: .anthropic
        case .gemini: .gemini
        case .custom: .customMinutes
        }
    }

    public var requiresHTTPS: Bool {
        self != .custom
    }

    public var requiresAPIKey: Bool {
        self != .custom
    }
}

/// 单个在线能力（转写或纪要）的端点配置快照与校验规则
public struct OnlineEndpointConfig: Hashable, Sendable {
    public var baseURL: String
    public var model: String
    public var apiKey: String
    public var requiresHTTPS: Bool
    public var requiresAPIKey: Bool
    public var providerID: String

    public init(baseURL: String, model: String, apiKey: String, requiresHTTPS: Bool, requiresAPIKey: Bool,
                providerID: String) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.requiresHTTPS = requiresHTTPS
        self.requiresAPIKey = requiresAPIKey
        self.providerID = providerID
    }

    public var trimmedBaseURL: String { baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedAPIKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var urlValidationError: String? {
        let trimmed = trimmedBaseURL
        if trimmed.isEmpty { return "请输入接口地址" }
        guard !trimmed.contains(where: \.isWhitespace),
              let components = URLComponents(string: trimmed),
              let url = components.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = parsedCleanHost(from: url),
              !host.isEmpty
        else { return "请输入有效的接口地址" }

        if requiresHTTPS && scheme != "https" {
            return "内置云服务商必须使用加密的 https:// 地址"
        }
        return nil
    }

    public var plaintextHTTPWarning: String? {
        guard !requiresHTTPS, urlValidationError == nil,
              let url = URL(string: trimmedBaseURL),
              url.scheme?.lowercased() == "http",
              let host = parsedCleanHost(from: url),
              !Self.loopbackHosts.contains(host)
        else { return nil }
        return "当前使用明文 http:// 地址，网络传输内容不会加密，请仅在可信局域网或内网环境中使用"
    }

    public var isReady: Bool {
        urlValidationError == nil && !trimmedModel.isEmpty && (!requiresAPIKey || !trimmedAPIKey.isEmpty)
    }

    public var sourceIdentifier: String {
        "\(providerID)/\(trimmedModel)"
    }

    public func validateReady() throws {
        if let urlError = urlValidationError {
            throw OnlineAPIError.invalidConfiguration(urlError)
        }
        if trimmedModel.isEmpty {
            throw OnlineAPIError.invalidConfiguration("请填写模型标识")
        }
        if requiresAPIKey && trimmedAPIKey.isEmpty {
            throw OnlineAPIError.invalidConfiguration("请填写 API Key")
        }
    }

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    private func parsedCleanHost(from url: URL) -> String? {
        guard let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased(),
              !host.isEmpty
        else { return nil }
        return host
    }
}

/// 集中管理在线转写与在线纪要的配置持久化、预设切换记忆及钥匙串密钥读写
@MainActor @Observable
public final class OnlineModelSettings {
    public var transcriptionMode: EngineMode {
        didSet {
            guard transcriptionMode != oldValue else { return }
            defaults.set(transcriptionMode.rawValue, forKey: Keys.transcriptionMode)
            onChange?()
        }
    }

    public var minutesMode: EngineMode {
        didSet {
            guard minutesMode != oldValue else { return }
            defaults.set(minutesMode.rawValue, forKey: Keys.minutesMode)
            onChange?()
        }
    }

    public var transcriptionProvider: OnlineTranscriptionProvider {
        didSet {
            guard transcriptionProvider != oldValue else { return }
            defaults.set(transcriptionProvider.rawValue, forKey: Keys.transcriptionProvider)
            onChange?()
        }
    }

    public var minutesProvider: OnlineMinutesProvider {
        didSet {
            guard minutesProvider != oldValue else { return }
            defaults.set(minutesProvider.rawValue, forKey: Keys.minutesProvider)
            onChange?()
        }
    }

    public private(set) var lastCredentialError: String?

    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any CredentialStore

    private var transcriptionBaseURLs: [OnlineTranscriptionProvider: String]
    private var transcriptionModels: [OnlineTranscriptionProvider: String]
    private var minutesBaseURLs: [OnlineMinutesProvider: String]
    private var minutesModels: [OnlineMinutesProvider: String]
    private var credentialRevision: Int = 0

    public init(defaults: UserDefaults, credentials: any CredentialStore) {
        self.defaults = defaults
        self.credentials = credentials
        self.transcriptionMode = defaults.string(forKey: Keys.transcriptionMode)
            .flatMap(EngineMode.init(rawValue:)) ?? .local
        self.minutesMode = defaults.string(forKey: Keys.minutesMode)
            .flatMap(EngineMode.init(rawValue:)) ?? .local
        self.transcriptionProvider = defaults.string(forKey: Keys.transcriptionProvider)
            .flatMap(OnlineTranscriptionProvider.init(rawValue:)) ?? .dashScope
        self.minutesProvider = defaults.string(forKey: Keys.minutesProvider)
            .flatMap(OnlineMinutesProvider.init(rawValue:)) ?? .deepSeek
        self.transcriptionBaseURLs = Self.loadPresetMap(defaults: defaults, scope: Keys.transcriptionScope, field: Keys.baseURLField)
        self.transcriptionModels = Self.loadPresetMap(defaults: defaults, scope: Keys.transcriptionScope, field: Keys.modelField)
        self.minutesBaseURLs = Self.loadPresetMap(defaults: defaults, scope: Keys.minutesScope, field: Keys.baseURLField)
        self.minutesModels = Self.loadPresetMap(defaults: defaults, scope: Keys.minutesScope, field: Keys.modelField)
    }

    public var transcriptionBaseURL: String {
        get { transcriptionBaseURLs[transcriptionProvider] ?? transcriptionProvider.defaultBaseURL }
        set { updatePresetValue(newValue, current: transcriptionBaseURL, provider: transcriptionProvider,
                                scope: Keys.transcriptionScope, field: Keys.baseURLField, map: &transcriptionBaseURLs) }
    }

    public var transcriptionModel: String {
        get { transcriptionModels[transcriptionProvider] ?? transcriptionProvider.defaultModel }
        set { updatePresetValue(newValue, current: transcriptionModel, provider: transcriptionProvider,
                                scope: Keys.transcriptionScope, field: Keys.modelField, map: &transcriptionModels) }
    }

    public var transcriptionAPIKey: String {
        get { apiKey(for: transcriptionProvider.credentialSlot) }
        set { setAPIKey(newValue, for: transcriptionProvider.credentialSlot) }
    }

    public var minutesBaseURL: String {
        get { minutesBaseURLs[minutesProvider] ?? minutesProvider.defaultBaseURL }
        set { updatePresetValue(newValue, current: minutesBaseURL, provider: minutesProvider,
                                scope: Keys.minutesScope, field: Keys.baseURLField, map: &minutesBaseURLs) }
    }

    public var minutesModel: String {
        get { minutesModels[minutesProvider] ?? minutesProvider.defaultModel }
        set { updatePresetValue(newValue, current: minutesModel, provider: minutesProvider,
                                scope: Keys.minutesScope, field: Keys.modelField, map: &minutesModels) }
    }

    public var minutesAPIKey: String {
        get { apiKey(for: minutesProvider.credentialSlot) }
        set { setAPIKey(newValue, for: minutesProvider.credentialSlot) }
    }

    public func transcriptionConfig(for provider: OnlineTranscriptionProvider) -> OnlineEndpointConfig {
        OnlineEndpointConfig(
            baseURL: transcriptionBaseURLs[provider] ?? provider.defaultBaseURL,
            model: transcriptionModels[provider] ?? provider.defaultModel,
            apiKey: apiKey(for: provider.credentialSlot),
            requiresHTTPS: provider.requiresHTTPS,
            requiresAPIKey: provider.requiresAPIKey,
            providerID: provider.providerID
        )
    }

    public func minutesConfig(for provider: OnlineMinutesProvider) -> OnlineEndpointConfig {
        OnlineEndpointConfig(
            baseURL: minutesBaseURLs[provider] ?? provider.defaultBaseURL,
            model: minutesModels[provider] ?? provider.defaultModel,
            apiKey: apiKey(for: provider.credentialSlot),
            requiresHTTPS: provider.requiresHTTPS,
            requiresAPIKey: provider.requiresAPIKey,
            providerID: provider.providerID
        )
    }

    public var activeTranscriptionConfig: OnlineEndpointConfig {
        transcriptionConfig(for: transcriptionProvider)
    }

    public var activeMinutesConfig: OnlineEndpointConfig {
        minutesConfig(for: minutesProvider)
    }

    public var isTranscriptionReady: Bool {
        transcriptionMode == .local || activeTranscriptionConfig.isReady
    }

    private func apiKey(for slot: CredentialSlot) -> String {
        _ = credentialRevision
        return credentials.string(for: slot)
    }

    private func setAPIKey(_ newValue: String, for slot: CredentialSlot) {
        guard credentials.string(for: slot) != newValue else { return }
        do {
            try credentials.setString(newValue, for: slot)
            lastCredentialError = nil
            credentialRevision += 1
            onChange?()
        } catch {
            lastCredentialError = error.localizedDescription
        }
    }

    private func updatePresetValue<Provider: RawRepresentable & Hashable>(
        _ newValue: String,
        current: String,
        provider: Provider,
        scope: String,
        field: String,
        map: inout [Provider: String]
    ) where Provider.RawValue == String {
        guard newValue != current else { return }
        map[provider] = newValue
        defaults.set(newValue, forKey: Keys.preset(scope: scope, provider: provider.rawValue, field: field))
        onChange?()
    }

    private static func loadPresetMap<Provider: RawRepresentable & CaseIterable & Hashable>(
        defaults: UserDefaults,
        scope: String,
        field: String
    ) -> [Provider: String] where Provider.RawValue == String {
        var result: [Provider: String] = [:]
        for provider in Provider.allCases {
            let key = Keys.preset(scope: scope, provider: provider.rawValue, field: field)
            if let value = defaults.string(forKey: key) {
                result[provider] = value
            }
        }
        return result
    }

    private enum Keys {
        static let transcriptionMode = "online.transcription.mode"
        static let minutesMode = "online.minutes.mode"
        static let transcriptionProvider = "online.transcription.provider"
        static let minutesProvider = "online.minutes.provider"
        static let transcriptionScope = "transcription"
        static let minutesScope = "minutes"
        static let baseURLField = "baseURL"
        static let modelField = "model"

        static func preset(scope: String, provider: String, field: String) -> String {
            "online.\(scope).preset.\(provider).\(field)"
        }
    }
}
