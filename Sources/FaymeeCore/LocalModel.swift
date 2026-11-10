import Foundation

/// 本机纪要模型的文件：放在哪、叫什么、多大、哈希多少、从哪下载。下载器（ticket 05）和
/// `LlamaTextGenerator` 共用这些常量
public struct LocalModel: Sendable, Equatable {
    /// 写进 `Minutes.model` 的引擎标识
    public let id: String
    public let fileName: String
    /// 字节数
    public let size: Int64
    /// 小写 hex，下载完成后校验
    public let sha256: String
    /// 下载地址，按优先顺序
    public let downloadURLs: [URL]

    /// Qwen3 4B（Qwen 官方 GGUF，Q4_K_M 量化）。大小和哈希与 ModelScope、Hugging Face 的文件 API 一致
    public static let qwen3_4B = LocalModel(
        id: "llama/qwen3-4b-q4km",
        fileName: "Qwen3-4B-Q4_K_M.gguf",
        size: 2_497_280_256,
        sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5",
        downloadURLs: [
            // ModelScope 文件 API：不跳转，HEAD 有 Content-Length，Range 直接 206
            URL(string: "https://modelscope.cn/api/v1/models/Qwen/Qwen3-4B-GGUF/repo?Revision=master&FilePath=Qwen3-4B-Q4_K_M.gguf")!,
            // Hugging Face，钉在 2025-05-21 的 commit；302 到带签名、会过期的 CDN 地址
            URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/bc640142c66e1fdd12af0bd68f40445458f3869b/Qwen3-4B-Q4_K_M.gguf")!,
        ])

    /// 约定的模型目录：~/Library/Application Support/Faymee/Models
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Faymee/Models", isDirectory: true)
    }

    public func url(in directory: URL = LocalModel.defaultDirectory) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// 文件在 `directory` 里且大小与预期一致。不算哈希（2.5GB 要 5 秒多）：下载器先写临时文件，
    /// 校验哈希通过后才改名到这里，所以这里只防“文件不在”和“被截断”
    public func isDownloaded(in directory: URL = LocalModel.defaultDirectory) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url(in: directory).path)
        return (attributes?[.size] as? NSNumber)?.int64Value == size
    }
}
