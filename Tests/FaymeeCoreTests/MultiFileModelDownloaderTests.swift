import Foundation
import Testing
@testable import FaymeeCore

// 公开的 SHA-256 测试向量（不用代码现算）
private let abcSHA = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
private let helloSHA = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
private let xyzSHA = "3608bca1e44ea6c4d268eb6db02260269892c0b42b86bbf1e77a6fa16c3c9282"

private func url(_ s: String) -> URL { URL(string: "https://mirror.example/\(s)")! }

/// 主模型：两个文件，一个在子目录里，各有主、备两个地址
private let asrModel = LocalModel(id: "test/asr", directoryName: "asr-2026", files: [
    ModelFile(path: "model.onnx", size: 3, sha256: abcSHA, downloadURLs: [url("a/model.onnx"), url("b/model.onnx")]),
    ModelFile(path: "tokenizer/vocab.txt", size: 5, sha256: helloSHA,
              downloadURLs: [url("a/vocab.txt"), url("b/vocab.txt")]),
])
/// 辅助模型（如标点）
private let punctModel = LocalModel(id: "test/punct", directoryName: "punct-2024", files: [
    ModelFile(path: "punct.onnx", size: 3, sha256: xyzSHA, downloadURLs: [url("a/punct.onnx")]),
])

/// 服务器上的文件：按地址的最后两段（如 `a/model.onnx`）找内容，支持 Range；`broken` 里的地址返回 503
private final class Mirror: ModelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]
    private var _requests: [(path: String, offset: Int64)] = []
    /// 给出第一块后一直不结束的地址（模拟很慢的连接）
    var stalls: Set<String> = []

    init(_ files: [String: Data]) { self.files = files }

    var requests: [(path: String, offset: Int64)] { lock.withLock { _requests } }

    func set(_ path: String, _ data: Data?) { lock.withLock { files[path] = data } }

    func get(_ url: URL, from offset: Int64) async throws -> ModelResponse {
        let key = url.pathComponents.suffix(2).joined(separator: "/")
        let (file, stall) = lock.withLock { () -> (Data?, Bool) in
            _requests.append((key, offset))
            return (files[key], stalls.contains(key))
        }
        guard let file else {
            return ModelResponse(status: 503, contentRange: nil, contentLength: 0,
                                 body: AsyncThrowingStream { $0.finish() })
        }
        let rest = Data(file.suffix(from: Int(offset)))
        let body = AsyncThrowingStream<Data, Error> { c in
            if stall {
                c.yield(rest.prefix(1))
            } else {
                c.yield(rest)
                c.finish()
            }
        }
        if offset == 0 {
            return ModelResponse(status: 200, contentRange: nil, contentLength: Int64(file.count), body: body)
        }
        return ModelResponse(status: 206, contentRange: "bytes \(offset)-\(file.count - 1)/\(file.count)",
                             contentLength: Int64(rest.count), body: body)
    }
}

