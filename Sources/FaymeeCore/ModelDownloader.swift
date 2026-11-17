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

/// 本机模型的下载器：一个主模型加它依赖的辅助模型（如 Paraformer 的标点模型），所有文件逐个下载。
/// 每个文件按 `ModelFile.downloadURLs` 的顺序试，写到同目录的 `<文件>.partial`，SHA-256 校验通过后才改名到位
/// （`LocalModel.isDownloaded` 只看大小，所以必须先校验）。整体进度按所有文件的总字节数计。
/// 只在用户点了“下载”时开始，不会自己开始，启动时也不自动续传
@MainActor @Observable
public final class ModelDownloader {
    public let model: LocalModel
    /// 随主模型一起下载的辅助模型；全部下好才算就绪
    public let dependencies: [LocalModel]
    /// 模型根目录（各模型在其下的 `directoryName` 子目录）。没有默认值：只有 App 传约定目录，测试一律用临时目录
    public let directory: URL
    public private(set) var phase: ModelDownloadPhase = .notDownloaded
    /// 已下载到本地的字节数（所有文件合计，含之前中断留下的）
    public private(set) var receivedBytes: Int64 = 0
    /// 模型变得可用（下载完成）或不再可用（删除）时调用。App 在这里通知排队的管线。
    /// 按磁盘上的文件判断，变了就调用：取消时恰好下完、改名到位的也算
    @ObservationIgnored public var onAvailabilityChange: (() -> Void)?
    /// 删除 / 取消时，这个辅助模型要不要留着（还有别的已下载模型依赖它）。由 `ModelDownloads` 设置
    @ObservationIgnored public var keepsDependency: (LocalModel) -> Bool = { _ in false }

    @ObservationIgnored private let transport: any ModelTransport
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 每次开始下载加一，旧任务迟到的进度和结果据此丢弃
    @ObservationIgnored private var generation = 0

    public init(model: LocalModel, dependencies: [LocalModel] = [], directory: URL, transport: any ModelTransport) {
        self.model = model
        self.dependencies = dependencies
        self.directory = directory
        self.transport = transport
        refreshFromDisk()
    }

    /// 辅助模型在前：主模型下好时辅助模型一定也下好了
    var allModels: [LocalModel] { dependencies + [model] }
    /// 主模型和辅助模型的总字节数
    public var totalBytes: Int64 { allModels.reduce(0) { $0 + $1.size } }
    public var isReady: Bool { phase == .ready }
    public var isRunning: Bool { phase == .downloading || phase == .verifying }
    public var progress: Double { totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 0 }

