import Foundation
import Testing
@testable import FaymeeCore

private let primary = URL(string: "https://primary.example/model.gguf")!
private let backup = URL(string: "https://backup.example/model.gguf")!

/// "abc" 的 SHA-256（公开的测试向量），不用代码现算
private let abcSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
private let abcModel = LocalModel(id: "test/abc", fileName: "abc.gguf", size: 3, sha256: abcSHA256,
                                  downloadURLs: [primary, backup])

/// 假网络：按脚本回应每次请求，记下请求了哪个地址、从哪个偏移开始
private final class FakeTransport: ModelTransport, @unchecked Sendable {
    typealias Reply = (_ url: URL, _ offset: Int64) throws -> ModelResponse
    private let lock = NSLock()
    private var replies: [Reply]
    private var _requests: [(url: URL, offset: Int64)] = []

    /// 第 i 次请求用第 i 个回应，用完后重复最后一个
    init(_ replies: Reply...) { self.replies = replies }

    var requests: [(url: URL, offset: Int64)] { lock.withLock { _requests } }

    func get(_ url: URL, from offset: Int64) async throws -> ModelResponse {
        let reply = lock.withLock {
            _requests.append((url, offset))
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
        return try reply(url, offset)
    }
}

/// 一个响应：状态码、Content-Range、Content-Length，响应体分成 chunks 依次给出，给完后可以接着抛错（模拟断线）
private func response(_ status: Int, range: String? = nil, length: Int64? = nil,
                      chunks: [Data], thenFail error: Error? = nil) -> ModelResponse {
    let body = AsyncThrowingStream<Data, Error> { c in
        for chunk in chunks { c.yield(chunk) }
        c.finish(throwing: error)
    }
    return ModelResponse(status: status, contentRange: range, contentLength: length, body: body)
}

/// 服务器上的完整文件：从 offset 起按 Range 返回 206，offset 为 0 时返回 200
private func serve(_ file: Data, chunkSize: Int = 2) -> FakeTransport.Reply {
    { _, offset in
        let rest = file.suffix(from: Int(offset))
        let chunks = stride(from: rest.startIndex, to: rest.endIndex, by: chunkSize).map {
            Data(rest[$0..<min($0 + chunkSize, rest.endIndex)])
        }
        if offset == 0 { return response(200, length: Int64(file.count), chunks: chunks) }
        return response(206, range: "bytes \(offset)-\(file.count - 1)/\(file.count)", length: Int64(rest.count),
                        chunks: chunks)
    }
}

/// 给出 chunks 之后一直不结束，直到请求被取消（模拟下得很慢的连接）
private func stalled(_ status: Int = 200, range: String? = nil, chunks: [Data]) -> ModelResponse {
    let body = AsyncThrowingStream<Data, Error> { c in
        for chunk in chunks { c.yield(chunk) }
    }
    return ModelResponse(status: status, contentRange: range, contentLength: 3, body: body)
}

private struct Offline: LocalizedError {
    var errorDescription: String? { "网络连接已中断" }
}

/// 假引擎：模型是否已下载看临时目录里的文件，和 LlamaTextGenerator 一样
private final class DiskBackedGenerator: TextGenerator, @unchecked Sendable {
    let model: LocalModel
    let directory: URL
    init(model: LocalModel, directory: URL) {
        self.model = model
        self.directory = directory
    }

    var contextTokens: Int { 100_000 }
    var isDownloaded: Bool { model.isDownloaded(in: directory) }
    func countTokens(_ text: String) -> Int { text.count }
    func load(progress: @escaping (Double) -> Void) async throws {}
    func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        #"{"overview": [{"text": "讨论了发布时间", "refs": ["s1"]}]}"#
    }
    func unload() {}
}

@MainActor
private final class FakeHost: MinutesHost {
    var meetings: [String: Meeting] = [:]
    func meeting(_ id: String) -> Meeting? { meetings[id] }
    func setMinutes(_ state: MinutesState, for id: String) { meetings[id]?.minutes = state }
}

