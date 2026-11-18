import Foundation

/// 转写稿的纠错信息（spec「存储」），存在 `Transcript.correction`。句子改了什么在各句的 `correction`
/// （纠错前的文字）里，下划线位置显示时由两者比对得出（`TextDiff`），不另存
public struct TranscriptCorrection: Codable, Hashable, Sendable {
    /// 纠错用的引擎：本机目录项 id（如 "llama/qwen3.5-4b-q4km"），或在线的 "<服务商>/<模型>"
    public var engine: String
    public var createdAt: Date
    /// 纠错时用的热词快照
    public var hotwords: [String]
    /// 数字建议（含已忽略的：重新纠错时据此不再出现同一建议）
    public var suggestions: [NumberSuggestion]
    /// 被护栏挡掉的条数，键是 `CorrectionRule.rawValue`。界面不显示，留作以后调整依据
    public var rejections: [String: Int]

    public init(engine: String, createdAt: Date, hotwords: [String], suggestions: [NumberSuggestion] = [],
                rejections: [String: Int] = [:]) {
        self.engine = engine
        self.createdAt = createdAt
        self.hotwords = hotwords
        self.suggestions = suggestions
        self.rejections = rejections
    }
}

/// 数字建议（spec「护栏」规则 7）：涉及数字的修改不写进正文，在句子旁显示「可能是『四月』？采纳 / 忽略」（ticket 02）
public struct NumberSuggestion: Codable, Hashable, Sendable {
    /// 句子 id
    public var sentence: String
    /// 句子里的原文，如「十月」
    public var from: String
    /// 建议的写法，如「四月」
    public var to: String
    /// 用户点了「忽略」：不再显示，重新纠错也不再出现同一建议
    public var ignored: Bool

    public init(sentence: String, from: String, to: String, ignored: Bool = false) {
        self.sentence = sentence
        self.from = from
        self.to = to
        self.ignored = ignored
    }

    /// 同一条建议（不看是否忽略）
    func isSame(as other: NumberSuggestion) -> Bool {
        sentence == other.sentence && from == other.from && to == other.to
    }
}

/// 一次纠错的结果，写盘前用 `Transcript.applyCorrection(_:)` 应用到最新的转写稿上
public struct CorrectionResult: Hashable, Sendable {
    /// 开始纠错时读的转写稿的 createdAt：最新的不一样说明重新转写过，结果作废
    public var transcriptCreatedAt: Date
    /// 送进模型时各句的文字和说话人：与最新的不同，这一句的修改跳过
    public var snapshot: [String: SentenceSnapshot]
    public var review: CorrectionReview
    public var engine: String
    public var createdAt: Date
    public var hotwords: [String]

    public struct SentenceSnapshot: Hashable, Sendable {
        public var text: String
        public var speaker: String?
    }

    public init(snapshot: Transcript, review: CorrectionReview, engine: String, createdAt: Date, hotwords: [String]) {
        transcriptCreatedAt = snapshot.createdAt
        self.snapshot = Dictionary(snapshot.sentences.map { ($0.id, SentenceSnapshot(text: $0.text, speaker: $0.speaker)) },
                                   uniquingKeysWith: { a, _ in a })
        self.review = review
        self.engine = engine
        self.createdAt = createdAt
        self.hotwords = hotwords
    }
}

public enum CorrectionError: LocalizedError, Equatable {
    /// 纠错期间重新转写过，结果作废
    case retranscribed
    /// 没有转写稿
    case noTranscript

    public var errorDescription: String? {
        switch self {
        case .retranscribed: "纠错期间转写稿重新生成了"
        case .noTranscript: "没有转写稿，无法纠错"
        }
    }
}

extension Transcript {
    /// 被纠错改过（还没撤销、没被手动修改接受）的句子数，状态行「已纠错 N 句」用
    public var correctedCount: Int {
        sentences.count { $0.correction != nil }
    }

    /// 把纠错结果应用到这份（写盘前重读的最新）转写稿上（spec「与手动编辑并发」）：
    /// - `createdAt` 与开始时不同（重新转写过）：抛 `CorrectionError.retranscribed`，什么都不改
    /// - 句子的文字、说话人与快照不同，或已被手动改过：这一句的修改和数字建议都跳过
    /// - 其余句子写进改后的文字，`correction` 记纠错前的文字（已有的保留，即最早的原文）
    /// - 纠错信息换成这次的；已忽略的建议保留，新结果里同一条建议不再出现；未忽略的旧建议被这次的替换
    public mutating func applyCorrection(_ result: CorrectionResult) throws {
        guard createdAt == result.transcriptCreatedAt else { throw CorrectionError.retranscribed }
        var skipped = Set<String>()
        for (i, item) in items.enumerated() {
            guard case var .sentence(s) = item else { continue }
            let unchanged = result.snapshot[s.id].map { $0.text == s.text && $0.speaker == s.speaker } ?? false
            guard unchanged, s.original == nil else {
                skipped.insert(s.id)
                continue
            }
            guard let text = result.review.texts[s.id], text != s.text else { continue }
            s.correction = s.correction ?? s.text
            s.text = text
            items[i] = .sentence(s)
        }
        let ignored = (correction?.suggestions ?? []).filter(\.ignored)
        let fresh = result.review.suggestions.filter { new in
            !skipped.contains(new.sentence) && !ignored.contains { $0.isSame(as: new) }
        }
        correction = TranscriptCorrection(engine: result.engine, createdAt: result.createdAt, hotwords: result.hotwords,
                                          suggestions: ignored + fresh, rejections: result.review.rejections)
    }

    /// 撤销一句的纠错：`text` 换回纠错前的文字，清掉 `correction`。没纠错过的句子返回 false
    @discardableResult
    public mutating func undoCorrection(sentence id: String) -> Bool {
        guard let i = sentenceIndex(id), case var .sentence(s) = items[i], let before = s.correction else { return false }
        s.text = before
        s.correction = nil
        items[i] = .sentence(s)
        return true
    }

    /// 撤销全部纠错：所有纠错过的句子换回纠错前的文字。纠错信息（建议、挡掉的条数）保留。
    /// 没有可撤销的返回 false
    @discardableResult
    public mutating func undoAllCorrections() -> Bool {
        var changed = false
        for s in sentences where s.correction != nil {
            changed = undoCorrection(sentence: s.id) || changed
        }
        return changed
    }
}
