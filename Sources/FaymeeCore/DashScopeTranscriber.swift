import CryptoKit
import Foundation

/// 阿里云百炼文件转写适配器：临时 OSS 直传、异步任务提交与轮询拉取分句结果
public final class DashScopeTranscriber: Transcriber, @unchecked Sendable {
    private static let maxPollDuration: Duration = .seconds(3600)

    private struct VocabularyCache {
        let fingerprint: String
        let vocabularyID: String
    }

    private let config: OnlineEndpointConfig
    private let transport: any HTTPTransport
    private let pollInterval: Duration
    private let cacheLock = NSLock()
    private var vocabularyCache: VocabularyCache?

    /// 构造百炼文件转写适配器；`pollInterval` 可注入以加速单元测试轮询
    public init(
        config: OnlineEndpointConfig,
        transport: any HTTPTransport,
        pollInterval: Duration = .seconds(2)
    ) {
        self.config = config
        self.transport = transport
        self.pollInterval = pollInterval
    }

    /// 快速校验配置完整性，百炼在线转写无需下载本地模型
    public func prepare(progress: @escaping (Double) -> Void) async throws {
        try Task.checkCancellation()
        try config.validateReady()
        progress(1)
    }

    /// 使用探测短音频走完策略获取、临时直传、提交与轮询拉取的真实链路以验证配置可用性
    public static func testConnection(
        config: OnlineEndpointConfig,
        transport: any HTTPTransport,
        pollInterval: Duration = .seconds(1)
    ) async throws {
        try Task.checkCancellation()
        try config.validateReady()
        try await ProbeAudio.withTemporaryWAV { wavURL in
            let transcriber = DashScopeTranscriber(
                config: config,
                transport: transport,
                pollInterval: pollInterval
            )
            try await transcriber.prepare { _ in }
            _ = try await transcriber.transcribe(audio: wavURL, hotwords: []) { _ in }
        }
    }

    /// 通过四步异步直传流程完成整段录音转写并返回秒级时间分句
    public func transcribe(
        audio: URL,
        hotwords: [String],
        progress: @escaping (Double) -> Void
    ) async throws -> [TranscribedSentence] {
        try Task.checkCancellation()
        try config.validateReady()
        guard FileManager.default.fileExists(atPath: audio.path) else {
            throw OnlineAPIError.invalidConfiguration("找不到待转写的音频文件")
        }

        let apiBase = try Self.resolveAPIBaseURL(from: config.trimmedBaseURL)
        let model = config.trimmedModel
        let apiKey = config.trimmedAPIKey

        progress(0.05)
        let policy = try await fetchUploadPolicy(apiBase: apiBase, model: model, apiKey: apiKey)

        progress(0.15)
        let ossURL = try await uploadToOSS(audio: audio, policy: policy)
        progress(0.40)

        let normalizedHotwords = Hotwords.normalize(hotwords)
        let taskID = try await submitTranscriptionTask(
            apiBase: apiBase,
            model: model,
            apiKey: apiKey,
            ossURL: ossURL,
            hotwords: normalizedHotwords
        )
        progress(0.45)

        let transcriptionURL = try await pollTaskUntilSucceeded(
            apiBase: apiBase,
            taskID: taskID,
            apiKey: apiKey,
            progress: progress
        )
        progress(0.95)

        let sentences = try await fetchAndParseTranscript(from: transcriptionURL)
        progress(1.0)
        return sentences
    }

    // MARK: - Step 1: Upload Policy

    private struct UploadPolicy {
        let uploadHost: URL
        let uploadDir: String
        let ossAccessKeyID: String
        let signature: String
        let policy: String
        let xOssObjectACL: String
        let xOssForbidOverwrite: String
    }