@MainActor
private final class Fixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FaymeeModelTests-\(UUID().uuidString)", isDirectory: true)
    let model: LocalModel
    let transport: FakeTransport
    let downloader: ModelDownloader

    init(model: LocalModel = abcModel, _ transport: FakeTransport) {
        self.model = model
        self.transport = transport
        downloader = ModelDownloader(model: model, directory: directory, transport: transport)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// 接上纪要管线，接法同 AppModel：下载器的 onAvailabilityChange 调 modelAvailabilityChanged()，
    /// 并排进一场转写好的会议
    func makePipeline() -> (MinutesPipeline, FakeHost) {
        let store = MeetingStore(root: directory.appendingPathComponent("Meetings", isDirectory: true))
        let host = FakeHost()
        let pipeline = MinutesPipeline(store: store, generator: DiskBackedGenerator(model: model, directory: directory),
                                       model: model.id, host: host)
        downloader.onAvailabilityChange = { pipeline.modelAvailabilityChanged() }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var m = Meeting(id: "m1", title: "产品周会", startedAt: start, endedAt: start + 600, status: .done,
                        recording: "recording.m4a", duration: 600)
        m.transcription = TranscriptionState(status: .done)
        try! FileManager.default.createDirectory(at: store.directory("m1"), withIntermediateDirectories: true)
        try! store.save(m)
        try! store.saveTranscript(Transcript(engine: "fake", createdAt: start + 700, hotwords: [], items: [
            .sentence(TranscriptSentence(id: "s1", start: 1, end: 5, text: "我们今天讨论 v2.3 的发布时间，支付接口还没准备好")),
        ]), for: "m1")
        host.meetings["m1"] = m
        return (pipeline, host)
    }

    var modelFile: URL { model.url(in: directory) }
    var partialFile: URL { directory.appendingPathComponent(model.fileName + ".partial") }

    func contents(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    func writePartial(_ data: Data) {
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! data.write(to: partialFile)
    }

    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    /// 下载到结束（完成、失败或暂停）
    func download() async {
        downloader.start()
        await downloader.waitUntilFinished()
    }
}

@MainActor @Suite struct ModelDownloaderTests {
    @Test func 下载完成后校验通过_改名到约定位置() async {
        let f = Fixture(FakeTransport(serve(Data("abc".utf8))))
        #expect(f.downloader.phase == .notDownloaded)

        await f.download()

        #expect(f.downloader.phase == .ready)
        #expect(f.contents(f.modelFile) == Data("abc".utf8))
        #expect(!FileManager.default.fileExists(atPath: f.partialFile.path))
        #expect(f.model.isDownloaded(in: f.directory))
        #expect(f.transport.requests.map(\.url) == [primary])
        #expect(f.transport.requests.map(\.offset) == [0])
    }

    @Test func 有上次中断留下的部分文件时_从断点续传() async {
        let f = Fixture(FakeTransport(serve(Data("abc".utf8))))
        f.writePartial(Data("a".utf8))

        await f.download()

        #expect(f.transport.requests.map(\.offset) == [1])
        #expect(f.downloader.phase == .ready)
        #expect(f.contents(f.modelFile) == Data("abc".utf8))
    }

    @Test func 服务器不认Range从头返回时_重写部分文件而不是接在后面() async {
        // 不管偏移多少都返回 200 和整个文件
        let full: FakeTransport.Reply = { _, _ in response(200, length: 3, chunks: [Data("abc".utf8)]) }
        let g = Fixture(FakeTransport(full))
        g.writePartial(Data("x".utf8))

        await g.download()

        #expect(g.transport.requests.map(\.offset) == [1])
        #expect(g.downloader.phase == .ready)
        #expect(g.contents(g.modelFile) == Data("abc".utf8))
    }

    @Test func 校验失败时删掉下载的文件_显示原因_重试从头下载() async {
        let corrupt: FakeTransport.Reply = { _, _ in response(200, length: 3, chunks: [Data("abd".utf8)]) }
        let f = Fixture(FakeTransport(corrupt, serve(Data("abc".utf8))))

        await f.download()

        #expect(f.downloader.phase == .failed("下载的文件校验失败，已删除，请重试"))
        #expect(!FileManager.default.fileExists(atPath: f.modelFile.path))
        #expect(!FileManager.default.fileExists(atPath: f.partialFile.path))
        #expect(f.downloader.receivedBytes == 0)

        await f.download()

        #expect(f.transport.requests.map(\.offset) == [0, 0])
        #expect(f.downloader.phase == .ready)
        #expect(f.contents(f.modelFile) == Data("abc".utf8))
    }

    @Test func 主来源报错时改用备用来源() async {
        let unavailable: FakeTransport.Reply = { _, _ in response(503, chunks: []) }
        let f = Fixture(FakeTransport(unavailable, serve(Data("abc".utf8))))

        await f.download()

        #expect(f.transport.requests.map(\.url) == [primary, backup])
        #expect(f.downloader.phase == .ready)
    }

    @Test func 下到一半断线_从断点重连同一来源_再连不上才换备用来源并接着断点下() async {
        let dropped: FakeTransport.Reply = { _, _ in response(200, length: 3, chunks: [Data("a".utf8)], thenFail: Offline()) }
        let offline: FakeTransport.Reply = { _, _ in throw Offline() }
        let f = Fixture(FakeTransport(dropped, offline, serve(Data("abc".utf8))))

        await f.download()

        #expect(f.transport.requests.map(\.url) == [primary, primary, backup])
        #expect(f.transport.requests.map(\.offset) == [0, 1, 1])
        #expect(f.downloader.phase == .ready)
        #expect(f.contents(f.modelFile) == Data("abc".utf8))
    }

    @Test func 来源上的文件大小与预期不符时不用它_也不动已下的部分() async {
        // 主来源换了文件（ModelScope 没有钉版本）：Content-Range 的总长不对
        let changed: FakeTransport.Reply = { _, _ in response(206, range: "bytes 1-3/4", length: 3, chunks: [Data("xyz".utf8)]) }
        let f = Fixture(FakeTransport(changed, serve(Data("abc".utf8))))
        f.writePartial(Data("a".utf8))

        await f.download()

        #expect(f.transport.requests.map(\.url) == [primary, backup])
        #expect(f.transport.requests.map(\.offset) == [1, 1])
        #expect(f.contents(f.modelFile) == Data("abc".utf8))
    }

    @Test func 不用的响应要断开连接_免得剩下的内容继续下进内存() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.withLock { value += 1 } }
            var count: Int { lock.withLock { value } }
        }
        let cancels = Counter()
        // 来源上的文件大小不对：响应头一到就不用它了，但响应体还会一直来
        let changed: FakeTransport.Reply = { _, _ in
            var r = stalled(200, chunks: [])
            r.contentLength = 4
            r.cancel = { cancels.increment() }
            return r
        }
        let f = Fixture(FakeTransport(changed, serve(Data("abc".utf8))))

        await f.download()

        #expect(f.downloader.phase == .ready)
        #expect(cancels.count >= 1)
    }

    @Test func 所有来源都失败时显示原因_保留已下的部分供重试续传() async {
        let dropped: FakeTransport.Reply = { _, _ in response(200, length: 3, chunks: [Data("a".utf8)], thenFail: Offline()) }
        let offline: FakeTransport.Reply = { _, _ in throw Offline() }
        let f = Fixture(FakeTransport(dropped, offline))

        await f.download()

        #expect(f.transport.requests.map(\.url) == [primary, primary, backup])
        #expect(f.downloader.phase == .failed("网络连接已中断"))
        #expect(f.downloader.receivedBytes == 1)
        #expect(f.contents(f.partialFile) == Data("a".utf8))
    }

    @Test func 启动时按磁盘上的文件得出状态_不会自己开始下载() async throws {
        let ready = Fixture(FakeTransport(serve(Data("abc".utf8))))
        try FileManager.default.createDirectory(at: ready.directory, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: ready.modelFile)
        let paused = Fixture(FakeTransport(serve(Data("abc".utf8))))
        paused.writePartial(Data("ab".utf8))

        for f in [ready, paused] {
            let reopened = ModelDownloader(model: f.model, directory: f.directory, transport: f.transport)
            if f === ready {
                #expect(reopened.phase == .ready)
                #expect(reopened.receivedBytes == 3)
            } else {
                #expect(reopened.phase == .paused)
                #expect(reopened.receivedBytes == 2)
            }
            try await Task.sleep(for: .milliseconds(20))
            #expect(f.transport.requests.isEmpty)
        }
    }

    @Test func 暂停时保留已下的部分_继续下载从断点开始() async throws {
        let slow: FakeTransport.Reply = { _, _ in stalled(chunks: [Data("a".utf8)]) }
        let f = Fixture(FakeTransport(slow, serve(Data("abc".utf8))))

        f.downloader.start()
        try await f.until { f.downloader.receivedBytes == 1 }
        #expect(f.downloader.phase == .downloading)
        #expect(f.downloader.progress == 1.0 / 3)
        f.downloader.pause()
        #expect(f.downloader.phase == .paused)
        await f.downloader.waitUntilFinished()

        #expect(f.downloader.phase == .paused)
        #expect(f.downloader.receivedBytes == 1)
        #expect(f.contents(f.partialFile) == Data("a".utf8))

        await f.download()

        #expect(f.transport.requests.map(\.offset) == [0, 1])
        #expect(f.downloader.phase == .ready)
        #expect(f.contents(f.modelFile) == Data("abc".utf8))
    }

    @Test func 取消时删掉已下的部分() async throws {
        let slow: FakeTransport.Reply = { _, _ in stalled(chunks: [Data("a".utf8)]) }
        let f = Fixture(FakeTransport(slow))
        f.downloader.start()
        try await f.until { f.downloader.receivedBytes == 1 }

        await f.downloader.cancel()

        #expect(f.downloader.phase == .notDownloaded)
        #expect(f.downloader.receivedBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: f.partialFile.path))
    }

    @Test func 下载完成后排队的纪要自动开始() async throws {
        let f = Fixture(FakeTransport(serve(Data("abc".utf8))))
        let (pipeline, host) = f.makePipeline()
        #expect(pipeline.enqueue("m1"))
        #expect(pipeline.waitReason(for: "m1") == .model)

        await f.download()

        try await f.until { host.meetings["m1"]?.minutes?.status == .done }
    }

    @Test func 删除模型后状态回到未下载_排队的纪要显示等待下载模型() async throws {
        let f = Fixture(FakeTransport(serve(Data("abc".utf8))))
        await f.download()
        let (pipeline, host) = f.makePipeline()
        pipeline.isSuspended = true  // 先别开始，留在队列里
        #expect(pipeline.enqueue("m1"))
        #expect(pipeline.waitReason(for: "m1") == nil)

        try await f.downloader.delete()

        #expect(f.downloader.phase == .notDownloaded)
        #expect(f.downloader.receivedBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: f.modelFile.path))
        pipeline.isSuspended = false
        #expect(pipeline.waitReason(for: "m1") == .model)
        #expect(MinutesStatus(state: host.meetings["m1"]?.minutes, activity: pipeline.activity(for: "m1"),
                              waitReason: pipeline.waitReason(for: "m1"), transcript: nil).text == "等待下载模型")
    }

    @Test func 下载中删除模型_停下下载并删掉部分文件() async throws {
        let slow: FakeTransport.Reply = { _, _ in stalled(chunks: [Data("a".utf8)]) }
        let f = Fixture(FakeTransport(slow))
        f.downloader.start()
        try await f.until { f.downloader.receivedBytes == 1 }

        try await f.downloader.delete()

        #expect(f.downloader.phase == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: f.partialFile.path))
    }

    @Test func 设置和详情页上的模型状态文字() {
        let size: Int64 = 2_497_280_256
        func status(_ phase: ModelDownloadPhase, _ received: Int64 = 0) -> ModelDownloadStatus {
            ModelDownloadStatus(phase: phase, receivedBytes: received, totalBytes: size)
        }

        #expect(status(.notDownloaded).text == "未下载（约 2.5 GB）")
        #expect(status(.notDownloaded).minutesText == "生成纪要需要下载约 2.5 GB 的模型")
        #expect(status(.downloading, 950_000_000).text == "下载中 38%（0.9 GB / 2.5 GB）")
        #expect(status(.downloading, 950_000_000).minutesText == "正在下载模型 38%")
        #expect(status(.paused, 950_000_000).text == "已暂停，已下载 38%（0.9 GB / 2.5 GB）")
        #expect(status(.paused, 950_000_000).minutesText == "模型下载已暂停（38%）")
        #expect(status(.verifying, size).text == "正在校验模型…")
        #expect(status(.ready, size).text == "已就绪，占用 2.5 GB")
        #expect(status(.failed("网络连接已中断"), 950_000_000).text == "下载失败：网络连接已中断")
        #expect(status(.failed("网络连接已中断")).minutesText == "模型下载失败：网络连接已中断")
    }
}