    /// 开始或继续下载（也用于“重试”）。已就绪、正在下载时什么都不做
    public func start() {
        guard !isRunning, phase != .ready else { return }
        generation += 1
        let token = generation
        let previous = task
        phase = .downloading
        let job = DownloadJob(models: allModels, directory: directory, transport: transport,
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

    /// 取消下载，删掉这次已下的全部内容（含已下好的文件和辅助模型），回到未下载。
    /// 取消时恰好全部下完的不动，照样算就绪；别的模型还在用的辅助模型也不动
    public func cancel() async {
        await stop()
        if !allModels.allSatisfy({ $0.isDownloaded(in: directory) }) {
            for m in allModels where !isKept(m) {
                try? remove(m)
            }
        }
        refreshFromDisk()
    }

    /// 删除模型（和没下完的部分），以及没有别的模型依赖的辅助模型。之后状态回到未下载，排队的任务等待重新下载
    public func delete() async throws {
        await stop()
        var failure: Error?
        for m in allModels where !isKept(m) {
            do { try remove(m) } catch { failure = failure ?? error }
        }
        refreshFromDisk()
        if let failure { throw failure }
    }

    /// 等这次下载结束（完成、失败、暂停），测试用
    public func waitUntilFinished() async {
        await task?.value
    }

    private func isKept(_ m: LocalModel) -> Bool { m != model && keepsDependency(m) }

    /// 删掉一个模型的文件和部分文件。有自己的目录时整个目录删掉；放在根目录下的只删自己的文件
    @discardableResult
    private func remove(_ m: LocalModel) throws -> Bool {
        let fm = FileManager.default
        if !m.directoryName.isEmpty {
            let dir = m.directory(in: directory)
            guard fm.fileExists(atPath: dir.path) else { return false }
            try fm.removeItem(at: dir)
            return true
        }
        var failure: Error?
        for file in m.files {
            let url = m.url(of: file, in: directory)
            try? fm.removeItem(at: partialURL(url))
            if fm.fileExists(atPath: url.path) {
                do { try fm.removeItem(at: url) } catch { failure = error }
            }
        }
        if let failure { throw failure }
        return true
    }

    /// 停下正在进行的下载，等它真的不再写文件
    private func stop() async {
        generation += 1
        task?.cancel()
        await task?.value
        task = nil
    }

    /// 按磁盘上的文件得出状态；模型是否可用变了就通知
    private func refreshFromDisk() {
        let wasReady = isReady
        if allModels.allSatisfy({ $0.isDownloaded(in: directory) }) {
            receivedBytes = totalBytes
            phase = .ready
        } else {
            receivedBytes = bytesOnDisk(allModels, in: directory)
            // 只有还没下全的模型下了一部分才算“已暂停”：别的模型已经下好的辅助模型不算
            let unfinished = allModels.filter { !$0.isDownloaded(in: directory) }
            phase = bytesOnDisk(unfinished, in: directory) > 0 ? .paused : .notDownloaded
        }
        if isReady != wasReady { onAvailabilityChange?() }
    }

    private func report(_ event: DownloadJob.Event, token: Int) {
        guard token == generation, isRunning else { return }
        switch event {
        case let .received(bytes): receivedBytes = bytes
        case .verifying: phase = .verifying
        case .downloading: phase = .downloading
        }
    }

    private func finish(_ result: Result<Void, Error>, token: Int) {
        guard token == generation else { return }
        task = nil
        switch result {
        case .success:
            refreshFromDisk()
        case let .failure(error) where error is CancellationError:
            // 暂停
            refreshFromDisk()
        case let .failure(error):
            receivedBytes = bytesOnDisk(allModels, in: directory)
            phase = .failed(error.localizedDescription)
        }
    }
}

/// 文件的部分下载：同目录的 `<文件名>.partial`
func partialURL(_ file: URL) -> URL {
    file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".partial")
}

/// 磁盘上已有的字节数：下好的文件算全部，没下完的算部分文件的大小
private func bytesOnDisk(_ models: [LocalModel], in root: URL) -> Int64 {
    models.reduce(0) { total, m in
        m.files.reduce(total) { sum, file in
            let url = m.url(of: file, in: root)
            if fileHasSize(url, file.size) { return sum + file.size }
            return sum + min(fileSize(partialURL(url)), file.size)
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
        case .notDownloaded: "未下载（约 \(formatModelSize(totalBytes))）"
        case .downloading: "下载中 \(percent)（\(amount)）"
        case .paused: "已暂停，已下载 \(percent)（\(amount)）"
        case .verifying: "正在校验模型…"
        case .ready: "已就绪，占用 \(formatModelSize(totalBytes))"
        case let .failed(reason): "下载失败：\(reason)"
        }
    }

    public var minutesText: String {
        switch phase {
        case .notDownloaded: "生成纪要需要下载约 \(formatModelSize(totalBytes)) 的模型"
        case .downloading: "正在下载模型 \(percent)"
        case .paused: "模型下载已暂停（\(percent)）"
        case .verifying: "正在校验模型…"
        case .ready: "模型已就绪"
        case let .failed(reason): "模型下载失败：\(reason)"
        }
    }

    private var percent: String { "\(Int((progress * 100).rounded(.down)))%" }
    /// 已下 / 总共，两边用同一个单位（按总大小选：不到 1 GB 用 MB）
    private var amount: String {
        let gb = formatModelSize(totalBytes).hasSuffix("GB")
        func f(_ b: Int64) -> String { gb ? formatGigabytes(b) : String(format: "%.0f MB", Double(b) / 1e6) }
        return "\(f(receivedBytes)) / \(f(totalBytes))"
    }
}

extension ModelDownloader {
    public var status: ModelDownloadStatus {
        ModelDownloadStatus(phase: phase, receivedBytes: receivedBytes, totalBytes: totalBytes)
    }
}

/// 按十进制 GB 显示一位小数（和访达一致），如“2.5 GB”
public func formatGigabytes(_ bytes: Int64) -> String {
    String(format: "%.1f GB", Double(bytes) / 1e9)
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

/// 一次下载：在后台执行，不碰下载器的状态。所有文件逐个下载、逐个校验
private struct DownloadJob: Sendable {
    let models: [LocalModel]
    let directory: URL
    let transport: any ModelTransport
    let progress: @Sendable (Event) -> Void

    enum Event: Sendable {
        /// 所有文件合计现在下了多少
        case received(Int64)
        case downloading
        case verifying
    }

    func run() async throws {
        for m in models {
            for file in m.files {
                try Task.checkCancellation()
                let url = m.url(of: file, in: directory)
                // 上一次暂停时恰好下完、改了名；或者别的模型已经下好了这个辅助模型
                if fileHasSize(url, file.size) { continue }
                // 两个主模型依赖同一个辅助模型、同时下载时，不能同时写同一个部分文件
                try await ModelFileLocks.shared.withLock(url.path) {
                    if fileHasSize(url, file.size) { return }
                    try await download(file, to: url)
                }
            }
        }
    }

    private func download(_ file: ModelFile, to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = partialURL(url)
        // 别的文件已经下了多少，这个文件的进度加上它就是整体进度
        let base = bytesOnDisk(models, in: directory) - min(fileSize(partial), file.size)
        progress(.downloading)
        try await FileFetch(file: file, partial: partial, transport: transport, base: base, progress: progress)
            .fetchFromSources()
        try Task.checkCancellation()
        progress(.verifying)
        guard try sha256(of: partial) == file.sha256 else {
            // 不知道坏在哪一段，只能整个重下
            try? FileManager.default.removeItem(at: partial)
            throw ModelDownloadError.checksumMismatch
        }
        try Task.checkCancellation()
        // 大小不对的旧文件（不算已下载）。大小对的文件一开始就跳过了，不会走到这里
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: partial, to: url)
    }
}

/// 下载一个文件到它的部分文件
private struct FileFetch: Sendable {
    let file: ModelFile
    let partial: URL
    let transport: any ModelTransport
    /// 其他文件已下的字节数，报进度时加上
    let base: Int64
    let progress: @Sendable (DownloadJob.Event) -> Void

