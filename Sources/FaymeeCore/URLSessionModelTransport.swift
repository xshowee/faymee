import Foundation

/// `ModelTransport` 的真实实现。用 data delegate 按块收数据（`URLSession.bytes` 按字节迭代，2.5GB 太慢）。
/// 每次请求都从原始 URL 开始、跟随跳转，跳转时把 `Range` 头带过去；跳转后的签名地址不缓存
public final class URLSessionModelTransport: NSObject, ModelTransport, @unchecked Sendable {
    private struct Pending {
        var response: CheckedContinuation<ModelResponse, Error>?
        let body: AsyncThrowingStream<Data, Error>.Continuation
        let stream: AsyncThrowingStream<Data, Error>
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    public override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        // 一分钟收不到数据算断线；整个文件下多久都行
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    public func get(_ url: URL, from offset: Int64) async throws -> ModelResponse {
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        // 不要压缩：Content-Length、Content-Range 要对应文件本身的字节
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        let (stream, body) = AsyncThrowingStream<Data, Error>.makeStream()
        // 读的那个任务被取消（暂停）时断开连接。读的一方不再读、但没被取消时（大小不对、写盘失败）
        // 不会走到这里，靠 ModelResponse.cancel
        body.onTermination = { _ in task.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    pending[task.taskIdentifier] = Pending(response: continuation, body: body, stream: stream)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

extension URLSessionModelTransport: URLSessionDataDelegate {
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var request = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(request)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let continuation = lock.withLock { () -> (CheckedContinuation<ModelResponse, Error>, AsyncThrowingStream<Data, Error>)? in
            guard let p = pending[dataTask.taskIdentifier], let c = p.response else { return nil }
            pending[dataTask.taskIdentifier]?.response = nil
            return (c, p.stream)
        }
        completionHandler(.allow)
        guard let (continuation, stream) = continuation else { return }
        let length = response.expectedContentLength
        continuation.resume(returning: ModelResponse(
            status: http?.statusCode ?? 0,
            contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
            contentLength: length >= 0 ? length : nil,
            body: stream,
            cancel: { dataTask.cancel() }))
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let body = lock.withLock { pending[dataTask.taskIdentifier]?.body }
        body?.yield(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let p = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        // 还没收到响应头就失败了（连不上、超时）
        p.response?.resume(throwing: error ?? URLError(.badServerResponse))
        p.body.finish(throwing: error)
    }
}
