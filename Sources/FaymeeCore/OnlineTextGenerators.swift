import Foundation

/// 在线纪要模型的默认上下文与单次最大输出预算
public enum OnlineMinutesDefaults {
    public static let contextTokens = 64_000
    public static let maxOutputTokens = 8_192
}

/// 纯本地启发式 token 估算：中日韩字符按高权重估算，西文按字母数字词数与字符数估算，
/// 标点符号单独计权，并整体预留约 20% 安全余量，保证对字符串追加内容时单调不减
enum OnlineTokenEstimator {
    /// 以 1/100 token 为单位累加，已包含约 20% 安全余量（1.2x）
    static func countTokens(_ text: String) -> Int {
        var units = 0
        var inWesternWord = false

        for scalar in text.unicodeScalars {
            if isCJKScalar(scalar) {
                inWesternWord = false
                units += 150
            } else if scalar.properties.isWhitespace {
                inWesternWord = false
                units += 12
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                if !inWesternWord {
                    units += 72
                    inWesternWord = true
                }
                units += 36
            } else {
                inWesternWord = false
                units += scalar.isASCII ? 96 : 150
            }
        }

        return units == 0 ? 0 : (units + 99) / 100
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK 标点符号
             0x3040...0x30FF,   // 平假名、片假名
             0x3400...0x4DBF,   // CJK 扩展 A
             0x4E00...0x9FFF,   // CJK 统一表意文字
             0xAC00...0xD7AF,   // 韩文音节
             0xF900...0xFAFF,   // CJK 兼容表意文字
             0xFF00...0xFFEF,   // 全角标点与半角片假名
             0x20000...0x2EBEF: // CJK 扩展 B–F
            true
        default:
            false
        }
    }
}

private enum OnlineTextSupport {
    static let requestTimeout: TimeInterval = 300
    static let connectionTestTimeout: TimeInterval = 30

    static func endpointURL(baseURL: String, appendingPath path: String) throws -> URL {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let url = URL(string: trimmed + path) else {
            throw OnlineAPIError.invalidConfiguration("请输入有效的接口地址")
        }
        return url
    }

    static func encodeJSONObject(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func decodeJSONObject(from data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { throw OnlineAPIError.emptyResponse }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OnlineAPIError.invalidResponse("无法解析服务端返回的 JSON")
        }
        return object
    }

    static func postJSON(
        url: URL,
        headers: [String: String],
        payload: [String: Any],
        timeout: TimeInterval,
        transport: any HTTPTransport
    ) async throws -> HTTPResponse {
        var mergedHeaders = headers
        mergedHeaders["Content-Type"] = "application/json"
        mergedHeaders["Accept"] = "application/json"
        let data = try encodeJSONObject(payload)
        return try await transport.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: mergedHeaders,
            body: .data(data),
            timeout: timeout
        ))
    }

    static func extractNormalizedText(_ raw: String) throws -> String {
        let stripped = LlamaTextGenerator.stripThink(raw)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OnlineAPIError.emptyResponse }
        return trimmed
    }

    static func extractErrorMessage(from object: [String: Any]) -> String? {
        let candidates: [String?] = [
            (object["error"] as? [String: Any])?["message"] as? String,
            object["error"] as? String,
            object["message"] as? String,
        ]
        for candidate in candidates {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return String(trimmed.prefix(240))
            }
        }
        return nil
    }
}

/// OpenAI Chat Completions 兼容协议适配器（覆盖 DeepSeek、阿里云百炼、OpenAI 及自定义网关）
public final class OpenAICompatibleTextGenerator: TextGenerator, Sendable {
    public let config: OnlineEndpointConfig
    public let contextTokens: Int
    public let maxOutputTokens: Int
    private let transport: any HTTPTransport
    private let requestTimeout: TimeInterval

    public convenience init(
        config: OnlineEndpointConfig,
        transport: any HTTPTransport,
        contextTokens: Int = OnlineMinutesDefaults.contextTokens,
        maxOutputTokens: Int = OnlineMinutesDefaults.maxOutputTokens
    ) {
        self.init(
            config: config,
            transport: transport,
            contextTokens: contextTokens,
            maxOutputTokens: maxOutputTokens,
            requestTimeout: OnlineTextSupport.requestTimeout
        )
    }

