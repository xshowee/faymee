import Foundation

/// 一场会议的纪要，存为 minutes.json，只由生成和编辑写入。
/// 生成时依据的是哪一份转写稿记在 `source` 里，用来派生“转写稿已重新生成”“转写稿有修改”的提示
public struct Minutes: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// 生成这份纪要的模型，如 "mlx/qwen3-8b-4bit"
    public var model: String
    /// 模板的标识，如 "weekly"。取值由模板定义（02）
    public var template: String
    public var createdAt: Date
    public var source: MinutesSource
    /// 按模板定义的顺序排列。空的节也保留
    public var sections: [MinutesSection]

    public init(version: Int = Minutes.currentVersion, model: String, template: String, createdAt: Date,
                source: MinutesSource, sections: [MinutesSection]) {
        self.version = version
        self.model = model
        self.template = template
        self.createdAt = createdAt
        self.source = source
        self.sections = sections
    }
}

/// 生成时用的转写稿快照
public struct MinutesSource: Codable, Hashable, Sendable {
    /// 对应 `Transcript.createdAt`：与当前转写稿不同，说明被重新转写过，句子 id 已不可信
    public var transcriptCreatedAt: Date
    /// 对应 `Transcript.textHash`：只有它不同，说明句子被修改过
    public var textHash: String

    public init(transcriptCreatedAt: Date, textHash: String) {
        self.transcriptCreatedAt = transcriptCreatedAt
        self.textHash = textHash
    }
}

/// 出处：转写稿里的一句。`start` 是该句生成时相对录音的秒数，
/// 转写稿被重新转写后 `id` 会指向别的句子，这时改用 `start` 跳转
public struct MinutesRef: Codable, Hashable, Sendable {
    public var id: String
    public var start: TimeInterval

    public init(id: String, start: TimeInterval) {
        self.id = id
        self.start = start
    }
}

public enum MinutesSectionKind: Hashable, Sendable {
    case overview, decisions, actions, questions
    /// 模板额外定义的节，用 key 区分，如 "commitments"
    case custom(String)
}

/// 纪要的一节。文件中 `kind` 为 overview/decisions/actions/questions/custom，只有 custom 带 `key`
public struct MinutesSection: Codable, Hashable, Sendable {
    public var kind: MinutesSectionKind
    public var title: String
    public var items: [MinutesItem]

    public init(kind: MinutesSectionKind, title: String, items: [MinutesItem]) {
        self.kind = kind
        self.title = title
        self.items = items
    }

    private enum Kind: String, Codable { case overview, decisions, actions, questions, custom }
    private enum CodingKeys: String, CodingKey { case kind, key, title, items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .overview: kind = .overview
        case .decisions: kind = .decisions
        case .actions: kind = .actions
        case .questions: kind = .questions
        case .custom: kind = .custom(try c.decode(String.self, forKey: .key))
        }
        title = try c.decode(String.self, forKey: .title)
        items = try c.decode([MinutesItem].self, forKey: .items)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch kind {
        case .overview: try c.encode(Kind.overview, forKey: .kind)
        case .decisions: try c.encode(Kind.decisions, forKey: .kind)
        case .actions: try c.encode(Kind.actions, forKey: .kind)
        case .questions: try c.encode(Kind.questions, forKey: .kind)
        case let .custom(key):
            try c.encode(Kind.custom, forKey: .kind)
            try c.encode(key, forKey: .key)
        }
        try c.encode(title, forKey: .title)
        try c.encode(items.map { ItemEncoding(item: $0, isAction: kind == .actions) }, forKey: .items)
    }
}

