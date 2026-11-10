import CryptoKit
import Foundation
import Observation

/// 一次 GET 的响应头和响应体
public struct ModelResponse: Sendable {
    public var status: Int
    /// `Content-Range` 头，206 时形如 `bytes 100-2497280255/2497280256`
    public var contentRange: String?
    /// 本次响应体的字节数（`Content-Length`），不知道时为 nil
    public var contentLength: Int64?
    /// 响应体，按收到的先后分块给出；连接中断时抛错
    public var body: AsyncThrowingStream<Data, Error>
    /// 断开连接。下载器用完（或不用）这个响应后一定会调用：否则看了响应头就不要的响应
    /// （大小不对、写盘失败）还会在后台接着收，把剩下的内容攒在内存里
    public var cancel: @Sendable () -> Void

    public init(status: Int, contentRange: String?, contentLength: Int64?, body: AsyncThrowingStream<Data, Error>,
                cancel: @escaping @Sendable () -> Void = {}) {
        self.status = status
        self.contentRange = contentRange
        self.contentLength = contentLength
        self.body = body
        self.cancel = cancel
    }
}

/// 下载器用的网络。测试注入假网络；App 用 `URLSessionModelTransport`
public protocol ModelTransport: Sendable {
    /// 请求 `url`；`offset > 0` 时带 `Range: bytes=offset-`。每次都从原始 URL 请求、跟随跳转：
    /// 跳转后的 CDN 地址带签名，会过期，不能缓存下来续传
    func get(_ url: URL, from offset: Int64) async throws -> ModelResponse
}

/// 下载器的状态
public enum ModelDownloadPhase: Hashable, Sendable {
    case notDownloaded
    /// 下了一部分，没在下（用户暂停，或上次退出 App 时没下完）
    case paused
    case downloading
    /// 下完了，正在算 SHA-256（2.5GB 约 6 秒）
    case verifying
    case ready
    /// 失败原因；已下的部分还在时重试会续传
    case failed(String)
}

/// 本机纪要模型的下载器：按 `LocalModel.downloadURLs` 的顺序下载，写到同目录的 `.partial` 文件，
/// SHA-256 校验通过后才改名到 `LocalModel.url(in:)`（`isDownloaded` 只看大小，所以必须先校验）。
/// 只在用户点了“下载”时开始，不会自己开始，启动时也不自动续传
@MainActor @Observable
public final class ModelDownloader {
    public let model: LocalModel
    /// 模型目录。没有默认值：只有 App 传约定目录，测试一律用临时目录
    public let directory: URL
    public private(set) var phase: ModelDownloadPhase = .notDownloaded
    /// 已下载到本地的字节数（含之前中断留下的）
    public private(set) var receivedBytes: Int64 = 0
    /// 模型变得可用（下载完成）或不再可用（删除）时调用。App 在这里调 `MinutesPipeline.modelAvailabilityChanged()`
    @ObservationIgnored public var onAvailabilityChange: (() -> Void)?

    @ObservationIgnored private let transport: any ModelTransport
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 每次开始下载加一，旧任务迟到的进度和结果据此丢弃
    @ObservationIgnored private var generation = 0

    public init(model: LocalModel, directory: URL, transport: any ModelTransport) {
        self.model = model
        self.directory = directory
        self.transport = transport
        refreshFromDisk()
    }

    public var isReady: Bool { phase == .ready }
    public var isRunning: Bool { phase == .downloading || phase == .verifying }
    public var progress: Double { model.size > 0 ? Double(receivedBytes) / Double(model.size) : 0 }

    var partialURL: URL { directory.appendingPathComponent(model.fileName + ".partial") }

    /// 开始或继续下载（也用于“重试”）。已就绪、正在下载时什么都不做
    public func start() {
        guard !isRunning, phase != .ready else { return }
        generation += 1
        let token = generation
        let previous = task
        phase = .downloading
        let job = DownloadJob(model: model, directory: directory, partial: partialURL, transport: transport,
                              progress: { [weak self] event in
            Task { @MainActor in self?.report(event, token: token) }
        })
        task = Task(priority: .utility) {
            // 暂停后马上继续时，等上一次真正停下再写同一个文件
            await previous?.value
            let result = await Result { try await job.run() }
            self.finish(result, token: token)
        }
    }

    /// 暂停：保留已下的部分，之后 `start()` 从断点续传
    public func pause() {
        guard isRunning else { return }
        task?.cancel()
        phase = receivedBytes > 0 ? .paused : .notDownloaded
    }

