import AVFoundation
import Foundation
import Testing
@testable import FaymeeCore

@Suite struct ProbeAudioTests {
    @Test func 生成合法的16kHz单声道16位PCM探测WAV且不静音() throws {
        let data = ProbeAudio.wavData()

        // 44 字节标准 WAV 头 + 16000 样本 * 2 字节 = 32044 字节
        #expect(data.count == 32_044)
        #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
    }

    @Test func 临时WAV可被AVAudioFile解码并在正常或抛错退出时清理() async throws {
        var capturedURL: URL?
        let duration = try await ProbeAudio.withTemporaryWAV { url in
            capturedURL = url
            #expect(url.pathExtension == "wav")
            #expect(FileManager.default.fileExists(atPath: url.path))

            let file = try AVAudioFile(forReading: url)
            #expect(file.processingFormat.sampleRate == 16_000)
            #expect(file.processingFormat.channelCount == 1)
            #expect(file.length == 16_000)

            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let channel = try #require(buffer.floatChannelData?[0])
            let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(channel[$1])) }
            #expect(peak > 0.05)

            return Double(file.length) / file.processingFormat.sampleRate
        }
        #expect(duration == 1.0)
        #expect(!FileManager.default.fileExists(atPath: try #require(capturedURL).path))

        struct ProbeFailure: Error {}
        var failingURL: URL?
        await #expect(throws: ProbeFailure.self) {
            try await ProbeAudio.withTemporaryWAV { url in
                failingURL = url
                #expect(FileManager.default.fileExists(atPath: url.path))
                throw ProbeFailure()
            }
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(failingURL).path))
    }
}

@Suite struct HTTPResponseAndErrorTests {
    @Test func 二百段状态码校验通过() throws {
        for status in [200, 201, 204] {
            let response = HTTPResponse(status: status, headers: ["Content-Type": "application/json"], data: Data("{}".utf8))
            try response.checkSuccess()
            #expect(response.headerValue(for: "content-type") == "application/json")
        }
    }

    @Test func 非二百段状态码映射为对应OnlineAPIError并提取可读中文原因() {
        let unauthorized = HTTPResponse(
            status: 401,
            data: Data(#"{"error":{"message":"Incorrect API key provided"}}"#.utf8)
        )
        #expect(throws: OnlineAPIError.unauthorized(401, "Incorrect API key provided")) {
            try unauthorized.checkSuccess()
        }

        let forbidden = HTTPResponse(
            status: 403,
            data: Data(#"{"message":"Access denied"}"#.utf8)
        )
        #expect(throws: OnlineAPIError.unauthorized(403, "Access denied")) {
            try forbidden.checkSuccess()
        }

        let notFound = HTTPResponse(
            status: 404,
            data: Data(#"{"error":{"message":"Model not found"}}"#.utf8)
        )
        #expect(throws: OnlineAPIError.notFound("Model not found")) {
            try notFound.checkSuccess()
        }

        let rateLimited = HTTPResponse(
            status: 429,
            data: Data(#"{"error":{"message":"Rate limit reached"}}"#.utf8)
        )
        #expect(throws: OnlineAPIError.rateLimited("Rate limit reached")) {
            try rateLimited.checkSuccess()
        }

        let serverErr = HTTPResponse(status: 503, data: Data("Service Unavailable".utf8))
        #expect(throws: OnlineAPIError.serverError(503, "Service Unavailable")) {
            try serverErr.checkSuccess()
        }

        let badReq = HTTPResponse(
            status: 400,
            data: Data(#"{"detail":"Unsupported parameter"}"#.utf8)
        )
        #expect(throws: OnlineAPIError.badRequest(400, "Unsupported parameter")) {
            try badReq.checkSuccess()
        }

        // 所有错误都有非空中文描述
        let allErrors: [OnlineAPIError] = [
            .invalidConfiguration("配置缺少密钥"),
            .networkUnavailable("离线"),
            .timedOut,
            .tlsFailed,
            .unauthorized(401, "无效密钥"),
            .notFound(nil),
            .rateLimited(nil),
            .serverError(500, nil),
            .badRequest(400, nil),
            .emptyResponse,
            .invalidResponse("JSON 损坏"),
            .remoteTaskFailed("识别失败"),
        ]
        for err in allErrors {
            #expect(err.errorDescription?.isEmpty == false)
        }
    }
}

