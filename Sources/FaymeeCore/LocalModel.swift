import Foundation

/// 模型的一个文件：放在模型目录下的哪个相对路径、多大、哈希多少、从哪下载
public struct ModelFile: Sendable, Hashable {
    /// 相对模型目录的路径，可以带子目录（如 `Qwen3-0.6B/vocab.json`）
    public let path: String
    /// 字节数
    public let size: Int64
    /// 小写 hex，下载完成后校验
    public let sha256: String
    /// 下载地址，按优先顺序。各地址必须是字节完全相同的同一个文件（靠 sha256 兜底）
    public let downloadURLs: [URL]

    public init(path: String, size: Int64, sha256: String, downloadURLs: [URL]) {
        self.path = path
        self.size = size
        self.sha256 = sha256
        self.downloadURLs = downloadURLs
    }
}

/// 一个需要下载的本机模型 = 若干文件，放在 `Models/<directoryName>/` 下。下载器和各引擎共用这些常量。
/// 目录项（`ModelCatalog`）里需要下载的模型都带一个 `LocalModel`
public struct LocalModel: Sendable, Equatable {
    /// 模型标识，和目录项的 `id` 相同，写进转写稿 / 纪要等
    public let id: String
    /// `Models/` 下的目录名；空串表示文件直接放在 `Models/` 根下（Qwen3 4B 的历史位置，已下载的用户不用重下）
    public let directoryName: String
    public let files: [ModelFile]

    public init(id: String, directoryName: String, files: [ModelFile]) {
        precondition(!files.isEmpty, "模型至少有一个文件")
        self.id = id
        self.directoryName = directoryName
        self.files = files
    }

    /// 单文件、直接放在 `Models/` 根下的模型（Qwen3 4B 的写法）
    public init(id: String, fileName: String, size: Int64, sha256: String, downloadURLs: [URL]) {
        self.init(id: id, directoryName: "",
                  files: [ModelFile(path: fileName, size: size, sha256: sha256, downloadURLs: downloadURLs)])
    }

    /// 所有文件的总字节数
    public var size: Int64 { files.reduce(0) { $0 + $1.size } }

    /// 第一个文件的相对路径（单文件模型就是那个文件）
    public var fileName: String { files[0].path }

    /// Qwen3 4B（Qwen 官方 GGUF，Q4_K_M 量化）。大小和哈希与 ModelScope、Hugging Face 的文件 API 一致。
    /// 协议：Apache-2.0（Qwen/Qwen3-4B-GGUF）
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

    /// Qwen3.5 4B（Q4_K_M）。Qwen 没发 Qwen3.5 的 GGUF，用的是 Unsloth 转换的（第三方，imatrix 量化），
    /// ModelScope 与 Hugging Face 上是同一个文件（大小、sha256 一致，2026-11-18 核对）。协议：Apache-2.0
    public static let qwen3_5_4B = unslothQwen3_5(
        id: "llama/qwen3.5-4b-q4km", size: "4B", bytes: 2_740_937_888,
        sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
        hfCommit: "e87f176479d0855a907a41277aca2f8ee7a09523")

    /// Qwen3.5 9B（Q4_K_M），来源同 `qwen3_5_4B`。协议：Apache-2.0
    public static let qwen3_5_9B = unslothQwen3_5(
        id: "llama/qwen3.5-9b-q4km", size: "9B", bytes: 5_680_522_464,
        sha256: "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8",
        hfCommit: "3885219b6810b007914f3a7950a8d1b469d598a5")

    /// Unsloth 的 Qwen3.5 GGUF：放在 `Models/<id 去掉 llama/>/` 下（不和 Qwen3 4B 一样放根目录）
    private static func unslothQwen3_5(id: String, size: String, bytes: Int64, sha256: String,
                                       hfCommit: String) -> LocalModel {
        let file = "Qwen3.5-\(size)-Q4_K_M.gguf"
        let repo = "unsloth/Qwen3.5-\(size)-GGUF"
        return LocalModel(id: id, directoryName: String(id.dropFirst("llama/".count)), files: [
            ModelFile(path: file, size: bytes, sha256: sha256, downloadURLs: [
                URL(string: "https://modelscope.cn/api/v1/models/\(repo)/repo?Revision=master&FilePath=\(file)")!,
                // 钉在 2026-03-02 的 commit
                URL(string: "https://huggingface.co/\(repo)/resolve/\(hfCommit)/\(file)")!,
            ]),
        ])
    }

    /// 约定的模型根目录：~/Library/Application Support/Faymee/Models
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Faymee/Models", isDirectory: true)
    }

    /// 这个模型的目录（`root/<directoryName>`；目录名为空时就是 `root`）
    public func directory(in root: URL = LocalModel.defaultDirectory) -> URL {
        directoryName.isEmpty ? root : root.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// 某个文件的位置
    public func url(of file: ModelFile, in root: URL = LocalModel.defaultDirectory) -> URL {
        directory(in: root).appendingPathComponent(file.path)
    }

    /// 第一个文件的位置（单文件模型就是模型文件本身）
    public func url(in root: URL = LocalModel.defaultDirectory) -> URL {
        url(of: files[0], in: root)
    }

    /// 文件都在 `root` 下且大小与预期一致。不算哈希（2.5GB 要 5 秒多）：下载器先写临时文件，
    /// 校验哈希通过后才改名到位，所以这里只防“文件不在”和“被截断”。
    /// 加载前必须先确认这一点：坏模型会让 sherpa-onnx 直接 `_Exit` 整个进程
    public func isDownloaded(in root: URL = LocalModel.defaultDirectory) -> Bool {
        files.allSatisfy { fileHasSize(url(of: $0, in: root), $0.size) }
    }
}

/// 文件大小；不存在时为 0
func fileSize(_ url: URL) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
}

/// 文件存在且大小正好是 `size`（存在、大小为 0 的文件也算）
func fileHasSize(_ url: URL, _ size: Int64) -> Bool {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.int64Value == size
}