    init(
        config: OnlineEndpointConfig,
        transport: any HTTPTransport,
        contextTokens: Int,
        maxOutputTokens: Int,
        requestTimeout: TimeInterval
    ) {
        self.config = config
        self.transport = transport
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
        self.requestTimeout = requestTimeout
    }

    public var isDownloaded: Bool { config.isReady }

    public func countTokens(_ text: String) -> Int {
        OnlineTokenEstimator.countTokens(text)
    }

    public func load(progress: @escaping (Double) -> Void) async throws {
        try Task.checkCancellation()
        progress(1)
    }

    public func unload() {}

    public func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        try Task.checkCancellation()
        try config.validateReady()

        let url = try OnlineTextSupport.endpointURL(baseURL: config.trimmedBaseURL, appendingPath: "/chat/completions")
        var headers: [String: String] = [:]
        let apiKey = config.trimmedAPIKey
        if !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }

        var response = try await OnlineTextSupport.postJSON(
            url: url,
            headers: headers,
            payload: buildPayload(system: system, prompt: prompt, maxTokens: maxTokens, includeResponseFormat: true),
            timeout: requestTimeout,
            transport: transport
        )

        if response.status == 400 {
            try Task.checkCancellation()
            response = try await OnlineTextSupport.postJSON(
                url: url,
                headers: headers,
                payload: buildPayload(system: system, prompt: prompt, maxTokens: maxTokens, includeResponseFormat: false),
                timeout: requestTimeout,
                transport: transport
            )
        }

        try response.checkSuccess()
        let json = try OnlineTextSupport.decodeJSONObject(from: response.data)

        guard let choices = json["choices"] as? [[String: Any]] else {
            if let errorMessage = OnlineTextSupport.extractErrorMessage(from: json) {
                throw OnlineAPIError.remoteTaskFailed(errorMessage)
            }
            throw OnlineAPIError.invalidResponse("响应缺少 choices 字段")
        }
        guard let first = choices.first, let message = first["message"] as? [String: Any] else {
            throw OnlineAPIError.emptyResponse
        }

        let contentText: String
        if let string = message["content"] as? String {
            contentText = string
        } else if let parts = message["content"] as? [[String: Any]] {
            contentText = parts.compactMap { part -> String? in
                if let type = part["type"] as? String, type != "text" { return nil }
                return part["text"] as? String
            }.joined()
        } else {
            throw OnlineAPIError.emptyResponse
        }

        return try OnlineTextSupport.extractNormalizedText(contentText)
    }

    private func buildPayload(system: String, prompt: String, maxTokens: Int, includeResponseFormat: Bool) -> [String: Any] {
        var messages: [[String: String]] = []
        if !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        var payload: [String: Any] = [
            "model": config.trimmedModel,
            "messages": messages,
            "max_tokens": maxTokens,
        ]
        if includeResponseFormat {
            payload["response_format"] = ["type": "json_object"]
        }
        return payload
    }
}

/// Anthropic Messages 原生协议适配器
public final class AnthropicTextGenerator: TextGenerator, Sendable {
    public let config: OnlineEndpointConfig
    public let contextTokens: Int
    public let maxOutputTokens: Int
    private let transport: any HTTPTransport
    private let requestTimeout: TimeInterval
    private static let apiVersion = "2023-06-01"

    public convenience init(
        config: OnlineEndpointConfig,
        transport: any HTTPTransport,
        contextTokens: Int = OnlineMinutesDefaults.contextTokens,
        maxOutputTokens: Int = OnlineMinutesDefaults.maxOutputTokens
    ) {
        self.init(
            config: config,
            transport: transport,
            contextTokens: contextTokens,
            maxOutputTokens: maxOutputTokens,
            requestTimeout: OnlineTextSupport.requestTimeout
        )
    }

    init(
        config: OnlineEndpointConfig,
        transport: any HTTPTransport,
        contextTokens: Int,
        maxOutputTokens: Int,
        requestTimeout: TimeInterval
    ) {
        self.config = config
        self.transport = transport
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
        self.requestTimeout = requestTimeout
    }

    public var isDownloaded: Bool { config.isReady }

    public func countTokens(_ text: String) -> Int {
        OnlineTokenEstimator.countTokens(text)
    }