@Suite struct MultipartEncodingTests {
    @Test func 按顺序编码文本_内存数据与文件部分() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaymeeMultipart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("probe.wav")
        let audioBytes = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0xFF, 0x7F])
        try audioBytes.write(to: fileURL)

        let parts: [MultipartPart] = [
            .text(name: "model", value: "gpt-transcribe"),
            .data(name: "meta", fileName: "meta.json", mimeType: "application/json", data: Data(#"{"a":1}"#.utf8)),
            .file(name: "file", fileURL: fileURL, fileName: "probe.wav", mimeType: "audio/wav"),
        ]

        let encoded = try encodeMultipart(parts, boundary: "test-boundary-123")

        var expected = Data()
        expected.append(Data("--test-boundary-123\r\n".utf8))
        expected.append(Data("Content-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n".utf8))
        expected.append(Data("--test-boundary-123\r\n".utf8))
        expected.append(Data("Content-Disposition: form-data; name=\"meta\"; filename=\"meta.json\"\r\n".utf8))
        expected.append(Data("Content-Type: application/json\r\n\r\n".utf8))
        expected.append(Data(#"{"a":1}"#.utf8))
        expected.append(Data("\r\n".utf8))
        expected.append(Data("--test-boundary-123\r\n".utf8))
        expected.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"probe.wav\"\r\n".utf8))
        expected.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        expected.append(audioBytes)
        expected.append(Data("\r\n--test-boundary-123--\r\n".utf8))

        #expect(encoded == expected)
    }

    @Test func 文件不存在时编码multipart抛出错误() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).wav")
        #expect(throws: (any Error).self) {
            try encodeMultipart([.file(name: "file", fileURL: missing, fileName: "missing.wav", mimeType: "audio/wav")],
                                boundary: "b")
        }
    }
}

@Suite struct FakeHTTPTransportTests {
    @Test func 队列按顺序回应并记录请求头与multipart快照() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaymeeFakeTransport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tempFile = dir.appendingPathComponent("clip.wav")
        try Data("audio-bytes".utf8).write(to: tempFile)

        let fake = FakeHTTPTransport()
        try fake.enqueue(json: ["ok": true], status: 200)
        fake.enqueue(HTTPResponse.text("accepted", status: 202))

        let r1 = try await fake.send(HTTPRequest(
            method: "POST",
            url: URL(string: "https://api.example.com/v1/audio")!,
            headers: ["Authorization": "Bearer secret"],
            body: .multipart([
                .text(name: "model", value: "gpt-transcribe"),
                .file(name: "file", fileURL: tempFile, fileName: "clip.wav", mimeType: "audio/wav"),
            ])
        ))
        // 模拟调用方在请求结束后删除临时分段文件
        try FileManager.default.removeItem(at: tempFile)

        let r2 = try await fake.send(HTTPRequest(
            method: "GET",
            url: URL(string: "https://api.example.com/v1/status")!
        ))

        #expect(r1.status == 200)
        #expect(r2.status == 202)
        #expect(fake.recordedRequests.count == 2)

