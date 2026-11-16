import Foundation

/// 在线模型调用、配置校验及传输层的统一错误
public enum OnlineAPIError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case networkUnavailable(String?)
    case timedOut
    case tlsFailed
    case unauthorized(Int, String?)
    case notFound(String?)
    case rateLimited(String?)
    case serverError(Int, String?)
    case badRequest(Int, String?)
    case emptyResponse
    case invalidResponse(String)
    case remoteTaskFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(reason):
            reason.isEmpty ? "在线模型配置不完整" : reason
        case let .networkUnavailable(detail):
            Self.format("网络连接失败", detail: detail, fallback: "请检查网络或接口地址")
        case .timedOut:
            "请求超时，请检查网络连接或稍后重试"
        case .tlsFailed:
            "安全连接（TLS/SSL）建立失败，请检查接口证书或地址是否正确"
        case let .unauthorized(status, detail):
            Self.format("接口鉴权失败（HTTP \(status)）", detail: detail, fallback: "请检查 API Key 是否正确")
        case let .notFound(detail):
            Self.format("接口或模型不存在（HTTP 404）", detail: detail, fallback: "请检查接口地址和模型标识")
        case let .rateLimited(detail):
            Self.format("请求过于频繁或额度已用尽（HTTP 429）", detail: detail, fallback: "请稍后重试")
        case let .serverError(status, detail):
            Self.format("服务端异常（HTTP \(status)）", detail: detail, fallback: "请稍后重试")
        case let .badRequest(status, detail):
            Self.format("请求参数错误（HTTP \(status)）", detail: detail, fallback: nil)
        case .emptyResponse:
            "服务端返回了空响应"
        case let .invalidResponse(detail):
            "服务端响应格式异常：\(detail)"
        case let .remoteTaskFailed(detail):
            "云端任务执行失败：\(detail)"
        }
    }

    private static func format(_ prefix: String, detail: String?, fallback: String?) -> String {
        if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(prefix)：\(detail)"
        }
        if let fallback {
            return "\(prefix)，\(fallback)"
        }
        return prefix
    }

    /// 从服务端返回的 HTTP 响应体（JSON 或纯文本）中提取简短可读错误信息
    public static func extractServerMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let extracted = extractServerMessage(from: json) {
            return extracted
        }
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           !text.lowercased().hasPrefix("<!doctype html"),
           !text.lowercased().hasPrefix("<html")
        {
            return String(text.prefix(240))
        }
        return nil
    }

    static func extractServerMessage(from json: [String: Any]) -> String? {
        let nestedError = json["error"] as? [String: Any]
        let candidates: [String?] = [
            nestedError?["message"] as? String,
            json["error"] as? String,
            json["message"] as? String,
            json["detail"] as? String,
            json["msg"] as? String,
            nestedError?["code"] as? String,
            json["code"] as? String,
        ]
        for candidate in candidates {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return String(trimmed.prefix(240))
            }
        }
        return nil
    }

    /// 判断 HTTP 400 响应是否明确且仅表示模型不存在（此时剥离可选参数重试毫无意义）
    static func isModelNotFoundError(data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let rawText = String(data: data, encoding: .utf8) ?? ""
        let loweredRaw = rawText.lowercased()

        let parameterMarkers = [
            "response_format", "json_object", "corpus", "vocabulary",
            "context", "not support", "unsupported parameter",
        ]
        if parameterMarkers.contains(where: { loweredRaw.contains($0) }) {
            return false
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let nestedError = json["error"] as? [String: Any]
            let code = ((nestedError?["code"] as? String) ?? (json["code"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if ["model_not_found", "modelnotfound", "model.notfound", "model_not_exist", "modelnotexist"].contains(code) {
                return true
            }
            if let param = (nestedError?["param"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !param.isEmpty, param != "model" {
                return false
            }
        }

        let message = (extractServerMessage(from: data) ?? rawText).lowercased()
        let missingModelPhrases = [
            "model_not_found",
            "modelnotfound",
            "model not found",
            "model not exist",
            "model does not exist",
            "no such model",
            "unknown model",
            "模型不存在",
        ]
        if missingModelPhrases.contains(where: { message.contains($0) }) {
            return true
        }
        return message.contains("model") && (message.contains("does not exist") || message.contains("not found"))
    }
}

/// multipart/form-data 请求体中的单个字段
public enum MultipartPart: Equatable, Hashable, Sendable {
    case text(name: String, value: String)
    case data(name: String, fileName: String, mimeType: String, data: Data)
    case file(name: String, fileURL: URL, fileName: String, mimeType: String)
}

/// 发送给 `HTTPTransport` 的结构化 HTTP 请求
public struct HTTPRequest: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case data(Data)
        case multipart([MultipartPart])
    }

    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Body?
    public var timeout: TimeInterval

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Body? = nil,
                timeout: TimeInterval = 180) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// 全适配器共用的薄 HTTP 传输协议；对任意已收到的 HTTP 状态码均返回 `HTTPResponse` 而不抛错
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// 基于系统 `URLSession` 的正式 HTTP 传输实现
public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration? = nil) {
        let resolved: URLSessionConfiguration
        if let configuration {
            resolved = configuration
        } else {
            let ephemeral = URLSessionConfiguration.ephemeral
            ephemeral.timeoutIntervalForRequest = 600
            ephemeral.timeoutIntervalForResource = 1800
            ephemeral.requestCachePolicy = .reloadIgnoringLocalCacheData
            resolved = ephemeral
        }
        self.session = URLSession(configuration: resolved)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let (data, urlResponse) = try await perform(request: &urlRequest, body: request.body)

        guard let http = urlResponse as? HTTPURLResponse else {
            throw OnlineAPIError.invalidResponse("未收到有效的 HTTP 响应")
        }
        var responseHeaders: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            responseHeaders[String(describing: key)] = String(describing: value)
        }
        return HTTPResponse(status: http.statusCode, headers: responseHeaders, data: data)
    }

    private func perform(request urlRequest: inout URLRequest, body: HTTPRequest.Body?) async throws -> (Data, URLResponse) {
        switch body {
        case nil:
            return try await mapErrors { try await session.data(for: urlRequest) }
        case let .data(bodyData):
            urlRequest.httpBody = bodyData
            return try await mapErrors { try await session.data(for: urlRequest) }
        case let .multipart(parts):
            let boundary = "FaymeeBoundary-\(UUID().uuidString)"
            urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let tempBodyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("faymee-http-\(UUID().uuidString).body")
            FileManager.default.createFile(atPath: tempBodyURL.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: tempBodyURL) }

            let handle = try FileHandle(forWritingTo: tempBodyURL)
            do {
                try writeMultipart(parts, boundary: boundary) { chunk in
                    try handle.write(contentsOf: chunk)
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            let uploadRequest = urlRequest
            return try await mapErrors { try await session.upload(for: uploadRequest, fromFile: tempBodyURL) }
        }
    }

    private func mapErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    private static func mapTransportError(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled {
            return CancellationError()
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return CancellationError()
            case .timedOut:
                return OnlineAPIError.timedOut
            case .secureConnectionFailed,
                 .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .clientCertificateRejected,
                 .clientCertificateRequired,
                 .appTransportSecurityRequiresSecureConnection:
                return OnlineAPIError.tlsFailed
            default:
                return OnlineAPIError.networkUnavailable(urlError.localizedDescription)
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return CancellationError()
        }
        return OnlineAPIError.networkUnavailable(error.localizedDescription)
    }
}

