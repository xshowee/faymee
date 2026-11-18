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
