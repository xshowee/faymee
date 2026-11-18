import Foundation
@testable import FaymeeCore

extension HTTPResponse {
    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) throws -> HTTPResponse {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var merged = headers
        if !merged.keys.contains(where: { $0.lowercased() == "content-type" }) {
            merged["Content-Type"] = "application/json"
        }
        return HTTPResponse(status: status, headers: merged, data: data)
    }

    static func text(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, data: Data(text.utf8))
    }
}

/// 供在线模型适配器与连接测试共用的可脚本化假 HTTP 传输
final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse

    struct RecordedRequest: Sendable {
        enum SnapshottedPart: Sendable {
            case text(name: String, value: String)
            case file(name: String, fileName: String, mimeType: String, data: Data)

            var name: String {
                switch self {
                case let .text(name, _): name
                case let .file(name, _, _, _): name
                }
            }
        }

        let request: HTTPRequest
        let multipartParts: [MultipartPart]
        let encodedBody: Data?
        private let snapshottedParts: [SnapshottedPart]

        init(request: HTTPRequest, boundary: String = "fake-boundary") {
            self.request = request
            switch request.body {
            case nil:
                self.multipartParts = []
                self.encodedBody = nil
                self.snapshottedParts = []
            case let .data(data):
                self.multipartParts = []
                self.encodedBody = data
                self.snapshottedParts = []
            case let .multipart(parts):
                self.multipartParts = parts
                let snapshots: [SnapshottedPart] = parts.map { part in
                    switch part {
                    case let .text(name, value):
                        .text(name: name, value: value)
                    case let .data(name, fileName, mimeType, data):
                        .file(name: name, fileName: fileName, mimeType: mimeType, data: data)
                    case let .file(name, fileURL, fileName, mimeType):
                        .file(name: name, fileName: fileName, mimeType: mimeType,
                              data: (try? Data(contentsOf: fileURL)) ?? Data())
                    }
                }
                self.snapshottedParts = snapshots
                let inMemoryParts: [MultipartPart] = snapshots.map { snapshot in
                    switch snapshot {
                    case let .text(name, value):
                        .text(name: name, value: value)
                    case let .file(name, fileName, mimeType, data):
                        .data(name: name, fileName: fileName, mimeType: mimeType, data: data)
                    }
                }
                self.encodedBody = try? encodeMultipart(inMemoryParts, boundary: boundary)
            }
        }

        func header(_ name: String) -> String? {
            let lowercased = name.lowercased()
            return request.headers.first { $0.key.lowercased() == lowercased }?.value
        }

        func bodyText() -> String? {
            encodedBody.flatMap { String(data: $0, encoding: .utf8) }
        }

        func bodyJSONObject() -> [String: Any]? {
            guard let encodedBody else { return nil }
            return try? JSONSerialization.jsonObject(with: encodedBody) as? [String: Any]
        }

        func multipartPartNames() -> [String] {
            snapshottedParts.map(\.name)
        }

        func multipartText(named name: String) -> String? {
            for part in snapshottedParts {
                if case let .text(partName, value) = part, partName == name {
                    return value
                }
            }
            return nil
        }

        func multipartFile(named name: String) -> (fileName: String, mimeType: String, data: Data)? {
            for part in snapshottedParts {
                if case let .file(partName, fileName, mimeType, data) = part, partName == name {
                    return (fileName, mimeType, data)
                }
            }
            return nil
        }
    }

    private enum Mode {
        case scripted(Handler)
        case queued([Handler])
    }

    private let lock = NSLock()
    private var mode: Mode
    private var _recordedRequests: [RecordedRequest] = []
    private var _cancelledRequests: [HTTPRequest] = []
    private var cancelledRequestIDs = Set<UUID>()

    init() {
        self.mode = .queued([])
    }

    init(queue: [Handler]) {
        self.mode = .queued(queue)
    }

    init(responses: [HTTPResponse]) {
        self.mode = .queued(responses.map { response in { _ in response } })
    }

    init(handler: @escaping Handler) {
        self.mode = .scripted(handler)
    }

    var requests: [HTTPRequest] {
        lock.withLock { _recordedRequests.map(\.request) }
    }

    var recordedRequests: [RecordedRequest] {
        lock.withLock { _recordedRequests }
    }

    var cancelledRequests: [HTTPRequest] {
        lock.withLock { _cancelledRequests }
    }

    func enqueue(_ handler: @escaping Handler) {
        lock.withLock {
            switch mode {
            case var .queued(queue):
                queue.append(handler)
                mode = .queued(queue)
            case .scripted:
                mode = .queued([handler])
            }
        }
    }

    func enqueue(_ response: HTTPResponse) {
        enqueue { _ in response }
    }

    func enqueue(json object: Any, status: Int = 200, headers: [String: String] = [:]) throws {
        let response = try HTTPResponse.json(object, status: status, headers: headers)
        enqueue(response)
    }

    func enqueue(text: String, status: Int = 200, headers: [String: String] = [:]) {
        enqueue(HTTPResponse.text(text, status: status, headers: headers))
    }

    func enqueue(error: any Error) {
        enqueue { _ in throw error }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let requestID = UUID()
        let snapshot = RecordedRequest(request: request)
        let nextHandler: Handler? = lock.withLock {
            _recordedRequests.append(snapshot)
            switch mode {
            case let .scripted(handler):
                return handler
            case var .queued(queue):
                guard !queue.isEmpty else { return nil }
                let first = queue.removeFirst()
                mode = .queued(queue)
                return first
            }
        }

        if Task.isCancelled {
            recordCancellation(id: requestID, request: request)
            throw CancellationError()
        }

        guard let nextHandler else {
            throw OnlineAPIError.invalidResponse("FakeHTTPTransport 队列已空，收到意外请求：\(request.method) \(request.url)")
        }

        return try await withTaskCancellationHandler {
            do {
                let response = try await nextHandler(request)
                if Task.isCancelled {
                    recordCancellation(id: requestID, request: request)
                    throw CancellationError()
                }
                return response
            } catch is CancellationError {
                recordCancellation(id: requestID, request: request)
                throw CancellationError()
            }
        } onCancel: {
            recordCancellation(id: requestID, request: request)
        }
    }

    private func recordCancellation(id: UUID, request: HTTPRequest) {
        lock.withLock {
            if cancelledRequestIDs.insert(id).inserted {
                _cancelledRequests.append(request)
            }
        }
    }
}

/// 包一层真实的 HTTP 传输，记下每次在线请求的响应和耗时（在线契约测试、纠错评估用）
final class RecordingHTTPTransport: HTTPTransport, @unchecked Sendable {
    struct Exchange {
        let response: HTTPResponse
        let seconds: TimeInterval

        /// 响应体的 JSON 对象；不是 JSON 时为 nil
        var json: [String: Any]? { try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] }
    }

    private let base = URLSessionHTTPTransport()
    private let lock = NSLock()
    private var recorded: [Exchange] = []

    var exchanges: [Exchange] { lock.withLock { recorded } }

    func removeAll() { lock.withLock { recorded.removeAll() } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let started = Date()
        let response = try await base.send(request)
        let exchange = Exchange(response: response, seconds: Date().timeIntervalSince(started))
        lock.withLock { recorded.append(exchange) }
        return response
    }
}