    public func load(progress: @escaping (Double) -> Void) async throws {
        try Task.checkCancellation()
        progress(1)
    }

    public func unload() {}

    public func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        try Task.checkCancellation()
        try config.validateReady()

        let url = try OnlineTextSupport.endpointURL(baseURL: config.trimmedBaseURL, appendingPath: "/messages")
        var headers = ["anthropic-version": Self.apiVersion]
        let apiKey = config.trimmedAPIKey
        if !apiKey.isEmpty {
            headers["x-api-key"] = apiKey
        }

        var payload: [String: Any] = [
            "model": config.trimmedModel,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]],
        ]
        if !system.isEmpty {
            payload["system"] = system
        }

        let response = try await OnlineTextSupport.postJSON(
            url: url,
            headers: headers,
            payload: payload,
            timeout: requestTimeout,
            transport: transport
        )
        try response.checkSuccess()

        let json = try OnlineTextSupport.decodeJSONObject(from: response.data)
        guard let blocks = json["content"] as? [[String: Any]] else {
            if let errorMessage = OnlineTextSupport.extractErrorMessage(from: json) {
                throw OnlineAPIError.remoteTaskFailed(errorMessage)
            }
            throw OnlineAPIError.invalidResponse("响应缺少 content 字段")
        }

        let text = blocks.compactMap { block -> String? in
            if let type = block["type"] as? String, type != "text" { return nil }
            return block["text"] as? String
        }.joined()

        return try OnlineTextSupport.extractNormalizedText(text)
    }
}

/// Google Gemini 原生 generateContent 协议适配器
public final class GeminiTextGenerator: TextGenerator, Sendable {
    public let config: OnlineEndpointConfig
    public let contextTokens: Int
    public let maxOutputTokens: Int
    private let transport: any HTTPTransport
    private let requestTimeout: TimeInterval

    public convenience init(
        config: OnlineEndpointConfig,
        transport: any HTTPTransport,
        contextTokens: Int = OnlineMinutesDefaults.contextTokens,
        maxOutputTokens: Int = OnlineMinutesDefaults.maxOutputTokens
    ) {
        self.init(
            config: config,
            transport: transport,
            contextTokens: contextTokens,
            maxOutputTokens: maxOutputTokens,
            requestTimeout: OnlineTextSupport.requestTimeout
        )
    }

    init(
        config: OnlineEndpointConfig,
        transport: any HTTPTransport,
        contextTokens: Int,
        maxOutputTokens: Int,
        requestTimeout: TimeInterval
    ) {
        self.config = config
        self.transport = transport
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
        self.requestTimeout = requestTimeout
    }

    public var isDownloaded: Bool { config.isReady }

    public func countTokens(_ text: String) -> Int {
        OnlineTokenEstimator.countTokens(text)
    }

    public func load(progress: @escaping (Double) -> Void) async throws {
        try Task.checkCancellation()
        progress(1)
    }

    public func unload() {}

    public func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        try Task.checkCancellation()
        try config.validateReady()

        let url = try generateContentURL()
        var headers: [String: String] = [:]
        let apiKey = config.trimmedAPIKey
        if !apiKey.isEmpty {
            headers["x-goog-api-key"] = apiKey
        }

