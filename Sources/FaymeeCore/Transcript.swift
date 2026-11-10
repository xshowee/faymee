import CryptoKit
import Foundation

/// 一场会议的转写稿，存为 transcript.json。
/// 时间都是相对 recording.m4a 开头的秒数，不是墙钟时间
public struct Transcript: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// 产出这份转写稿的引擎，如 "apple/speechanalyzer"
    public var engine: String
    public var createdAt: Date
    /// 转写时用的热词快照，用来判断改了热词表之后是否需要重转
    public var hotwords: [String]
    /// 按时间排序的句子与合盖空白
    public var items: [TranscriptItem]

    public init(version: Int = Transcript.currentVersion, engine: String, createdAt: Date,
                hotwords: [String], items: [TranscriptItem]) {
        self.version = version
        self.engine = engine
        self.createdAt = createdAt
        self.hotwords = hotwords
        self.items = items
    }

    public var sentences: [TranscriptSentence] {
        items.compactMap { if case let .sentence(s) = $0 { s } else { nil } }
    }

    /// 所有句子 `(id, text)` 的 SHA-256，形如 `sha256:<64 位小写十六进制>`。
    /// 生成纪要时记进 `Minutes.source`，之后与当前转写稿比对：只有它不同，才说明句子被修改过。
    /// 时间、合盖空白、`original` 不参与。
    ///
    /// 值会写盘并在以后比对，字节格式不能改：按句子顺序，每句依次写
    /// `<id 的 UTF-8 字节数>:<id><text 的 UTF-8 字节数>:<text>`，中间没有分隔符。
    /// 带长度前缀，文字在相邻句子间挪动不会撞出同一个哈希
    public var textHash: String {
        var bytes = Data()
        for s in sentences {
            for field in [s.id, s.text] {
                let utf8 = Data(field.utf8)
                bytes.append(contentsOf: "\(utf8.count):".utf8)
                bytes.append(utf8)
            }
        }
        return "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public struct TranscriptSentence: Hashable, Sendable {
    /// 在一份转写稿内稳定，供摘要引用（“这条待办来自 s42”）
    public var id: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// 被人工修改后保存引擎原文，未修改时为 nil；“恢复原文”就是把它写回 text
    public var original: String?

    public init(id: String, start: TimeInterval, end: TimeInterval, text: String, original: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.original = original
    }
}

/// 录音中没录到声音的一段（目前只有合盖），在转写稿里显示为不可编辑的标记行
public struct TranscriptGap: Hashable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var reason: GapReason

    public init(start: TimeInterval, end: TimeInterval, reason: GapReason) {
        self.start = start
        self.end = end
        self.reason = reason
    }
}

/// 文件中用 "kind" 区分条目：`{"kind": "sentence", ...}` / `{"kind": "gap", ...}`。
/// 编解码手写，因为合成的枚举编码是 `{"sentence": {...}}`，也不会把 original 写成 null
public enum TranscriptItem: Codable, Hashable, Sendable {
    case sentence(TranscriptSentence)
    case gap(TranscriptGap)

    public var start: TimeInterval {
        switch self {
        case let .sentence(s): s.start
        case let .gap(g): g.start
        }
    }

    public var end: TimeInterval {
        switch self {
        case let .sentence(s): s.end
        case let .gap(g): g.end
        }
    }

    private enum Kind: String, Codable { case sentence, gap }
    private enum CodingKeys: String, CodingKey { case kind, id, start, end, text, original, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let start = try c.decode(TimeInterval.self, forKey: .start)
        let end = try c.decode(TimeInterval.self, forKey: .end)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .sentence:
            self = .sentence(TranscriptSentence(
                id: try c.decode(String.self, forKey: .id), start: start, end: end,
                text: try c.decode(String.self, forKey: .text),
                original: try c.decodeIfPresent(String.self, forKey: .original)))
        case .gap:
            self = .gap(TranscriptGap(start: start, end: end, reason: try c.decode(GapReason.self, forKey: .reason)))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .sentence(s):
            try c.encode(Kind.sentence, forKey: .kind)
            try c.encode(s.id, forKey: .id)
            try c.encode(s.start, forKey: .start)
            try c.encode(s.end, forKey: .end)
            try c.encode(s.text, forKey: .text)
            try c.encode(s.original, forKey: .original)
        case let .gap(g):
            try c.encode(Kind.gap, forKey: .kind)
            try c.encode(g.start, forKey: .start)
            try c.encode(g.end, forKey: .end)
            try c.encode(g.reason, forKey: .reason)
        }
    }
}
