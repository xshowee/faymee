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
    static let connectionTestPrompt = "OK"
    static let connectionTestMaxTokens = 16
    /// 关不掉思考时（服务端拒收关思考的参数，或只能调低）在输出上限上多留的 token，免得思考吃光上限、正文为空
    static let reasoningHeadroomTokens = 16_384

    /// 关思考的请求被拒（HTTP 400，且不是模型不存在）时才去掉开关重发
    static func isRejectedParameter(_ response: HTTPResponse) -> Bool {
        response.status == 400 && !OnlineAPIError.isModelNotFoundError(data: response.data)
    }

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
        let stripped = stripLeadingThinkBlock(raw)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OnlineAPIError.emptyResponse }
        return trimmed
    }

    static func decodeArrayField(_ key: String, from data: Data) throws -> [[String: Any]] {
        let json = try decodeJSONObject(from: data)
        return try decodeArrayField(key, from: json)
    }

    static func decodeArrayField(_ key: String, from json: [String: Any]) throws -> [[String: Any]] {
        guard let array = json[key] as? [[String: Any]] else {
            if let errorMessage = OnlineAPIError.extractServerMessage(from: json) {
                throw OnlineAPIError.remoteTaskFailed(errorMessage)
            }
            throw OnlineAPIError.invalidResponse("响应缺少 \(key) 字段")
        }
        return array
    }
}

private protocol ConnectionProbable: TextGenerator {
    func probeConnection() async throws
}

/// OpenAI Chat Completions 兼容协议适配器（覆盖 DeepSeek、阿里云百炼、OpenAI 及自定义网关）
public final class OpenAICompatibleTextGenerator: TextGenerator, ConnectionProbable, Sendable {
    public let config: OnlineEndpointConfig
    public let contextTokens: Int
    public let maxOutputTokens: Int
    private let transport: any HTTPTransport
    private let requestTimeout: TimeInterval
    /// 为 true 时按服务商关思考（纠错用，见 `withThinkingDisabled`）；纪要不关
    let thinkingDisabled: Bool

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
        requestTimeout: TimeInterval,
        thinkingDisabled: Bool = false
    ) {
        self.config = config
        self.transport = transport
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
        self.requestTimeout = requestTimeout
        self.thinkingDisabled = thinkingDisabled
    }

    public func withThinkingDisabled() -> any TextGenerator {
        Self(config: config, transport: transport, contextTokens: contextTokens, maxOutputTokens: maxOutputTokens,
             requestTimeout: requestTimeout, thinkingDisabled: true)
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

        let url = try endpointURL()
        let headers = authHeaders()
        let thinkingOff = thinkingDisabled ? thinkingOffFields() : [:]
        let send = { (payload: [String: Any]) in
            try await OnlineTextSupport.postJSON(url: url, headers: headers, payload: payload,
                                                 timeout: self.requestTimeout, transport: self.transport)
        }

        // 400 时先去掉 response_format 重试；关思考的开关还被拒，再去掉开关、留出思考的余量
        var response = try await send(buildPayload(system: system, prompt: prompt, maxTokens: maxTokens,
                                                   includeResponseFormat: true, extra: thinkingOff))
        if OnlineTextSupport.isRejectedParameter(response) {
            try Task.checkCancellation()
            response = try await send(buildPayload(system: system, prompt: prompt, maxTokens: maxTokens,
                                                   includeResponseFormat: false, extra: thinkingOff))
        }
        if !thinkingOff.isEmpty, OnlineTextSupport.isRejectedParameter(response) {
            try Task.checkCancellation()
            response = try await send(buildPayload(
                system: system, prompt: prompt, maxTokens: maxTokens + OnlineTextSupport.reasoningHeadroomTokens,
                includeResponseFormat: false
            ))
        }

        try response.checkSuccess()
        let message = try firstMessage(from: response.data)

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

    func probeConnection() async throws {
        try Task.checkCancellation()
        try config.validateReady()

        let response = try await OnlineTextSupport.postJSON(
            url: try endpointURL(),
            headers: authHeaders(),
            payload: buildPayload(
                system: "",
                prompt: OnlineTextSupport.connectionTestPrompt,
                maxTokens: OnlineTextSupport.connectionTestMaxTokens,
                includeResponseFormat: false
            ),
            timeout: requestTimeout,
            transport: transport
        )
        try response.checkSuccess()
        let message = try firstMessage(from: response.data)
        let hasText = message["content"] is String
            || (message["content"] as? [[String: Any]])?.contains(where: { $0["text"] is String }) == true
        let hasReasoning = message["reasoning_content"] is String
        guard hasText || hasReasoning else {
            throw OnlineAPIError.emptyResponse
        }
    }

    private func endpointURL() throws -> URL {
        try OnlineTextSupport.endpointURL(baseURL: config.trimmedBaseURL, appendingPath: "/chat/completions")
    }

    private func authHeaders() -> [String: String] {
        let apiKey = config.trimmedAPIKey
        return apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(apiKey)"]
    }

    private func firstMessage(from data: Data) throws -> [String: Any] {
        let choices = try OnlineTextSupport.decodeArrayField("choices", from: data)
        guard let first = choices.first, let message = first["message"] as? [String: Any] else {
            throw OnlineAPIError.emptyResponse
        }
        return message
    }

    /// 各服务商关思考的参数（OpenAI Chat Completions 之外的扩展字段）：
    /// - DeepSeek：`thinking: {type: "disabled"}`（deepseek-flash 等默认思考）
    /// - 阿里云百炼：`enable_thinking: false`（Qwen3.5 及以后的混合思考模型默认思考）
    /// OpenAI 和自定义网关不发：OpenAI 能关思考的推理模型不收 `max_tokens`，本来就用不了；网关后面是什么模型不知道
    private func thinkingOffFields() -> [String: Any] {
        switch config.providerID {
        case OnlineMinutesProvider.deepSeek.providerID: ["thinking": ["type": "disabled"]]
        case OnlineMinutesProvider.dashScope.providerID: ["enable_thinking": false]
        default: [:]
        }
    }

    private func buildPayload(
        system: String, prompt: String, maxTokens: Int, includeResponseFormat: Bool, extra: [String: Any] = [:]
    ) -> [String: Any] {
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
        payload.merge(extra) { _, new in new }
        return payload
    }
}

