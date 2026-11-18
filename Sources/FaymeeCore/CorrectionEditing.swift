import Foundation

/// 转写稿里看得见、撤得掉（spec「存储」「界面」）：下划线位置、数字建议的采纳与忽略、重新纠错前的复位。
/// 撤销一句、撤销全部见 `TranscriptCorrection.swift`
extension TranscriptSentence {
    /// 改后文字（`text`）里纠错改过的位置（`Character` 下标），加下划线用。由纠错前后文字比对得出，不另存：
    /// 换掉的、补进去的字（含标点）都画；删掉的字在 `text` 里没有，不画。没纠错过时为空。
    /// 只删了字的句子也算纠错过（`correction != nil`），照样能撤销，只是没有下划线
    public var correctionHighlights: [Range<Int>] {
        guard let before = correction else { return [] }
        return TextDiff(from: before, to: text).segments.map(\.afterRange).filter { !$0.isEmpty }
    }
}

extension Transcript {
    /// 要在句子旁显示的数字建议，键是句子 id：没忽略、那句没被手动改过、原文在句子里恰好出现一次的。
    /// 采纳后句子里不再有原文，建议自然不显示；撤销那句后又显示出来（建议本身不删）
    public var numberSuggestions: [String: [NumberSuggestion]] {
        guard let all = correction?.suggestions, !all.isEmpty else { return [:] }
        let byID = Dictionary(sentences.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return Dictionary(grouping: all.filter { s in
            !s.ignored && byID[s.sentence].map { Self.canAdopt(s, in: $0) } == true
        }, by: \.sentence)
    }

    /// 采纳数字建议：把句子里那一处原文换成建议的写法，按一处纠错处理（`correction` 记纠错前的文字，
    /// 可撤销），不算人工修改。建议不显示时（见 `numberSuggestions`）不改，返回 false
    @discardableResult
    public mutating func adopt(_ suggestion: NumberSuggestion) -> Bool {
        guard !suggestion.ignored, let i = sentenceIndex(suggestion.sentence), case var .sentence(s) = items[i],
              Self.canAdopt(suggestion, in: s), let range = s.text.range(of: suggestion.from) else { return false }
        s.correction = s.correction ?? s.text
        s.text.replaceSubrange(range, with: suggestion.to)
        items[i] = .sentence(s)
        return true
    }

    /// 忽略数字建议：标记后不再显示，重新纠错也不再出现同一建议（`applyCorrection` 保留已忽略的）。
    /// 没有这条建议或已忽略过时返回 false
    @discardableResult
    public mutating func ignore(_ suggestion: NumberSuggestion) -> Bool {
        guard let i = correction?.suggestions.firstIndex(where: { $0.isSame(as: suggestion) && !$0.ignored })
        else { return false }
        correction?.suggestions[i].ignored = true
        return true
    }

    /// 「重新纠错」开跑前的复位：撤销全部纠错（含采纳过的建议），清掉未忽略的建议；手动改过的句子不动。
    /// 要在入队前写盘：纠错开始时读的就是复位后的转写稿。没有变化时返回 false
    @discardableResult
    public mutating func resetForRecorrection() -> Bool {
        var changed = undoAllCorrections()
        if let suggestions = correction?.suggestions, suggestions.contains(where: { !$0.ignored }) {
            correction?.suggestions = suggestions.filter(\.ignored)
            changed = true
        }
        return changed
    }

    private static func canAdopt(_ suggestion: NumberSuggestion, in s: TranscriptSentence) -> Bool {
        s.original == nil && !suggestion.from.isEmpty && s.text.occurrences(of: suggestion.from) == 1
    }
}

/// 转写稿菜单里的「纠错 / 重新纠错」（spec「界面」）。手动的随时能点，不看「纠错转写稿」开关和纪要模型
/// 是否就绪（没就绪时排队）
public struct CorrectionMenuItem: Hashable, Sendable {
    /// 纠错过（撤销全部后也算）是「重新纠错」，否则「纠错」
    public let title: String
    /// 「重新纠错」：入队前先 `resetForRecorrection()` 并写盘
    public let resets: Bool
    public let isEnabled: Bool

    /// - isEditable: 转写稿能改（不在重新转写中）
    public init(transcript: Transcript?, state: CorrectionState?, isEditable: Bool) {
        resets = transcript?.correction != nil
        title = resets ? "重新纠错" : "纠错"
        let busy = state?.status == .queued || state?.status == .running
        isEnabled = isEditable && !busy && transcript?.sentences.isEmpty == false
    }
}