    /// 按顺序试每个来源，直到部分文件完整。一个来源下到一半断了（这次有进展）就从断点重连它，
    /// 连上也没进展才换下一个，所以不会无限重试。换来源也接着断点下：各来源是同一个文件，最后靠哈希兜底
    func fetchFromSources() async throws {
        var lastError: Error = ModelDownloadError.noSource
        var index = 0
        while index < file.downloadURLs.count {
            let before = fileSize(partial)
            do {
                try await fetch(file.downloadURLs[index])
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
        if offset > file.size {
            try? FileManager.default.removeItem(at: partial)
            offset = 0
        }
        if offset == file.size, FileManager.default.fileExists(atPath: partial.path) { return }
        let response = try await transport.get(url, from: offset)
        defer { response.cancel() }
        let writeOffset: Int64
        let range = response.contentRange.flatMap(ContentRange.init)
        switch response.status {
        case 206:
            guard let range, range.start == offset else { throw ModelDownloadError.badResponse }
            if let total = range.total, total != file.size { throw ModelDownloadError.sizeMismatch }
            writeOffset = offset
        case 200 where offset > 0 && range?.start == offset:
            // ModelScope 对不走 LFS 的小文件回 200，但内容按 Range 给了、带着 Content-Range：按部分内容续传
            if let total = range?.total, total != file.size { throw ModelDownloadError.sizeMismatch }
            writeOffset = offset
        case 200:
            // 服务器不认 Range，从头给了整个文件
            if let length = response.contentLength, length != file.size { throw ModelDownloadError.sizeMismatch }
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
        progress(.received(base + written))
        // 进度最多每 0.1 秒报一次：每块只有几十 KB，2.5GB 要报上万次
        let clock = ContinuousClock()
        var lastReport = clock.now - .seconds(1)
        for try await chunk in response.body {
            try Task.checkCancellation()
            written += Int64(chunk.count)
            if written > file.size { throw ModelDownloadError.sizeMismatch }
            try handle.write(contentsOf: chunk)
            if clock.now - lastReport >= .milliseconds(100) {
                lastReport = clock.now
                progress(.received(base + written))
            }
        }
        progress(.received(base + written))
        try handle.close()
        if written < file.size { throw ModelDownloadError.incomplete }
    }
}

/// 进程内按文件路径互斥：同一时刻只有一个下载在写某个文件
actor ModelFileLocks {
    static let shared = ModelFileLocks()
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withLock<T: Sendable>(_ path: String, _ body: @Sendable () async throws -> T) async throws -> T {
        await acquire(path)
        defer { release(path) }
        try Task.checkCancellation()
        return try await body()
    }

    private func acquire(_ path: String) async {
        if held.insert(path).inserted { return }
        await withCheckedContinuation { waiters[path, default: []].append($0) }
    }

    private func release(_ path: String) {
        if var queue = waiters[path], !queue.isEmpty {
            // 直接交给下一个等待者，锁不释放
            let next = queue.removeFirst()
            waiters[path] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            held.remove(path)
        }
    }
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