/// Anthropic Messages 原生协议适配器
public final class AnthropicTextGenerator: TextGenerator, ConnectionProbable, Sendable {
    public let config: OnlineEndpointConfig
    public let contextTokens: Int
    public let maxOutputTokens: Int
    private let transport: any HTTPTransport
    private let requestTimeout: TimeInterval
    /// 为 true 时按服务商关思考（纠错用，见 `withThinkingDisabled`）；纪要不关
    let thinkingDisabled: Bool
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
        requestTimeout: TimeInterval,
        thinkingDisabled: Bool = false
    ) {
        self.config = config
        self.transport = transport
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
        self.requestTimeout = requestTimeout
        self.thinkingDisabled = thinkingDisabled
    }

    public func withThinkingDisabled() -> any TextGenerator {
        Self(config: config, transport: transport, contextTokens: contextTokens, maxOutputTokens: maxOutputTokens,
             requestTimeout: requestTimeout, thinkingDisabled: true)
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

        let response = try await OnlineTextSupport.postJSON(
            url: try endpointURL(),
            headers: authHeaders(),
            payload: buildPayload(system: system, prompt: prompt, maxTokens: maxTokens),
            timeout: requestTimeout,
            transport: transport
        )
        try response.checkSuccess()

        let blocks = try OnlineTextSupport.decodeArrayField("content", from: response.data)
        let text = blocks.compactMap { block -> String? in
            if let type = block["type"] as? String, type != "text" { return nil }
            return block["text"] as? String
        }.joined()

        return try OnlineTextSupport.extractNormalizedText(text)
    }

    func probeConnection() async throws {
        try Task.checkCancellation()
        try config.validateReady()

        let response = try await OnlineTextSupport.postJSON(
            url: try endpointURL(),
            headers: authHeaders(),
            payload: buildPayload(
                system: "",
                prompt: OnlineTextSupport.connectionTestPrompt,
                maxTokens: OnlineTextSupport.connectionTestMaxTokens
            ),
            timeout: requestTimeout,
            transport: transport
        )
        try response.checkSuccess()

        let blocks = try OnlineTextSupport.decodeArrayField("content", from: response.data)
        guard !blocks.isEmpty,
              blocks.contains(where: { $0["text"] is String || $0["thinking"] is String })
        else {
            throw OnlineAPIError.emptyResponse
        }
    }

    private func endpointURL() throws -> URL {
        try OnlineTextSupport.endpointURL(baseURL: config.trimmedBaseURL, appendingPath: "/messages")
    }

    private func authHeaders() -> [String: String] {
        var headers = ["anthropic-version": Self.apiVersion]
        let apiKey = config.trimmedAPIKey
        if !apiKey.isEmpty {
            headers["x-api-key"] = apiKey
        }
        return headers
    }

    private func buildPayload(system: String, prompt: String, maxTokens: Int) -> [String: Any] {
        var payload: [String: Any] = [
            "model": config.trimmedModel,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]],
        ]
        if !system.isEmpty {
            payload["system"] = system
        }
        return payload
    }
}