@MainActor
private final class Fixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FaymeeMultiFileTests-\(UUID().uuidString)", isDirectory: true)
    let mirror: Mirror

    init(_ files: [String: Data] = ["a/model.onnx": Data("abc".utf8), "a/vocab.txt": Data("hello".utf8),
                                     "a/punct.onnx": Data("xyz".utf8)]) {
        mirror = Mirror(files)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func downloader(_ model: LocalModel = asrModel, dependencies: [LocalModel] = []) -> ModelDownloader {
        ModelDownloader(model: model, dependencies: dependencies, directory: root, transport: mirror)
    }

    func file(_ model: LocalModel, _ index: Int) -> URL { model.url(of: model.files[index], in: root) }
    func partial(_ model: LocalModel, _ index: Int) -> URL {
        URL(fileURLWithPath: file(model, index).path + ".partial")
    }
    func contents(_ url: URL) -> Data? { try? Data(contentsOf: url) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}

@MainActor @Suite struct MultiFileModelDownloaderTests {
    @Test func 逐个下载每个文件_校验后放进模型自己的目录() async {
        let f = Fixture()
        let d = f.downloader()
        #expect(d.status.totalBytes == 8)

        d.start()
        await d.waitUntilFinished()

        #expect(d.phase == .ready)
        #expect(d.receivedBytes == 8)
        #expect(f.contents(f.root.appendingPathComponent("asr-2026/model.onnx")) == Data("abc".utf8))
        #expect(f.contents(f.root.appendingPathComponent("asr-2026/tokenizer/vocab.txt")) == Data("hello".utf8))
        #expect(!f.exists(f.partial(asrModel, 0)) && !f.exists(f.partial(asrModel, 1)))
        #expect(asrModel.isDownloaded(in: f.root))
        #expect(f.mirror.requests.map(\.path) == ["a/model.onnx", "a/vocab.txt"])
    }

    @Test func 某个文件校验失败时_只删这个文件的部分_已下好的文件不重下() async {
        let f = Fixture()
        f.mirror.set("a/vocab.txt", Data("hellx".utf8))
        let d = f.downloader()

        d.start()
        await d.waitUntilFinished()

        #expect(d.phase == .failed("下载的文件校验失败，已删除，请重试"))
        #expect(f.contents(f.file(asrModel, 0)) == Data("abc".utf8))
        #expect(!f.exists(f.file(asrModel, 1)) && !f.exists(f.partial(asrModel, 1)))
        #expect(d.receivedBytes == 3)

        f.mirror.set("a/vocab.txt", Data("hello".utf8))
        d.start()
        await d.waitUntilFinished()

        #expect(d.phase == .ready)
        #expect(f.mirror.requests.map(\.path) == ["a/model.onnx", "a/vocab.txt", "a/vocab.txt"])
    }

    @Test func 每个文件各自按顺序换备用地址() async {
        let f = Fixture(["a/model.onnx": Data("abc".utf8), "b/vocab.txt": Data("hello".utf8)])
        let d = f.downloader()

        d.start()
        await d.waitUntilFinished()

        #expect(d.phase == .ready)
        #expect(f.mirror.requests.map(\.path) == ["a/model.onnx", "a/vocab.txt", "b/vocab.txt"])
    }

    @Test func 暂停后继续_从中断的文件的断点续传_整体进度按总字节数() async throws {
        let f = Fixture()
        f.mirror.stalls = ["a/vocab.txt"]
        let d = f.downloader()

        d.start()
        try await f.until { d.receivedBytes == 4 }  // 第一个文件 3 字节 + 第二个文件 1 字节
        #expect(d.progress == 0.5)
        d.pause()
        await d.waitUntilFinished()
        #expect(d.phase == .paused)
        #expect(d.receivedBytes == 4)

        // 重开 App：按磁盘上的文件得出进度
        let reopened = f.downloader()
        #expect(reopened.phase == .paused)
        #expect(reopened.receivedBytes == 4)

        f.mirror.stalls = []
        reopened.start()
        await reopened.waitUntilFinished()

        #expect(reopened.phase == .ready)
        #expect(f.mirror.requests.map(\.path) == ["a/model.onnx", "a/vocab.txt", "a/vocab.txt"])
        #expect(f.mirror.requests.last?.offset == 1)
        #expect(f.contents(f.file(asrModel, 1)) == Data("hello".utf8))
    }

    @Test func 取消时删掉这个模型已下的全部内容() async throws {
        let f = Fixture()
        f.mirror.stalls = ["a/vocab.txt"]
        let d = f.downloader()
        d.start()
        try await f.until { d.receivedBytes == 4 }

        await d.cancel()

        #expect(!f.exists(f.partial(asrModel, 1)))
        #expect(!f.exists(f.file(asrModel, 0)))
        #expect(d.phase == .notDownloaded)
        #expect(d.receivedBytes == 0)
    }

    @Test func 删除模型时删掉整个模型目录() async throws {
        let f = Fixture()
        let d = f.downloader()
        d.start()
        await d.waitUntilFinished()
        var changes = 0
        d.onAvailabilityChange = { changes += 1 }

        try await d.delete()

        #expect(d.phase == .notDownloaded)
        #expect(d.receivedBytes == 0)
        #expect(!f.exists(asrModel.directory(in: f.root)))
        #expect(f.exists(f.root))
        #expect(changes == 1)
    }

    @Test func 辅助模型随主模型一起下载_一起算进度() async {
        let f = Fixture()
        let d = f.downloader(dependencies: [punctModel])
        #expect(d.status.totalBytes == 11)

        d.start()
        await d.waitUntilFinished()

        #expect(d.phase == .ready)
        #expect(punctModel.isDownloaded(in: f.root))
        #expect(asrModel.isDownloaded(in: f.root))
        #expect(Set(f.mirror.requests.map(\.path)) == ["a/model.onnx", "a/vocab.txt", "a/punct.onnx"])
    }

    @Test func 辅助模型缺了也不算就绪() async throws {
        let f = Fixture()
        let main = f.downloader()
        main.start()
        await main.waitUntilFinished()
        #expect(main.phase == .ready)

        let withPunct = f.downloader(dependencies: [punctModel])
        #expect(withPunct.phase == .notDownloaded)  // 主模型已下好，只差辅助模型
        #expect(withPunct.receivedBytes == 8)
        withPunct.start()
        await withPunct.waitUntilFinished()
        #expect(withPunct.phase == .ready)
        #expect(f.mirror.requests.filter { $0.path == "a/model.onnx" }.count == 1)  // 已下好的主模型不重下
    }

    @Test func 删除主模型时_没有别的模型依赖的辅助模型一起删除() async throws {
        let f = Fixture()
        let d = f.downloader(dependencies: [punctModel])
        d.start()
        await d.waitUntilFinished()

        try await d.delete()

        #expect(!f.exists(asrModel.directory(in: f.root)))
        #expect(!f.exists(punctModel.directory(in: f.root)))
    }

    @Test func 删除主模型时_还有别的模型依赖的辅助模型保留() async throws {
        let f = Fixture()
        let d = f.downloader(dependencies: [punctModel])
        d.keepsDependency = { $0.id == punctModel.id }
        d.start()
        await d.waitUntilFinished()

        try await d.delete()

        #expect(!f.exists(asrModel.directory(in: f.root)))
        #expect(punctModel.isDownloaded(in: f.root))
        #expect(d.phase == .notDownloaded)
    }

    @Test func 根目录下的单文件模型_删除时只删自己的文件不删目录() async throws {
        let qwen = LocalModel(id: "test/llm", fileName: "llm.gguf", size: 3, sha256: abcSHA,
                              downloadURLs: [url("a/model.onnx")])
        let f = Fixture()
        let d = f.downloader(qwen)
        d.start()
        await d.waitUntilFinished()
        #expect(f.contents(f.root.appendingPathComponent("llm.gguf")) == Data("abc".utf8))
        try Data("keep".utf8).write(to: f.root.appendingPathComponent("other.bin"))

        try await d.delete()

        #expect(!f.exists(f.root.appendingPathComponent("llm.gguf")))
        #expect(f.exists(f.root.appendingPathComponent("other.bin")))
    }
}

/// 两个主模型共用一个辅助模型的目录
private let asr2Model = LocalModel(id: "test/asr2", directoryName: "asr2", files: [
    ModelFile(path: "m.onnx", size: 3, sha256: abcSHA, downloadURLs: [url("a/model.onnx")]),
])
private let sharedCatalog = ModelCatalog(models: [
    CatalogModel(id: asrModel.id, roles: [.transcription], family: .sherpaParaformer, source: .download(asrModel),
                 name: "A", dependencies: [punctModel.id, "test/vad"]),
    CatalogModel(id: asr2Model.id, roles: [.liveFinalize], family: .sherpaParaformer, source: .download(asr2Model),
                 name: "B", dependencies: [punctModel.id]),
    CatalogModel(id: punctModel.id, roles: [], family: .sherpaPunctuation, source: .download(punctModel), name: "标点"),
    CatalogModel(id: "test/vad", roles: [], family: .sileroVAD, source: .bundled(directory: "VAD", fileName: "v.onnx"),
                 name: "VAD"),
    CatalogModel(id: "test/system", roles: [.transcription], family: .speechAnalyzer, source: .system, name: "系统"),
])

@MainActor @Suite struct ModelDownloadsTests {
    @Test func 系统自带和打进App的模型没有下载器_总是就绪() {
        let f = Fixture()
        let downloads = ModelDownloads(catalog: sharedCatalog, directory: f.root, transport: f.mirror)
        let system = sharedCatalog.model(id: "test/system")!
        #expect(downloads.downloader(for: system) == nil)
        #expect(downloads.isReady(system))
    }

    @Test func 同一个模型拿到同一个下载器_下载器带上要下载的辅助模型() async {
        let f = Fixture()
        let downloads = ModelDownloads(catalog: sharedCatalog, directory: f.root, transport: f.mirror)
        let a = sharedCatalog.model(id: asrModel.id)!
        let d = downloads.downloader(for: a)!
        #expect(downloads.downloader(for: a) === d)
        #expect(d.dependencies == [punctModel])  // 打进 App 的 VAD 不用下
        #expect(!downloads.isReady(a))

        d.start()
        await d.waitUntilFinished()

        #expect(downloads.isReady(a))
    }

    @Test func 删除主模型时_另一个已下载的模型也依赖的辅助模型保留_否则一起删() async throws {
        let f = Fixture()
        let downloads = ModelDownloads(catalog: sharedCatalog, directory: f.root, transport: f.mirror)
        let a = downloads.downloader(for: sharedCatalog.model(id: asrModel.id)!)!
        let b = downloads.downloader(for: sharedCatalog.model(id: asr2Model.id)!)!
        a.start()
        await a.waitUntilFinished()
        b.start()
        await b.waitUntilFinished()
        #expect(f.mirror.requests.filter { $0.path == "a/punct.onnx" }.count == 1)  // 共用的辅助模型只下一次

        try await a.delete()
        #expect(!asrModel.isDownloaded(in: f.root))
        #expect(punctModel.isDownloaded(in: f.root))
        #expect(b.phase == .ready)

        try await b.delete()
        #expect(!punctModel.isDownloaded(in: f.root))
    }

    @Test func 两个共用辅助模型的模型同时下载_辅助模型不会被同时写() async {
        let f = Fixture()
        let downloads = ModelDownloads(catalog: sharedCatalog, directory: f.root, transport: f.mirror)
        let a = downloads.downloader(for: sharedCatalog.model(id: asrModel.id)!)!
        let b = downloads.downloader(for: sharedCatalog.model(id: asr2Model.id)!)!

        a.start()
        b.start()
        await a.waitUntilFinished()
        await b.waitUntilFinished()

        #expect(a.phase == .ready && b.phase == .ready)
        #expect(f.contents(f.file(punctModel, 0)) == Data("xyz".utf8))
    }
}
