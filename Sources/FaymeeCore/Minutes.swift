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
    /// 模型从称呼里推断的说话人姓名，对应生成时的 `source.speakersCreatedAt`。
    /// 按说话人 id 排列，每个说话人最多一条；被忽略的也留着，重新生成时继承。
    /// 写盘时为空就不写（v0.3 的纪要没有这个字段）
    public var nameSuggestions: [NameSuggestion]

    public init(version: Int = Minutes.currentVersion, model: String, template: String, createdAt: Date,
                source: MinutesSource, sections: [MinutesSection], nameSuggestions: [NameSuggestion] = []) {
        self.version = version
        self.model = model
        self.template = template
        self.createdAt = createdAt
        self.source = source
        self.sections = sections
        self.nameSuggestions = nameSuggestions
    }

    private enum CodingKeys: String, CodingKey {
        case version, model, template, createdAt, source, sections, nameSuggestions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        model = try c.decode(String.self, forKey: .model)
        template = try c.decode(String.self, forKey: .template)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        source = try c.decode(MinutesSource.self, forKey: .source)
        sections = try c.decode([MinutesSection].self, forKey: .sections)
        nameSuggestions = try c.decodeIfPresent([NameSuggestion].self, forKey: .nameSuggestions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(model, forKey: .model)
        try c.encode(template, forKey: .template)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(source, forKey: .source)
        try c.encode(sections, forKey: .sections)
        if !nameSuggestions.isEmpty { try c.encode(nameSuggestions, forKey: .nameSuggestions) }
    }
}

/// 姓名建议：“说话人 2 可能是王总？”。只给生成时还没命名的说话人，
/// 至少一处出处原句里字面包含这个名字
public struct NameSuggestion: Codable, Hashable, Sendable {
    /// 说话人 id，如 "spk2"
    public var speaker: String
    public var name: String
    /// 含这个称呼的句子，最多 3 个，点击跳转同纪要条目的出处
    public var refs: [MinutesRef]
    /// 用户点了“忽略”：不再显示，重新生成时同一说话人同一名字也不再出现
    public var ignored: Bool

    public init(speaker: String, name: String, refs: [MinutesRef], ignored: Bool = false) {
        self.speaker = speaker
        self.name = name
        self.refs = refs
        self.ignored = ignored
    }
}

/// 生成时用的转写稿快照
public struct MinutesSource: Codable, Hashable, Sendable {
    /// 对应 `Transcript.createdAt`：与当前转写稿不同，说明被重新转写过，句子 id 已不可信
    public var transcriptCreatedAt: Date
    /// 对应 `Transcript.textHash`：只有它不同，说明句子被修改过
    public var textHash: String
    /// 对应 `Transcript.speakersCreatedAt`，生成时没区分过说话人为 nil（不写）。
    /// 与当前转写稿不同说明重新区分过，说话人编号已重排：负责人的说话人关联、姓名建议都失效。
    /// 不影响同步状态（`sync(with:)`）
    public var speakersCreatedAt: Date?

    public init(transcriptCreatedAt: Date, textHash: String, speakersCreatedAt: Date? = nil) {
        self.transcriptCreatedAt = transcriptCreatedAt
        self.textHash = textHash
        self.speakersCreatedAt = speakersCreatedAt
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
        public var ownerSpeaker: String?

        public init(text: String, owner: String? = nil, due: String? = nil, dueDate: CalendarDate? = nil,
                    ownerSpeaker: String? = nil) {
            self.text = text
            self.owner = owner
            self.due = due
            self.dueDate = dueDate
            self.ownerSpeaker = ownerSpeaker
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
    /// 负责人是哪个说话人（说话人 id）：模型给的负责人与输入里某个说话人的显示名完全相同时记下。
    /// 关联有效时负责人显示该说话人当前的名字（见 `Minutes.displayedOwner(of:transcript:)`），
    /// `owner` 留着生成时的文字。手动改负责人后清掉。只有待办有，没有时不写
    public var ownerSpeaker: String?
    /// 写盘前已校验过，都存在于生成时的转写稿中
    public var refs: [MinutesRef]
    public var origin: Origin
    public var original: Original?
    /// 删除只做标记，方便撤销和统计修改数
    public var deleted: Bool

    public init(id: String, text: String, owner: String? = nil, due: String? = nil, dueDate: CalendarDate? = nil,
                ownerSpeaker: String? = nil, refs: [MinutesRef], origin: Origin = .model, original: Original? = nil,
                deleted: Bool = false) {
        self.id = id
        self.text = text
        self.owner = owner
        self.due = due
        self.dueDate = dueDate
        self.ownerSpeaker = ownerSpeaker
        self.refs = refs
        self.origin = origin
        self.original = original
        self.deleted = deleted
    }

    /// “未找到出处”：模型给的出处在转写稿里都找不到。条目保留，由用户判断是否删除。
    /// 手动添加的条目本来就没有出处，不算
    public var isUnsourced: Bool { origin == .model && refs.isEmpty }

    fileprivate enum CodingKeys: String, CodingKey {
        case id, text, owner, due, dueDate, ownerSpeaker, refs, origin, original, deleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        dueDate = try c.decodeIfPresent(CalendarDate.self, forKey: .dueDate)
        ownerSpeaker = try c.decodeIfPresent(String.self, forKey: .ownerSpeaker)
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
            try c.encodeIfPresent(item.ownerSpeaker, forKey: .ownerSpeaker)
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
            try c.encodeIfPresent(original.ownerSpeaker, forKey: .ownerSpeaker)
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