/// 纪要的一条。`owner`、`due`、`dueDate` 只对待办节的条目有意义：
/// 写盘时只有待办节的条目写出这三个字段（为空时写 null），其他节的条目不写
public struct MinutesItem: Decodable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable {
        /// 模型生成
        case model
        /// 用户手动新增，没有出处
        case manual
    }

    /// 第一次人工修改时保存的模型原文，“恢复原文”就是把它写回去
    public struct Original: Decodable, Hashable, Sendable {
        public var text: String
        public var owner: String?
        public var due: String?
        public var dueDate: CalendarDate?

        public init(text: String, owner: String? = nil, due: String? = nil, dueDate: CalendarDate? = nil) {
            self.text = text
            self.owner = owner
            self.due = due
            self.dueDate = dueDate
        }
    }

    public var id: String
    public var text: String
    /// 负责人，只能从文字里推断，可以为空
    public var owner: String?
    /// 截止时间的原话，如“下周三”
    public var due: String?
    /// 按会议日期换算出的截止日期，换算不出来时为空
    public var dueDate: CalendarDate?
    /// 写盘前已校验过，都存在于生成时的转写稿中
    public var refs: [MinutesRef]
    public var origin: Origin
    public var original: Original?
    /// 删除只做标记，方便撤销和统计修改数
    public var deleted: Bool

    public init(id: String, text: String, owner: String? = nil, due: String? = nil, dueDate: CalendarDate? = nil,
                refs: [MinutesRef], origin: Origin = .model, original: Original? = nil, deleted: Bool = false) {
        self.id = id
        self.text = text
        self.owner = owner
        self.due = due
        self.dueDate = dueDate
        self.refs = refs
        self.origin = origin
        self.original = original
        self.deleted = deleted
    }

    /// “未找到出处”：模型给的出处在转写稿里都找不到。条目保留，由用户判断是否删除。
    /// 手动添加的条目本来就没有出处，不算
    public var isUnsourced: Bool { origin == .model && refs.isEmpty }

    fileprivate enum CodingKeys: String, CodingKey {
        case id, text, owner, due, dueDate, refs, origin, original, deleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        dueDate = try c.decodeIfPresent(CalendarDate.self, forKey: .dueDate)
        refs = try c.decode([MinutesRef].self, forKey: .refs)
        origin = try c.decode(Origin.self, forKey: .origin)
        original = try c.decodeIfPresent(Original.self, forKey: .original)
        deleted = try c.decode(Bool.self, forKey: .deleted)
    }
}

/// 条目的编码要看它在哪一节，所以由节来包一层
private struct ItemEncoding: Encodable {
    let item: MinutesItem
    let isAction: Bool

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: MinutesItem.CodingKeys.self)
        try c.encode(item.id, forKey: .id)
        try c.encode(item.text, forKey: .text)
        if isAction {
            try c.encode(item.owner, forKey: .owner)
            try c.encode(item.due, forKey: .due)
            try c.encode(item.dueDate, forKey: .dueDate)
        }
        try c.encode(item.refs, forKey: .refs)
        try c.encode(item.origin, forKey: .origin)
        if let original = item.original {
            try c.encode(OriginalEncoding(original: original, isAction: isAction), forKey: .original)
        } else {
            try c.encodeNil(forKey: .original)
        }
        try c.encode(item.deleted, forKey: .deleted)
    }
}

private struct OriginalEncoding: Encodable {
    let original: MinutesItem.Original
    let isAction: Bool

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: MinutesItem.CodingKeys.self)
        try c.encode(original.text, forKey: .text)
        if isAction {
            try c.encode(original.owner, forKey: .owner)
            try c.encode(original.due, forKey: .due)
            try c.encode(original.dueDate, forKey: .dueDate)
        }
    }
}

/// 不带时间和时区的公历日期，文件中写成 "2026-11-18"。
/// 不用 Date：截止日期是“哪一天”，换时区不该变成前一天或后一天
public struct CalendarDate: Codable, Hashable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// 不是合法日期（如 2 月 30 日）时返回 nil
    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month) else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        guard (1...days).contains(day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// 只接受 "YYYY-MM-DD"，不是合法日期时返回 nil
    public init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let date = CalendarDate(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "不是合法日期：\(s)")
        }
        self = date
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

extension String {
    /// 一条一行：每行去掉两边空白、丢掉空行，再用一个空格连起来（条目、一句话要留在同一行或同一段里）；
    /// 什么都不剩时为 nil。人工修改纪要和导出 Markdown 共用
    var singleLine: String? {
        let s = components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return s.isEmpty ? nil : s
    }
}