        var payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": prompt]],
                ]
            ],
            "generationConfig": [
                "maxOutputTokens": maxTokens,
                "responseMimeType": "application/json",
            ],
        ]
        if !system.isEmpty {
            payload["systemInstruction"] = ["parts": [["text": system]]]
        }

        let response = try await OnlineTextSupport.postJSON(
            url: url,
            headers: headers,
            payload: payload,
            timeout: requestTimeout,
            transport: transport
        )
        try response.checkSuccess()

        let json = try OnlineTextSupport.decodeJSONObject(from: response.data)
        if let promptFeedback = json["promptFeedback"] as? [String: Any],
           let blockReason = promptFeedback["blockReason"] as? String,
           !blockReason.isEmpty
        {
            throw OnlineAPIError.remoteTaskFailed("内容被安全策略拦截（\(blockReason)）")
        }

        guard let candidates = json["candidates"] as? [[String: Any]] else {
            if let errorMessage = OnlineTextSupport.extractErrorMessage(from: json) {
                throw OnlineAPIError.remoteTaskFailed(errorMessage)
            }
            throw OnlineAPIError.invalidResponse("响应缺少 candidates 字段")
        }
        guard let first = candidates.first else {
            throw OnlineAPIError.emptyResponse
        }

        let parts = ((first["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let rawText = parts.compactMap { part -> String? in
            if (part["thought"] as? Bool) == true { return nil }
            return part["text"] as? String
        }.joined()

        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty,
           let finishReason = first["finishReason"] as? String,
           ["SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII"].contains(finishReason)
        {
            throw OnlineAPIError.remoteTaskFailed("内容被安全策略拦截（\(finishReason)）")
        }

        return try OnlineTextSupport.extractNormalizedText(rawText)
    }

    private func generateContentURL() throws -> URL {
        let rawModel = config.trimmedModel
        let cleanModel = rawModel.hasPrefix("models/") ? String(rawModel.dropFirst("models/".count)) : rawModel
        guard !cleanModel.isEmpty else {
            throw OnlineAPIError.invalidConfiguration("请填写模型标识")
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let encodedModel = cleanModel.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw OnlineAPIError.invalidConfiguration("请填写有效的模型标识")
        }
        return try OnlineTextSupport.endpointURL(
            baseURL: config.trimmedBaseURL,
            appendingPath: "/models/\(encodedModel):generateContent"
        )
    }
}

/// 在线纪要引擎工厂与连接测试入口
public enum OnlineMinutesEngine {
    public static func makeGenerator(
        provider: OnlineMinutesProvider,
        config: OnlineEndpointConfig,
        transport: any HTTPTransport
    ) -> any TextGenerator {
        makeGenerator(
            provider: provider,
            config: config,
            transport: transport,
            timeout: OnlineTextSupport.requestTimeout
        )
    }

    @MainActor
    public static func makeEngine(
        settings: OnlineModelSettings,
        transport: any HTTPTransport,
        local: () -> (generator: any TextGenerator, name: String)
    ) -> (generator: any TextGenerator, name: String, requiresPower: Bool, isOnline: Bool) {
        switch settings.minutesMode {
        case .local:
            let resolved = local()
            return (resolved.generator, resolved.name, true, false)
        case .online:
            let config = settings.activeMinutesConfig
            let generator = makeGenerator(
                provider: settings.minutesProvider,
                config: config,
                transport: transport
            )
            return (generator, config.sourceIdentifier, false, true)
        }
    }

    public static func testConnection(
        provider: OnlineMinutesProvider,
        config: OnlineEndpointConfig,
        transport: any HTTPTransport
    ) async throws {
        try Task.checkCancellation()
        try config.validateReady()
        let generator = makeGenerator(
            provider: provider,
            config: config,
            transport: transport,
            timeout: OnlineTextSupport.connectionTestTimeout
        )
        _ = try await generator.generate(
            system: "你是连接测试助手，只输出一行紧凑 json 对象，不要输出其他文字。",
            prompt: #"请只回复 {"ok":true}"#,
            maxTokens: 128
        )
    }

    private static func makeGenerator(
        provider: OnlineMinutesProvider,
        config: OnlineEndpointConfig,
        transport: any HTTPTransport,
        timeout: TimeInterval
    ) -> any TextGenerator {
        switch provider.protocolKind {
        case .openAICompatible:
            OpenAICompatibleTextGenerator(
                config: config,
                transport: transport,
                contextTokens: OnlineMinutesDefaults.contextTokens,
                maxOutputTokens: OnlineMinutesDefaults.maxOutputTokens,
                requestTimeout: timeout
            )
        case .anthropic:
            AnthropicTextGenerator(
                config: config,
                transport: transport,
                contextTokens: OnlineMinutesDefaults.contextTokens,
                maxOutputTokens: OnlineMinutesDefaults.maxOutputTokens,
                requestTimeout: timeout
            )
        case .gemini:
            GeminiTextGenerator(
                config: config,
                transport: transport,
                contextTokens: OnlineMinutesDefaults.contextTokens,
                maxOutputTokens: OnlineMinutesDefaults.maxOutputTokens,
                requestTimeout: timeout
            )
        }
    }
}