/// Google Gemini 原生 generateContent 协议适配器
public final class GeminiTextGenerator: TextGenerator, ConnectionProbable, Sendable {
    private static let safetyFinishReasons: Set<String> = [
        "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII",
    ]
    public let config: OnlineEndpointConfig
    public let contextTokens: Int
    public let maxOutputTokens: Int
    private let transport: any HTTPTransport
    private let requestTimeout: TimeInterval
    /// 为 true 时按服务商关思考（纠错用，见 `withThinkingDisabled`）；纪要不关
    let thinkingDisabled: Bool

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
        requestTimeout: TimeInterval,
        thinkingDisabled: Bool = false
    ) {
        self.config = config
        self.transport = transport
        self.contextTokens = contextTokens
        self.maxOutputTokens = maxOutputTokens
        self.requestTimeout = requestTimeout
        self.thinkingDisabled = thinkingDisabled
    }

    public func withThinkingDisabled() -> any TextGenerator {
        Self(config: config, transport: transport, contextTokens: contextTokens, maxOutputTokens: maxOutputTokens,
             requestTimeout: requestTimeout, thinkingDisabled: true)
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

        let response = try await OnlineTextSupport.postJSON(
            url: try generateContentURL(),
            headers: authHeaders(),
            payload: buildPayload(
                system: system,
                prompt: prompt,
                maxTokens: maxTokens,
                responseMimeType: "application/json"
            ),
            timeout: requestTimeout,
            transport: transport
        )
        try response.checkSuccess()

        let (parts, finishReason) = try firstCandidateParts(from: response.data)
        let rawText = parts.compactMap { part -> String? in
            if (part["thought"] as? Bool) == true { return nil }
            return part["text"] as? String
        }.joined()

        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty,
           let finishReason,
           Self.safetyFinishReasons.contains(finishReason)
        {
            throw OnlineAPIError.remoteTaskFailed("内容被安全策略拦截（\(finishReason)）")
        }

        return try OnlineTextSupport.extractNormalizedText(rawText)
    }

    func probeConnection() async throws {
        try Task.checkCancellation()
        try config.validateReady()

        let response = try await OnlineTextSupport.postJSON(
            url: try generateContentURL(),
            headers: authHeaders(),
            payload: buildPayload(
                system: "",
                prompt: OnlineTextSupport.connectionTestPrompt,
                maxTokens: OnlineTextSupport.connectionTestMaxTokens,
                responseMimeType: nil
            ),
            timeout: requestTimeout,
            transport: transport
        )
        try response.checkSuccess()

        let (parts, finishReason) = try firstCandidateParts(from: response.data)
        if let finishReason, Self.safetyFinishReasons.contains(finishReason) {
            throw OnlineAPIError.remoteTaskFailed("内容被安全策略拦截（\(finishReason)）")
        }
        guard parts.contains(where: { $0["text"] is String || $0["thought"] is String }) else {
            throw OnlineAPIError.emptyResponse
        }
    }

    private func authHeaders() -> [String: String] {
        let apiKey = config.trimmedAPIKey
        return apiKey.isEmpty ? [:] : ["x-goog-api-key": apiKey]
    }

    private func buildPayload(
        system: String,
        prompt: String,
        maxTokens: Int,
        responseMimeType: String?
    ) -> [String: Any] {
        var generationConfig: [String: Any] = ["maxOutputTokens": maxTokens]
        if let responseMimeType {
            generationConfig["responseMimeType"] = responseMimeType
        }
        var payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": prompt]],
                ]
            ],
            "generationConfig": generationConfig,
        ]
        if !system.isEmpty {
            payload["systemInstruction"] = ["parts": [["text": system]]]
        }
        return payload
    }

    private func firstCandidateParts(from data: Data) throws -> (parts: [[String: Any]], finishReason: String?) {
        let json = try OnlineTextSupport.decodeJSONObject(from: data)
        if let promptFeedback = json["promptFeedback"] as? [String: Any],
           let blockReason = promptFeedback["blockReason"] as? String,
           !blockReason.isEmpty
        {
            throw OnlineAPIError.remoteTaskFailed("内容被安全策略拦截（\(blockReason)）")
        }

        let candidates = try OnlineTextSupport.decodeArrayField("candidates", from: json)
        guard let first = candidates.first else {
            throw OnlineAPIError.emptyResponse
        }
        let parts = ((first["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        return (parts, first["finishReason"] as? String)
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
        try await generator.probeConnection()
    }

    private static func makeGenerator(
        provider: OnlineMinutesProvider,
        config: OnlineEndpointConfig,
        transport: any HTTPTransport,
        timeout: TimeInterval
    ) -> any ConnectionProbable {
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
