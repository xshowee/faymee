import Foundation

/// 全局热词表：人名、产品名、公司术语，转写时交给引擎提高识别率。用户编辑的是一段文本，一行一个词
public enum Hotwords {
    /// 去掉每行首尾空白（含全角空格），丢弃空行，按首次出现的顺序去重。
    /// 去重区分大小写：引擎按热词原样输出，“iOS”和“IOS”可能是用户有意写的两种形式
    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// 热词表存成纯文本文件，一行一个词，用户也可以直接用文本编辑器改：
///
///     ~/Library/Application Support/Faymee/hotwords.txt
///
/// 存的是用户输入的原文，不做整理：编辑框边输入边保存，整理会吞掉正在输入的空行和空格。
/// 交给引擎前再用 `Hotwords.parse` 整理
public struct HotwordStore {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Faymee/hotwords.txt")
    }

    /// 还没有热词表时返回空文本
    public func load() throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 原子写入。previous 是上次读到或存下的内容：写之前先核对文件还是它，
    /// 读不出来（如被存成了别的编码）或已在别处改过就抛错、不写，免得一次按键把整个文件覆盖掉
    public func save(_ text: String, replacing previous: String) throws {
        guard try load() == previous else { throw HotwordStoreError.changedOnDisk }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

public enum HotwordStoreError: LocalizedError, Equatable {
    case changedOnDisk

    public var errorDescription: String? {
        switch self {
        case .changedOnDisk: "热词表文件在别处被修改过"
        }
    }
}
