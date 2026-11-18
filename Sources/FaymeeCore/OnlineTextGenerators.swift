import Foundation

/// 在线纪要模型的默认上下文与单次正文预算。分段按正文预算留输出；请求的输出上限另含思考，见 `OnlineOutputLimit`
public enum OnlineMinutesDefaults {
    public static let contextTokens = 64_000
    public static let maxOutputTokens = 8_192
}

/// 在线请求的输出上限（`max_tokens` / `maxOutputTokens`）。各家的思考都算在这个上限里，所以不按正文预算发，
/// 按模型接受的值发，给思考留出余量。超过模型的上限会被拒（DeepSeek 实测 400），所以按服务商和模型分别取
/// （各家文档，2026-11）：
/// - DeepSeek：接受 1–393216；取 65536，即思考模式不传时的默认值。旧名 deepseek-chat / reasoner 已转到 deepseek-flash
/// - 阿里云百炼：qwen-plus 32768；qwen-max 8192；qwen-turbo 查不到，按 8192；其他（qwen3.5-plus 起 64K 以上）按 32768
/// - OpenAI：gpt-4.1 系 32768；gpt-4o 系和其他 16384
/// - Anthropic：Sonnet 4.5、Haiku 4.5 64000；其他按 32000（Opus 4 / 4.1 的上限，更新的模型都不低于它）
/// - Gemini：2.0 及更早 8192；2.5 起 65536
/// - 自定义网关：后面是什么模型、接受多大都不知道，用以前一直被接受的 8192
///
/// 调用方要的正文预算比这个还大时按调用方的发。表里没有的模型按服务商取，它的上限若更低会被拒（400），
/// 这时按调用方的正文预算再发一次（同放大以前）
enum OnlineOutputLimit {
    /// 思考吃光上限、正文为空时再试一次的上限。只有自定义网关有：别的已按模型接受的值发，放大会被拒。
    /// 32768 是常见 OpenAI 兼容模型普遍接受的值（gpt-4.1、qwen-plus 等）；网关不接受时报它的 400
    static func retryTokens(providerID: String) -> Int? {
        switch providerID {
        case OnlineMinutesProvider.deepSeek.providerID, OnlineMinutesProvider.dashScope.providerID,
             OnlineMinutesProvider.openAI.providerID, OnlineMinutesProvider.anthropic.providerID,
             OnlineMinutesProvider.gemini.providerID:
            nil
        default:
            32_768
        }
    }

    static func tokens(providerID: String, model: String) -> Int {
        let model = model.lowercased()
        switch providerID {
        case OnlineMinutesProvider.deepSeek.providerID:
            return 65_536
        case OnlineMinutesProvider.dashScope.providerID:
            if model.hasPrefix("qwen-max") || model.hasPrefix("qwen-turbo") { return 8_192 }
            return 32_768
        case OnlineMinutesProvider.openAI.providerID:
            return model.hasPrefix("gpt-4.1") ? 32_768 : 16_384
        case OnlineMinutesProvider.anthropic.providerID:
            return model.hasPrefix("claude-sonnet-4-5") || model.hasPrefix("claude-haiku-4-5") ? 64_000 : 32_000
        case OnlineMinutesProvider.gemini.providerID:
            let name = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
            return name.hasPrefix("gemini-1") || name.hasPrefix("gemini-2.0") ? 8_192 : 65_536
        default:
            return 8_192
        }
    }
}

extension OnlineEndpointConfig {
    /// 发出去的输出上限：至少是这个模型的 `OnlineOutputLimit`
    func requestTokens(_ maxTokens: Int) -> Int {
        max(maxTokens, OnlineOutputLimit.tokens(providerID: providerID, model: trimmedModel))
    }
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

    /// 请求参数被拒（HTTP 400，且不是模型不存在）：去掉 JSON 模式重发
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

/// 三个在线协议适配器共用的：配置就绪即可用、按字数估 token
protocol OnlineTextGenerator: TextGenerator {
    var config: OnlineEndpointConfig { get }
}

extension OnlineTextGenerator {
    public var isDownloaded: Bool { config.isReady }

    public func countTokens(_ text: String) -> Int {
        OnlineTokenEstimator.countTokens(text)
    }
}

/// OpenAI Chat Completions 兼容协议适配器（覆盖 DeepSeek、阿里云百炼、OpenAI 及自定义网关）
public final class OpenAICompatibleTextGenerator: OnlineTextGenerator, ConnectionProbable, Sendable {
    public let config: OnlineEndpointConfig
    public let contextTokens: Int
    public let maxOutputTokens: Int
    let transport: any HTTPTransport
    let requestTimeout: TimeInterval

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
        let tokens = config.requestTokens(maxTokens)
        func send(format: Bool, tokens: Int) async throws -> HTTPResponse {
            try await OnlineTextSupport.postJSON(
                url: url,
                headers: headers,
                payload: buildPayload(system: system, prompt: prompt, maxTokens: tokens, includeResponseFormat: format),
                timeout: requestTimeout,
                transport: transport
            )
        }

