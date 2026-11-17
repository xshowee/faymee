import CryptoKit
import Foundation
import Testing
@testable import FaymeeCore

/// 目录里每个模型每个文件的每个下载地址
struct CatalogSource: CustomTestStringConvertible, Sendable {
    let model: LocalModel
    let file: ModelFile
    let url: URL

    static var all: [CatalogSource] {
        ModelCatalog.builtIn.models.compactMap(\.download).flatMap { m in
            m.files.flatMap { f in f.downloadURLs.map { CatalogSource(model: m, file: f, url: $0) } }
        }
    }

    var testDescription: String { "\(model.id) \(file.path) ← \(url.absoluteString)" }
}

/// 真实网络的契约测试：设环境变量 `FAYMEE_NETWORK=1` 才跑。对目录里每个文件的每个下载地址：
/// - 小文件（≤ 16 MB）整个下载，核对大小和 sha256（Hugging Face 不给非 LFS 小文件的 sha256，只能下来算）
/// - 大文件从中部取 1MiB 就断开：确认 Range 跟着跳转走（会 302 到签名 CDN）、返回 206 和正确的总长；
///   本机已有这个模型时再和本地文件逐字节比较（只读）
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FAYMEE_NETWORK"] == "1", "设 FAYMEE_NETWORK=1 才跑"))
struct URLSessionModelTransportTests {
    static let length = 1 << 20
    static let smallFile: Int64 = 16 << 20

    @Test(arguments: CatalogSource.all)
    func 每个下载地址都给出预期的文件(source: CatalogSource) async throws {
        let transport = URLSessionModelTransport()
        let file = source.file
        if file.size <= Self.smallFile {
            let response = try await transport.get(source.url, from: 0)
            defer { response.cancel() }
            #expect(response.status == 200)
            var received = Data()
            for try await chunk in response.body { received.append(chunk) }
            #expect(Int64(received.count) == file.size)
            let digest = SHA256.hash(data: received).map { String(format: "%02x", $0) }.joined()
            #expect(digest == file.sha256)
            return
        }

        let offset = file.size / 2
        let response = try await transport.get(source.url, from: offset)
        defer { response.cancel() }

        #expect(response.status == 206)
        let range = try #require(response.contentRange.flatMap(ContentRange.init))
        #expect(range.start == offset)
        #expect(range.total == file.size)

        var received = Data()
        for try await chunk in response.body {
            received.append(chunk)
            if received.count >= Self.length { break }
        }
        received = received.prefix(Self.length)
        #expect(received.count == Self.length)

        let local = source.model.url(of: file, in: LocalModel.defaultDirectory)
        if fileHasSize(local, file.size) {
            let handle = try FileHandle(forReadingFrom: local)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            #expect(try handle.read(upToCount: Self.length) == received)
        }
    }
}