    private func fetchUploadPolicy(apiBase: URL, model: String, apiKey: String) async throws -> UploadPolicy {
        try Task.checkCancellation()
        var components = URLComponents(url: apiBase.appendingPathComponent("uploads"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "getPolicy"),
            URLQueryItem(name: "model", value: model),
        ]
        guard let url = components?.url else {
            throw OnlineAPIError.invalidConfiguration("无法构造上传策略请求地址")
        }

        let response = try await transport.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: authHeaders(apiKey: apiKey, contentType: "application/json"),
            timeout: 60
        ))
        try response.checkSuccess()

        let json = try parseJSONObject(from: response.data, context: "上传策略响应")
        guard let data = json["data"] as? [String: Any],
              let uploadHostString = Self.nonEmptyString(data["upload_host"]),
              let uploadHost = URL(string: uploadHostString),
              let policy = Self.nonEmptyString(data["policy"]),
              let signature = Self.nonEmptyString(data["signature"]),
              let ossAccessKeyID = Self.nonEmptyString(data["oss_access_key_id"])
        else {
            throw OnlineAPIError.invalidResponse("上传策略缺少必要字段")
        }

        let uploadDir = (data["upload_dir"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let acl = Self.nonEmptyString(data["x_oss_object_acl"]) ?? "private"
        let forbidOverwrite = Self.stringValue(data["x_oss_forbid_overwrite"]) ?? "true"

        return UploadPolicy(
            uploadHost: uploadHost,
            uploadDir: uploadDir,
            ossAccessKeyID: ossAccessKeyID,
            signature: signature,
            policy: policy,
            xOssObjectACL: acl,
            xOssForbidOverwrite: forbidOverwrite
        )
    }

    // MARK: - Step 2: Temporary OSS Multipart Upload

    private func uploadToOSS(audio: URL, policy: UploadPolicy) async throws -> String {
        try Task.checkCancellation()
        let ext = audio.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ext.isEmpty ? "wav" : ext.lowercased()
        let uniqueFileName = "\(UUID().uuidString).\(suffix)"
        let key = policy.uploadDir.isEmpty ? uniqueFileName : "\(policy.uploadDir)/\(uniqueFileName)"

        let parts: [MultipartPart] = [
            .text(name: "OSSAccessKeyId", value: policy.ossAccessKeyID),
            .text(name: "Signature", value: policy.signature),
            .text(name: "policy", value: policy.policy),
            .text(name: "x-oss-object-acl", value: policy.xOssObjectACL),
            .text(name: "x-oss-forbid-overwrite", value: policy.xOssForbidOverwrite),
            .text(name: "key", value: key),
            .text(name: "success_action_status", value: "200"),
            .file(name: "file", fileURL: audio, fileName: uniqueFileName, mimeType: AudioMIMEType.forExtension(suffix)),
        ]

        let response = try await transport.send(HTTPRequest(
            method: "POST",
            url: policy.uploadHost,
            headers: [:],
            body: .multipart(parts),
            timeout: 600
        ))
        try response.checkSuccess()
        return "oss://\(key)"
    }

    // MARK: - Step 3: Hotword Adaptation & Async Transcription Task

    private func submitTranscriptionTask(
        apiBase: URL,
        model: String,
        apiKey: String,
        ossURL: String,
        hotwords: [String]
    ) async throws -> String {
        let isQwen = Self.isQwenModel(model)
        let contextText: String? = (isQwen && !hotwords.isEmpty) ? hotwords.joined(separator: ", ") : nil
        let vocabularyID: String? = if !isQwen, !hotwords.isEmpty {
            try await syncVocabulary(apiBase: apiBase, model: model, apiKey: apiKey, hotwords: hotwords)
        } else {
            nil
        }

        let response = try await sendTaskSubmission(
            apiBase: apiBase,
            model: model,
            apiKey: apiKey,
            ossURL: ossURL,
            contextText: contextText,
            vocabularyID: vocabularyID
        )

        if response.status == 400,
           contextText != nil || vocabularyID != nil,
           !OnlineAPIError.isModelNotFoundError(data: response.data) {
            let fallbackResponse = try await sendTaskSubmission(
                apiBase: apiBase,
                model: model,
                apiKey: apiKey,
                ossURL: ossURL,
                contextText: nil,
                vocabularyID: nil
            )
            try fallbackResponse.checkSuccess()
            return try extractTaskID(from: fallbackResponse.data)
        }

        try response.checkSuccess()
        return try extractTaskID(from: response.data)
    }

    private func syncVocabulary(
        apiBase: URL,
        model: String,
        apiKey: String,
        hotwords: [String]
    ) async throws -> String? {
        try Task.checkCancellation()
        let fingerprint = Self.hotwordsFingerprint(apiBase: apiBase, model: model, hotwords: hotwords)
        let cached = cacheLock.withLock { vocabularyCache }
        if let cached, cached.fingerprint == fingerprint {
            return cached.vocabularyID
        }

        let entries: [[String: Any]] = hotwords.map { ["text": $0, "weight": 4] }

        if let existingID = cached?.vocabularyID {
            let updateResp = try await sendVocabularyRequest(
                apiBase: apiBase,
                apiKey: apiKey,
                input: [
                    "action": "update_vocabulary",
                    "vocabulary_id": existingID,
                    "vocabulary": entries,
                ]
            )
            if updateResp.status == 400 {
                cacheLock.withLock {
                    if vocabularyCache?.vocabularyID == existingID {
                        vocabularyCache = nil
                    }
                }
            } else {
                try updateResp.checkSuccess()
                let resolvedID = extractVocabularyID(from: updateResp.data, context: "更新热词响应") ?? existingID
                cacheLock.withLock {
                    vocabularyCache = VocabularyCache(fingerprint: fingerprint, vocabularyID: resolvedID)
                }
                return resolvedID
            }
        }

        let createResp = try await sendVocabularyRequest(
            apiBase: apiBase,
            apiKey: apiKey,
            input: [
                "action": "create_vocabulary",
                "target_model": model,
                "prefix": "faymee",
                "vocabulary": entries,
            ]
        )
        if createResp.status == 400 {
            return nil
        }
        try createResp.checkSuccess()

        guard let createdID = extractVocabularyID(from: createResp.data, context: "创建热词表响应") else {
            throw OnlineAPIError.invalidResponse("定制热词接口未返回 vocabulary_id")
        }
        cacheLock.withLock {
            vocabularyCache = VocabularyCache(fingerprint: fingerprint, vocabularyID: createdID)
        }
        return createdID
    }

    private func sendVocabularyRequest(
        apiBase: URL,
        apiKey: String,
        input: [String: Any]
    ) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let payload: [String: Any] = [
            "model": "speech-biasing",
            "input": input,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        let url = apiBase.appendingPathComponent("services/audio/asr/customization")
        return try await transport.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: authHeaders(apiKey: apiKey, contentType: "application/json"),
            body: .data(bodyData),
            timeout: 60
        ))
    }

    private func extractVocabularyID(from data: Data, context: String) -> String? {
        guard let json = try? parseJSONObject(from: data, context: context),
              let output = json["output"] as? [String: Any]
        else { return nil }
        return Self.nonEmptyString(output["vocabulary_id"])
    }

    private func sendTaskSubmission(
        apiBase: URL,
        model: String,
        apiKey: String,
        ossURL: String,
        contextText: String?,
        vocabularyID: String?
    ) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let url = apiBase.appendingPathComponent("services/audio/asr/transcription")
        let isQwen = Self.isQwenModel(model)
        let input: [String: Any] = isQwen ? ["file_url": ossURL] : ["file_urls": [ossURL]]
        var payload: [String: Any] = [
            "model": model,
            "input": input,
        ]
        if isQwen, let contextText {
            payload["parameters"] = ["corpus": ["text": contextText]]
        } else if !isQwen, let vocabularyID {
            payload["parameters"] = ["vocabulary_id": vocabularyID]
        }
        let bodyData = try JSONSerialization.data(withJSONObject: payload)

        var headers = authHeaders(apiKey: apiKey, contentType: "application/json")
        headers["X-DashScope-Async"] = "enable"
        headers["X-DashScope-OssResourceResolve"] = "enable"

        return try await transport.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: headers,
            body: .data(bodyData),
            timeout: 120
        ))
    }

    private func extractTaskID(from data: Data) throws -> String {
        let json = try parseJSONObject(from: data, context: "提交转写任务响应")
        guard let output = json["output"] as? [String: Any],
              let taskID = Self.nonEmptyString(output["task_id"])
        else {
            if let message = OnlineAPIError.extractServerMessage(from: json) {
                throw OnlineAPIError.remoteTaskFailed(message)
            }
            throw OnlineAPIError.invalidResponse("提交转写任务未返回 task_id")
        }
        return taskID
    }

    // MARK: - Step 4: Poll & Fetch Result

    private func pollTaskUntilSucceeded(
        apiBase: URL,
        taskID: String,
        apiKey: String,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let pollURL = apiBase.appendingPathComponent("tasks").appendingPathComponent(taskID)
        let deadline = ContinuousClock.now + Self.maxPollDuration
        var pollCount = 0

        while true {
            try Task.checkCancellation()
            if pollInterval > .zero {
                try await Task.sleep(for: pollInterval)
            }
            try Task.checkCancellation()

            pollCount += 1
            let response = try await transport.send(HTTPRequest(
                method: "GET",
                url: pollURL,
                headers: authHeaders(apiKey: apiKey, contentType: nil),
                timeout: 60
            ))
            try response.checkSuccess()

            let json = try parseJSONObject(from: response.data, context: "查询任务状态响应")
            guard let output = json["output"] as? [String: Any],
                  let rawStatus = Self.nonEmptyString(output["task_status"])
            else {
                throw OnlineAPIError.invalidResponse("查询任务状态缺少 task_status")
            }

            let status = rawStatus.uppercased()
            switch status {
            case "SUCCEEDED":
                return try extractTranscriptionURL(from: output)
            case "PENDING", "RUNNING", "QUEUED":
                let pollProgress = 0.45 + 0.50 * (1.0 - pow(0.85, Double(pollCount)))
                progress(min(0.94, pollProgress))
                if ContinuousClock.now >= deadline {
                    throw OnlineAPIError.timedOut
                }
            case "FAILED":
                throw OnlineAPIError.remoteTaskFailed(extractTaskFailureMessage(output: output, root: json))
            case "CANCELED", "CANCELLED":
                throw OnlineAPIError.remoteTaskFailed("云端转写任务已被取消")
            case "UNKNOWN":
                throw OnlineAPIError.remoteTaskFailed("云端转写任务不存在或已过期（UNKNOWN）")
            default:
                throw OnlineAPIError.invalidResponse("云端任务返回意外状态：\(rawStatus)")
            }
        }
    }

    private func extractTranscriptionURL(from output: [String: Any]) throws -> URL {
        if let results = output["results"] as? [[String: Any]], let first = results.first {
            if let subtaskStatus = Self.nonEmptyString(first["subtask_status"])?.uppercased(),
               subtaskStatus == "FAILED" {
                let detail = OnlineAPIError.extractServerMessage(from: first) ?? "子任务转写失败"
                throw OnlineAPIError.remoteTaskFailed(detail)
            }
            if let urlString = Self.nonEmptyString(first["transcription_url"]),
               let url = URL(string: urlString) {
                return url
            }
        }
        if let result = output["result"] as? [String: Any],
           let urlString = Self.nonEmptyString(result["transcription_url"]),
           let url = URL(string: urlString) {
            return url
        }
        if let urlString = Self.nonEmptyString(output["transcription_url"]),
           let url = URL(string: urlString) {
            return url
        }
        throw OnlineAPIError.invalidResponse("云端任务已完成，但未返回转写结果链接")
    }

    private func extractTaskFailureMessage(output: [String: Any], root: [String: Any]) -> String {
        if let msg = OnlineAPIError.extractServerMessage(from: output) {
            return msg
        }
        if let results = output["results"] as? [[String: Any]],
           let first = results.first,
           let msg = OnlineAPIError.extractServerMessage(from: first) {
            return msg
        }
        if let msg = OnlineAPIError.extractServerMessage(from: root) {
            return msg
        }
        return "云端转写任务执行失败"
    }

    private func fetchAndParseTranscript(from url: URL) async throws -> [TranscribedSentence] {
        try Task.checkCancellation()
        let response = try await transport.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [:],
            timeout: 180
        ))
        try response.checkSuccess()

        let json = try parseJSONObject(from: response.data, context: "转写结果文件")
        return try Self.parseTranscriptJSON(json)
    }

    static func parseTranscriptJSON(_ json: [String: Any]) throws -> [TranscribedSentence] {
        let channelObjects: [[String: Any]]
        if let transcripts = json["transcripts"] as? [[String: Any]] {
            channelObjects = transcripts
        } else if let sentences = json["sentences"] as? [[String: Any]] {
            channelObjects = [["sentences": sentences]]
        } else {
            throw OnlineAPIError.invalidResponse("转写结果缺少 transcripts 字段")
        }

        var collected: [(offset: Int, sentence: TranscribedSentence)] = []
        var offset = 0

        for channel in channelObjects {
            if let sentences = channel["sentences"] as? [[String: Any]], !sentences.isEmpty {
                for item in sentences {
                    guard let text = item["text"] as? String else {
                        throw OnlineAPIError.invalidResponse("分句缺少 text 字段")
                    }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    guard let beginMS = Self.numericValue(in: item, keys: ["begin_time", "start_time"]),
                          let endMS = Self.numericValue(in: item, keys: ["end_time", "stop_time"]) ?? Optional(beginMS)
                    else {
                        throw OnlineAPIError.invalidResponse("分句缺少时间戳字段")
                    }
                    let start = max(0, beginMS / 1000.0)
                    let end = max(start, endMS / 1000.0)
                    collected.append((offset, TranscribedSentence(start: start, end: end, text: trimmed)))
                    offset += 1
                }
            } else if let text = Self.nonEmptyString(channel["text"]) {
                let durationMS = Self.numericValue(in: channel, keys: ["content_duration_in_milliseconds"]) ?? 0
                let end = max(0, durationMS / 1000.0)
                collected.append((offset, TranscribedSentence(start: 0, end: end, text: text)))
                offset += 1
            }
        }

        return collected
            .sorted { ($0.sentence.start, $0.sentence.end, $0.offset) < ($1.sentence.start, $1.sentence.end, $1.offset) }
            .map(\.sentence)
    }

    // MARK: - Helpers

    private static func resolveAPIBaseURL(from baseURLString: String) throws -> URL {
        guard var components = URLComponents(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let url = components.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty
        else {
            throw OnlineAPIError.invalidConfiguration("请输入有效的接口地址")
        }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/api/v1"
        } else {
            while components.path.hasSuffix("/") && components.path.count > 1 {
                components.path.removeLast()
            }
        }
        components.query = nil
        components.fragment = nil
        guard let resolved = components.url else {
            throw OnlineAPIError.invalidConfiguration("请输入有效的接口地址")
        }
        return resolved
    }

    private static func isQwenModel(_ model: String) -> Bool {
        model.lowercased().contains("qwen")
    }

    private static func hotwordsFingerprint(apiBase: URL, model: String, hotwords: [String]) -> String {
        let joined = ([apiBase.absoluteString, model] + hotwords).joined(separator: "\0")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func authHeaders(apiKey: String, contentType: String?) -> [String: String] {
        var headers: [String: String] = [:]
        if !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        if let contentType {
            headers["Content-Type"] = contentType
        }
        return headers
    }

    private func parseJSONObject(from data: Data, context: String) throws -> [String: Any] {
        guard !data.isEmpty else {
            throw OnlineAPIError.emptyResponse
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OnlineAPIError.invalidResponse("\(context)不是有效的 JSON 对象")
        }
        return json
    }

    private static func numericValue(in dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let raw = dict[key] else { continue }
            if let number = raw as? NSNumber,
               CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() {
                return number.doubleValue
            }
            if let string = raw as? String, let parsed = Double(string) {
                return parsed
            }
        }
        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let str = value as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let num = value as? NSNumber {
            if CFGetTypeID(num as CFTypeRef) == CFBooleanGetTypeID() {
                return num.boolValue ? "true" : "false"
            }
            return num.stringValue
        }
        return nil
    }
}