        // 400 时先去掉 response_format 重试；仍被拒、且上限比正文预算大（表里没有、上限更低的模型），按正文预算再发
        var format = true
        var sent = tokens
        var response = try await send(format: format, tokens: sent)
        if OnlineTextSupport.isRejectedParameter(response) {
            try Task.checkCancellation()
            format = false
            response = try await send(format: format, tokens: sent)
        }
        if sent > maxTokens, OnlineTextSupport.isRejectedParameter(response) {
            try Task.checkCancellation()
            sent = maxTokens
            response = try await send(format: format, tokens: sent)
        }
        try response.checkSuccess()
        var choice = try firstChoice(from: response.data)

        // 思考吃光了上限、正文为空：上限还没到模型接受的值（自定义网关）时放大再试一次，仍为空照常报错
        if choice.finishReason == "length", (try? OnlineTextSupport.extractNormalizedText(choice.text ?? "")) == nil,
           let retry = OnlineOutputLimit.retryTokens(providerID: config.providerID), retry > sent
        {
            try Task.checkCancellation()
            response = try await send(format: format, tokens: retry)
            try response.checkSuccess()
            choice = try firstChoice(from: response.data)
        }

        guard let text = choice.text else { throw OnlineAPIError.emptyResponse }
        return try OnlineTextSupport.extractNormalizedText(text)
    }

    /// 第一条回复的正文（`content` 为字符串或文本分片）和结束原因。没有正文字段时 `text` 为 nil
    private func firstChoice(from data: Data) throws -> (text: String?, finishReason: String?) {
        let choices = try OnlineTextSupport.decodeArrayField("choices", from: data)
        guard let first = choices.first, let message = first["message"] as? [String: Any] else {
            throw OnlineAPIError.emptyResponse
        }
        let text: String?
        if let string = message["content"] as? String {
            text = string
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { part -> String? in
                if let type = part["type"] as? String, type != "text" { return nil }
                return part["text"] as? String
            }.joined()
        } else {
            text = nil
        }
        return (text, first["finish_reason"] as? String)
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

    private func buildPayload(
        system: String, prompt: String, maxTokens: Int, includeResponseFormat: Bool
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
        return payload
    }
}

/// Anthropic Messages 原生协议适配器
public final class AnthropicTextGenerator: OnlineTextGenerator, ConnectionProbable, Sendable {
    public let config: OnlineEndpointConfig
    public let contextTokens: Int
    public let maxOutputTokens: Int
    let transport: any HTTPTransport
    let requestTimeout: TimeInterval
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
        let send = { (payload: [String: Any]) in
            try await OnlineTextSupport.postJSON(url: url, headers: headers, payload: payload,
                                                 timeout: self.requestTimeout, transport: self.transport)
        }
        // 被拒（400）、且上限比正文预算大（表里没有、上限更低的模型）时按正文预算再发一次
        let tokens = config.requestTokens(maxTokens)
        var response = try await send(buildPayload(system: system, prompt: prompt, maxTokens: tokens))
        if tokens > maxTokens, OnlineTextSupport.isRejectedParameter(response) {
            try Task.checkCancellation()
            response = try await send(buildPayload(system: system, prompt: prompt, maxTokens: maxTokens))
        }
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
public final class GeminiTextGenerator: OnlineTextGenerator, ConnectionProbable, Sendable {
    private static let safetyFinishReasons: Set<String> = [
        "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII",
    ]
    public let config: OnlineEndpointConfig
    public let contextTokens: Int
    public let maxOutputTokens: Int
    let transport: any HTTPTransport
    let requestTimeout: TimeInterval

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

    public func load(progress: @escaping (Double) -> Void) async throws {
        try Task.checkCancellation()
        progress(1)
    }

    public func unload() {}

    public func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        try Task.checkCancellation()
        try config.validateReady()

        let url = try generateContentURL()
        let headers = authHeaders()
        func send(_ tokens: Int) async throws -> HTTPResponse {
            try await OnlineTextSupport.postJSON(
                url: url,
                headers: headers,
                payload: buildPayload(system: system, prompt: prompt, maxTokens: tokens,
                                      responseMimeType: "application/json"),
                timeout: requestTimeout,
                transport: transport
            )
        }
        // 被拒（400）、且上限比正文预算大（表里没有、上限更低的模型）时按正文预算再发一次
        let tokens = config.requestTokens(maxTokens)
        var response = try await send(tokens)
        if tokens > maxTokens, OnlineTextSupport.isRejectedParameter(response) {
            try Task.checkCancellation()
            response = try await send(maxTokens)
        }
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