/// 将 multipart 各部分按给定 boundary 编码为 RFC 7578 字节流
public func encodeMultipart(_ parts: [MultipartPart], boundary: String) throws -> Data {
    var result = Data()
    try writeMultipart(parts, boundary: boundary) { chunk in
        result.append(chunk)
    }
    return result
}

func writeMultipart(_ parts: [MultipartPart], boundary: String, write: (Data) throws -> Void) throws {
    let cleanBoundary = sanitizeHeaderValue(boundary)
    for part in parts {
        try Task.checkCancellation()
        try write(Data("--\(cleanBoundary)\r\n".utf8))
        switch part {
        case let .text(name, value):
            try write(Data("Content-Disposition: form-data; name=\"\(sanitizeQuotedParam(name))\"\r\n\r\n".utf8))
            try write(Data(value.utf8))
            try write(Data("\r\n".utf8))
        case let .data(name, fileName, mimeType, data):
            try write(Data(filePartHeader(name: name, fileName: fileName, mimeType: mimeType).utf8))
            try write(data)
            try write(Data("\r\n".utf8))
        case let .file(name, fileURL, fileName, mimeType):
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try write(Data(filePartHeader(name: name, fileName: fileName, mimeType: mimeType).utf8))
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                try write(chunk)
            }
            try write(Data("\r\n".utf8))
        }
    }
    try write(Data("--\(cleanBoundary)--\r\n".utf8))
}

private func filePartHeader(name: String, fileName: String, mimeType: String) -> String {
    "Content-Disposition: form-data; name=\"\(sanitizeQuotedParam(name))\"; filename=\"\(sanitizeQuotedParam(fileName))\"\r\n"
        + "Content-Type: \(sanitizeHeaderValue(mimeType))\r\n\r\n"
}

private func sanitizeQuotedParam(_ value: String) -> String {
    sanitizeHeaderValue(value).replacingOccurrences(of: "\"", with: "\\\"")
}

private func sanitizeHeaderValue(_ value: String) -> String {
    value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
}

/// 收到完整 HTTP 响应后的结构化结果；任何 HTTP 状态码（含 4xx/5xx）均先返回由调用方决定如何处理
public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var data: Data

    public init(status: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.status = status
        self.headers = headers
        self.data = data
    }

    /// 按不区分大小写的名字读取响应头
    public func headerValue(for name: String) -> String? {
        let lowercased = name.lowercased()
        return headers.first { $0.key.lowercased() == lowercased }?.value
    }

    /// 校验状态码属于 2xx，否则提取响应体中的可读错误并抛出对应的 `OnlineAPIError`
    public func checkSuccess() throws {
        if (200..<300).contains(status) { return }
        let message = OnlineAPIError.extractServerMessage(from: data)
        switch status {
        case 401, 403:
            throw OnlineAPIError.unauthorized(status, message)
        case 404:
            throw OnlineAPIError.notFound(message)
        case 429:
            throw OnlineAPIError.rateLimited(message)
        case 400..<500:
            throw OnlineAPIError.badRequest(status, message)
        case 500..<600:
            throw OnlineAPIError.serverError(status, message)
        default:
            throw OnlineAPIError.invalidResponse("收到意外的 HTTP 状态码 \(status)")
        }
    }
}
