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

    private static func canAdopt(_ suggestion: NumberSuggestion, in s: TranscriptSentence) -> Bool {
        s.original == nil && !suggestion.from.isEmpty && s.text.components(separatedBy: suggestion.from).count == 2
    }
}
