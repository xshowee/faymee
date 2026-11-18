import Foundation
import Testing
@testable import FaymeeCore

/// 用真实网络把目录里需要下载的模型下到 App 的模型目录（~/Library/Application Support/Faymee/Models），
/// 给模型契约测试和评估脚本用。设环境变量 `FAYMEE_DOWNLOAD_MODELS=1` 才跑；可以用
/// `FAYMEE_DOWNLOAD_MODELS_ONLY=<id>,<id>` 只下其中几个。已下好的不重下，下载器逐个文件校验 sha256
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FAYMEE_DOWNLOAD_MODELS"] == "1",
                             "设 FAYMEE_DOWNLOAD_MODELS=1 才跑"))
struct CatalogModelDownloadTests {
    @Test func 下载目录里的模型() async throws {
        let only = ProcessInfo.processInfo.environment["FAYMEE_DOWNLOAD_MODELS_ONLY"]
            .map { Set($0.split(separator: ",").map(String.init)) }
        let catalog = ModelCatalog.builtIn
        let downloads = ModelDownloads(catalog: catalog, directory: LocalModel.defaultDirectory,
                                       transport: URLSessionModelTransport())
        let targets = catalog.models.filter { !$0.roles.isEmpty && $0.download != nil && $0.id != LocalModel.qwen3_4B.id }
            .filter { only?.contains($0.id) ?? true }
        for model in targets {
            let d = try #require(downloads.downloader(for: model))
            d.start()
            await d.waitUntilFinished()
            #expect(d.phase == .ready, "\(model.id): \(d.phase)")
            print("\(model.id): \(d.phase) \(model.download!.directory().path)")
        }
    }
}