    /// 取消下载并删掉已下的部分
    public func cancel() async {
        await stop()
        try? FileManager.default.removeItem(at: partialURL)
        refreshFromDisk()
    }

    /// 删除模型（和没下完的部分）。之后状态回到未下载，排队的纪要等待重新下载
    public func delete() async throws {
        await stop()
        let fm = FileManager.default
        try? fm.removeItem(at: partialURL)
        let url = model.url(in: directory)
        var failure: Error?
        if fm.fileExists(atPath: url.path) {
            do { try fm.removeItem(at: url) } catch { failure = error }
        }
        refreshFromDisk()
        onAvailabilityChange?()
        if let failure { throw failure }
    }

    /// 等这次下载结束（完成、失败、暂停），测试用
    public func waitUntilFinished() async {
        await task?.value
    }

    /// 停下正在进行的下载，等它真的不再写文件
    private func stop() async {
        generation += 1
        task?.cancel()
        await task?.value
        task = nil
    }

    private func refreshFromDisk() {
        if model.isDownloaded(in: directory) {
            receivedBytes = model.size
            phase = .ready
        } else {
            receivedBytes = min(fileSize(partialURL), model.size)
            phase = receivedBytes > 0 ? .paused : .notDownloaded
        }
    }

    private func report(_ event: DownloadJob.Event, token: Int) {
        guard token == generation, isRunning else { return }
        switch event {
        case let .received(bytes): receivedBytes = bytes
        case .verifying: phase = .verifying
        }
    }

    private func finish(_ result: Result<Void, Error>, token: Int) {
        guard token == generation else { return }
        task = nil
        switch result {
        case .success:
            refreshFromDisk()
            onAvailabilityChange?()
        case let .failure(error) where error is CancellationError:
            // 暂停
            refreshFromDisk()
        case let .failure(error):
            receivedBytes = min(fileSize(partialURL), model.size)
            phase = .failed(error.localizedDescription)
        }
    }
}

/// 模型状态的文字：设置里的一行（`text`），和详情页纪要“等待下载模型”时的说明（`minutesText`）
public struct ModelDownloadStatus: Hashable, Sendable {
    public var phase: ModelDownloadPhase
    public var receivedBytes: Int64
    public var totalBytes: Int64

    public init(phase: ModelDownloadPhase, receivedBytes: Int64, totalBytes: Int64) {
        self.phase = phase
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }

    public var progress: Double { totalBytes > 0 ? min(Double(receivedBytes) / Double(totalBytes), 1) : 0 }

    public var text: String {
        switch phase {
        case .notDownloaded: "未下载（约 \(gigabytes(totalBytes))）"
        case .downloading: "下载中 \(percent)（\(amount)）"
        case .paused: "已暂停，已下载 \(percent)（\(amount)）"
        case .verifying: "正在校验模型…"
        case .ready: "已就绪，占用 \(gigabytes(totalBytes))"
        case let .failed(reason): "下载失败：\(reason)"
        }
    }

    public var minutesText: String {
        switch phase {
        case .notDownloaded: "生成纪要需要下载约 \(gigabytes(totalBytes)) 的模型"
        case .downloading: "正在下载模型 \(percent)"
        case .paused: "模型下载已暂停（\(percent)）"
        case .verifying: "正在校验模型…"
        case .ready: "模型已就绪"
        case let .failed(reason): "模型下载失败：\(reason)"
        }
    }

    private var percent: String { "\(Int((progress * 100).rounded(.down)))%" }
    private var amount: String { "\(gigabytes(receivedBytes)) / \(gigabytes(totalBytes))" }
}

extension ModelDownloader {
    public var status: ModelDownloadStatus {
        ModelDownloadStatus(phase: phase, receivedBytes: receivedBytes, totalBytes: model.size)
    }
}

