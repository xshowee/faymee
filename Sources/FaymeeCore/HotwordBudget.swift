import Foundation

/// 大模型类 ASR 的热词要和音频、输出共用上下文（Fun-ASR-Nano 512 token），只能放进有限的 token。
/// 按热词表的顺序放，放到预算用完为止
public enum HotwordBudget {
    /// 按顺序取热词，直到按模型拼法（`separator` 连接，同 sherpa 拼进提示词的样子：Fun-ASR-Nano `, `，
    /// Qwen3-ASR 空格）计数的 token 超过 `budget`。
    /// 一个词放不下就停：热词表的顺序是用户排的，不跳过它去塞后面更短的词
    public static func fit(_ hotwords: [String], budget: Int, separator: String = ", ",
                           count: (String) -> Int) -> [String] {
        var kept: [String] = []
        for word in hotwords {
            guard count((kept + [word]).joined(separator: separator)) <= budget else { break }
            kept.append(word)
        }
        return kept
    }
}

/// Qwen 系列（Qwen2/Qwen3）tokenizer 的 token 计数：字节级 BPE，只用 `merges.txt`。
/// 与 Hugging Face tokenizers 对同一份 tokenizer.json 的结果一致（NFC 规整 → 按 Qwen 的正则预切分 →
/// 每段 UTF-8 字节映射成可见字符 → 按 merges 的顺序合并），不认特殊 token（热词里不会有）。
///
/// 只用来给热词计数：sherpa-onnx 的 C API 没有 tokenizer 接口
public final class QwenTokenCounter: @unchecked Sendable {
    /// 合并规则的优先级：「左 右」→ 行号
    private let ranks: [String: Int]
    /// 预切分结果 → token 数（热词表每次多放一个词都要重算整串）
    private var cache: [String: Int] = [:]
    private let lock = NSLock()

    /// tokenizer.json 里 pre_tokenizer 的 Split 正则
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#)

    /// GPT-2 的字节到可见字符映射：可打印的 Latin-1 字节映射到自己，其余依次映射到 U+0100 起
    private static let byteCharacters: [Character] = {
        var printable = Array(0x21...0x7E) + Array(0xA1...0xAC) + Array(0xAE...0xFF)
        var mapped = printable
        var next = 0
        for b in 0..<256 where !printable.contains(b) {
            printable.append(b)
            mapped.append(256 + next)
            next += 1
        }
        var table = [Character](repeating: " ", count: 256)
        for (b, u) in zip(printable, mapped) { table[b] = Character(Unicode.Scalar(u)!) }
        return table
    }()

    /// - Parameter directory: tokenizer 目录（含 merges.txt），如 Fun-ASR-Nano 的 `Qwen3-0.6B/`
    public init(directory: URL) throws {
        let text = try String(contentsOf: directory.appendingPathComponent("merges.txt"), encoding: .utf8)
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(160_000)
        var rank = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("#version") {
            ranks[String(line)] = rank
            rank += 1
        }
        self.ranks = ranks
    }

    public func count(_ text: String) -> Int {
        let normalized = text.precomposedStringWithCanonicalMapping
        let ns = normalized as NSString
        return Self.pattern.matches(in: normalized, range: NSRange(location: 0, length: ns.length)).reduce(0) {
            $0 + pieces(ns.substring(with: $1.range))
        }
    }

    /// 一段预切分结果合并后的 token 数
    private func pieces(_ word: String) -> Int {
        if let n = lock.withLock({ cache[word] }) { return n }
        var symbols = word.utf8.map { String(Self.byteCharacters[Int($0)]) }
        while symbols.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(symbols.count - 1) {
                if let r = ranks[symbols[i] + " " + symbols[i + 1]], r < best?.rank ?? .max { best = (r, i) }
            }
            guard let best else { break }
            let left = symbols[best.index], right = symbols[best.index + 1]
            var merged: [String] = []
            var i = 0
            while i < symbols.count {
                if i + 1 < symbols.count, symbols[i] == left, symbols[i + 1] == right {
                    merged.append(left + right)
                    i += 2
                } else {
                    merged.append(symbols[i])
                    i += 1
                }
            }
            symbols = merged
        }
        lock.withLock { cache[word] = symbols.count }
        return symbols.count
    }
}