        let first = fake.recordedRequests[0]
        #expect(first.header("authorization") == "Bearer secret")
        #expect(first.multipartPartNames() == ["model", "file"])
        #expect(first.multipartText(named: "model") == "gpt-transcribe")
        let uploaded = try #require(first.multipartFile(named: "file"))
        #expect(uploaded.fileName == "clip.wav")
        #expect(uploaded.mimeType == "audio/wav")
        #expect(uploaded.data == Data("audio-bytes".utf8))
        #expect(first.encodedBody != nil)
    }

    @Test func 队列耗尽后再发请求会抛出明确错误() async {
        let fake = FakeHTTPTransport(queue: [])
        await #expect(throws: OnlineAPIError.self) {
            _ = try await fake.send(HTTPRequest(url: URL(string: "https://api.example.com/v1/ping")!))
        }
    }

    @Test func 任务取消时记录被取消的请求并抛出CancellationError() async throws {
        let started = AsyncStream<Void>.makeStream()
        let fake = FakeHTTPTransport { _ in
            started.continuation.yield()
            try await Task.sleep(for: .seconds(10))
            return HTTPResponse(status: 200)
        }

        let targetURL = URL(string: "https://api.example.com/v1/slow")!
        let task = Task {
            try await fake.send(HTTPRequest(method: "POST", url: targetURL))
        }

        for await _ in started.stream { break }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(fake.cancelledRequests.count == 1)
        #expect(fake.cancelledRequests.first?.url == targetURL)
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) async throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func register(host: String, handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
    }

    static func unregister(host: String) {
        _ = lock.withLock { handlers.removeValue(forKey: host) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var loadingTask: Task<Void, Never>?

    override func startLoading() {
        let req = request
        let host = req.url?.host ?? ""
        let handler = Self.lock.withLock { Self.handlers[host] }
        let bodyData = Self.readBody(from: req)

        loadingTask = Task {
            guard let handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
                return
            }
            do {
                let (response, data) = try await handler(req, bodyData)
                try Task.checkCancellation()
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch is CancellationError {
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
        loadingTask = nil
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }
}

@Suite(.serialized)
struct URLSessionHTTPTransportTests {
    private func makeTransport() -> URLSessionHTTPTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSessionHTTPTransport(configuration: config)
    }

    @Test func 发送JSON与Multipart请求并返回含400和500在内的原始HTTP状态码() async throws {
        let host = "mock-\(UUID().uuidString).local"
        defer { StubURLProtocol.unregister(host: host) }

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            var captured: [(method: String?, contentType: String?, auth: String?, body: Data?)] = []
            func append(_ item: (method: String?, contentType: String?, auth: String?, body: Data?)) {
                lock.withLock { captured.append(item) }
            }
            func all() -> [(method: String?, contentType: String?, auth: String?, body: Data?)] {
                lock.withLock { captured }
            }
        }
        let box = Box()

        StubURLProtocol.register(host: host) { req, body in
            box.append((req.httpMethod, req.value(forHTTPHeaderField: "Content-Type"),
                        req.value(forHTTPHeaderField: "Authorization"), body))
            let status = req.url?.path == "/error400" ? 400 : 200
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["X-Request-Id": "req-1"])!
            return (resp, Data(#"{"status":\#(status)}"#.utf8))
        }

        let transport = makeTransport()

        // 1) JSON POST 返回 400 不抛错，保留响应体给适配器做降级判断
        let jsonResp = try await transport.send(HTTPRequest(
            method: "POST",
            url: URL(string: "https://\(host)/error400")!,
            headers: ["Authorization": "Bearer k1", "Content-Type": "application/json"],
            body: .data(Data(#"{"hello":"world"}"#.utf8))
        ))
        #expect(jsonResp.status == 400)
        #expect(jsonResp.headerValue(for: "x-request-id") == "req-1")

        // 2) Multipart 文件上传
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaymeeURLSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("audio.wav")
        try Data("RIFF-MOCK".utf8).write(to: fileURL)

        let mpResp = try await transport.send(HTTPRequest(
            method: "POST",
            url: URL(string: "https://\(host)/upload")!,
            headers: ["Authorization": "Bearer k2"],
            body: .multipart([
                .text(name: "model", value: "gpt-transcribe"),
                .file(name: "file", fileURL: fileURL, fileName: "audio.wav", mimeType: "audio/wav"),
            ])
        ))
        #expect(mpResp.status == 200)

        let calls = box.all()
        #expect(calls.count == 2)
        #expect(calls[0].method == "POST")
        #expect(calls[0].auth == "Bearer k1")
        #expect(calls[0].body == Data(#"{"hello":"world"}"#.utf8))

        #expect(calls[1].contentType?.hasPrefix("multipart/form-data; boundary=") == true)
        let mpBodyString = String(data: try #require(calls[1].body), encoding: .utf8)
        #expect(mpBodyString?.contains("name=\"model\"\r\n\r\ngpt-transcribe\r\n") == true)
        #expect(mpBodyString?.contains("filename=\"audio.wav\"") == true)
        #expect(mpBodyString?.contains("RIFF-MOCK") == true)
    }

    @Test func 底层网络超时_断网与TLS错误映射为对应OnlineAPIError() async {
        let host = "err-\(UUID().uuidString).local"
        defer { StubURLProtocol.unregister(host: host) }
        let transport = makeTransport()

        let cases: [(URLError.Code, OnlineAPIError)] = [
            (.timedOut, .timedOut),
            (.secureConnectionFailed, .tlsFailed),
            (.serverCertificateUntrusted, .tlsFailed),
            (.notConnectedToInternet, .networkUnavailable(URLError(.notConnectedToInternet).localizedDescription)),
        ]

        for (code, expected) in cases {
            StubURLProtocol.register(host: host) { _, _ in
                throw URLError(code)
            }
            await #expect(throws: expected) {
                _ = try await transport.send(HTTPRequest(url: URL(string: "https://\(host)/ping")!))
            }
        }
    }

    @Test func 任务取消时转为CancellationError() async {
        let host = "cancel-\(UUID().uuidString).local"
        defer { StubURLProtocol.unregister(host: host) }
        let started = AsyncStream<Void>.makeStream()

        StubURLProtocol.register(host: host) { _, _ in
            started.continuation.yield()
            try await Task.sleep(for: .seconds(10))
            return (HTTPURLResponse(), Data())
        }

        let transport = makeTransport()
        let task = Task {
            try await transport.send(HTTPRequest(url: URL(string: "https://\(host)/slow")!))
        }
        for await _ in started.stream { break }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}