/// 按十进制 GB 显示一位小数（和访达一致）
private func gigabytes(_ bytes: Int64) -> String {
    String(format: "%.1f GB", Double(bytes) / 1e9)
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

/// 一次下载：在后台执行，不碰下载器的状态
private struct DownloadJob: Sendable {
    let model: LocalModel
    let directory: URL
    let partial: URL
    let transport: any ModelTransport
    let progress: @Sendable (Event) -> Void

    enum Event: Sendable {
        /// 部分文件现在多大
        case received(Int64)
        case verifying
    }

    func run() async throws {
        // 上一次暂停时恰好下完、改了名
        if model.isDownloaded(in: directory) { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await fetchFromSources()
        try Task.checkCancellation()
        progress(.verifying)
        guard try sha256(of: partial) == model.sha256 else {
            // 不知道坏在哪一段，只能整个重下
            try? FileManager.default.removeItem(at: partial)
            throw ModelDownloadError.checksumMismatch
        }
        try Task.checkCancellation()
        let url = model.url(in: directory)
        // 大小不对的旧文件（不算已下载）。大小对的文件 run 一开始就返回了，不会走到这里
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: partial, to: url)
    }

    /// 按顺序试每个来源，直到部分文件完整。一个来源下到一半断了（这次有进展）就从断点重连它，
    /// 连上也没进展才换下一个，所以不会无限重试。换来源也接着断点下：各来源是同一个文件，最后靠哈希兜底
    private func fetchFromSources() async throws {
        var lastError: Error = ModelDownloadError.noSource
        var index = 0
        while index < model.downloadURLs.count {
            let before = fileSize(partial)
            do {
                try await fetch(model.downloadURLs[index])
                return
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                lastError = error
                let madeProgress = fileSize(partial) > before
                if !madeProgress || error as? ModelDownloadError == .sizeMismatch { index += 1 }
            }
        }
        throw lastError
    }

    /// 从部分文件的末尾续传到完整
    private func fetch(_ url: URL) async throws {
        var offset = fileSize(partial)
        // 比完整文件还长：不知道哪里错了，从头来
        if offset > model.size {
            try? FileManager.default.removeItem(at: partial)
            offset = 0
        }
        if offset == model.size { return }
        let response = try await transport.get(url, from: offset)
        defer { response.cancel() }
        let writeOffset: Int64
        switch response.status {
        case 206:
            guard let range = response.contentRange.flatMap(ContentRange.init), range.start == offset else {
                throw ModelDownloadError.badResponse
            }
            if let total = range.total, total != model.size { throw ModelDownloadError.sizeMismatch }
            writeOffset = offset
        case 200:
            // 服务器不认 Range，从头给了整个文件
            if let length = response.contentLength, length != model.size { throw ModelDownloadError.sizeMismatch }
            writeOffset = 0
        default:
            throw ModelDownloadError.httpStatus(response.status)
        }
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(writeOffset))
        try handle.seekToEnd()
        var written = writeOffset
        progress(.received(written))
        // 进度最多每 0.1 秒报一次：每块只有几十 KB，2.5GB 要报上万次
        let clock = ContinuousClock()
        var lastReport = clock.now - .seconds(1)
        for try await chunk in response.body {
            try Task.checkCancellation()
            written += Int64(chunk.count)
            if written > model.size { throw ModelDownloadError.sizeMismatch }
            try handle.write(contentsOf: chunk)
            if clock.now - lastReport >= .milliseconds(100) {
                lastReport = clock.now
                progress(.received(written))
            }
        }
        progress(.received(written))
        try handle.close()
        if written < model.size { throw ModelDownloadError.incomplete }
    }
}

private func fileSize(_ url: URL) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
}

/// `Content-Range: bytes 100-199/2000`；总长未知时为 `*`
struct ContentRange: Equatable {
    var start: Int64
    var total: Int64?

    init?(_ header: String) {
        let parts = header.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = parts[1].split(separator: "/", maxSplits: 1)
        guard rangeAndTotal.count == 2, let dash = rangeAndTotal[0].firstIndex(of: "-"),
              let start = Int64(rangeAndTotal[0][..<dash].trimmingCharacters(in: .whitespaces))
        else { return nil }
        self.start = start
        total = Int64(rangeAndTotal[1].trimmingCharacters(in: .whitespaces))
    }
}

public enum ModelDownloadError: LocalizedError, Equatable {
    case checksumMismatch
    /// 206 的 Content-Range 对不上请求的偏移，或者缺了
    case badResponse
    case httpStatus(Int)
    /// 来源上的文件大小和预期不同：换了文件，不能用它续传
    case sizeMismatch
    /// 响应正常结束，但没给全
    case incomplete
    case noSource

    public var errorDescription: String? {
        switch self {
        case .checksumMismatch: "下载的文件校验失败，已删除，请重试"
        case .badResponse: "服务器返回的内容不对"
        case let .httpStatus(code): "服务器返回错误（\(code)）"
        case .sizeMismatch: "服务器上的模型文件和预期的不一样"
        case .incomplete: "连接中断，文件没有下完"
        case .noSource: "没有可用的下载地址"
        }
    }
}

/// 文件的 SHA-256，小写 hex。分块读，2.5GB 不会一次读进内存
func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
        try Task.checkCancellation()
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
