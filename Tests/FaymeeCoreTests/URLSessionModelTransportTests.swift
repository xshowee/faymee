import Foundation
import Testing
@testable import FaymeeCore

/// 真实网络的契约测试：设环境变量 `FAYMEE_NETWORK=1` 才跑。对每个下载地址从文件中部取 1MiB 就断开，
/// 不下整个文件。确认 Range 跟着跳转走（Hugging Face 会 302 到签名 CDN）、返回 206 和正确的总长；
/// 本机已有模型时再和本地文件逐字节比较（只读）
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FAYMEE_NETWORK"] == "1", "设 FAYMEE_NETWORK=1 才跑"))
struct URLSessionModelTransportTests {
    static let model = LocalModel.qwen3_4B
    static let offset: Int64 = 1_234_567_890
    static let length = 1 << 20

    @Test(arguments: LocalModel.qwen3_4B.downloadURLs)
    func 从中间续传返回206和总长(url: URL) async throws {
        let transport = URLSessionModelTransport()
        let response = try await transport.get(url, from: Self.offset)
        defer { response.cancel() }

        #expect(response.status == 206)
        let range = try #require(response.contentRange.flatMap(ContentRange.init))
        #expect(range.start == Self.offset)
        #expect(range.total == Self.model.size)

        var received = Data()
        for try await chunk in response.body {
            received.append(chunk)
            if received.count >= Self.length { break }
        }
        received = received.prefix(Self.length)
        #expect(received.count == Self.length)

        if Self.model.isDownloaded() {
            let handle = try FileHandle(forReadingFrom: Self.model.url())
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(Self.offset))
            #expect(try handle.read(upToCount: Self.length) == received)
        }
    }
}
