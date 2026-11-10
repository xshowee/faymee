import Foundation

/// 人工修改转写稿：只改句子文字，不改时间，不合并、不拆分。
/// 改完由调用方用 `MeetingStore.saveTranscript` 整份原子写盘
extension Transcript {
    /// 重新转写会丢弃的人工修改处数，提示“会丢弃 N 处修改”用：改过文字的句子数加上改过说话人的句子数
    /// （`speakerEditCount`），同一句两样都改过算两处
    public var editCount: Int {
        sentences.count { $0.original != nil } + speakerEditCount
    }

    /// 重新转写前确认提示里的修改数。会区分说话人时同 `editCount`（名字按时间重合沿用到新说话人）；
    /// 不会区分时（开关关着、没有区分引擎）新稿没有说话人，再加上手动起了名字的说话人数。
    /// 声纹认出的名字不算：不是人工修改，下次区分还会认出来。
    /// 区分说话人这一步失败事先无法预知，那时名字同样丢失，说话人状态记为失败
    public func retranscribeEditCount(diarizes: Bool) -> Int {
        editCount + (diarizes ? 0 : speakers.count { $0.nameSource == .user && !$0.isUnnamed })
    }

    /// 把某句改成 text，第一次修改时把引擎原文存进 original。
    /// - 去掉首尾空白和换行；清空等于取消（不支持删句子）
    /// - 句中的换行换成空格：一句一行，复制全文也是一条一行
    /// - 改回引擎原文等于恢复原文，不再算修改
    /// 返回转写稿是否有变化，没有变化就不必写盘
    @discardableResult
    public mutating func edit(sentence id: String, to text: String) -> Bool {
        let text = text.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let i = sentenceIndex(id), case var .sentence(s) = items[i],
              text != s.text else { return false }
        let original = s.original ?? s.text
        s.original = text == original ? nil : original
        s.text = text
        items[i] = .sentence(s)
        return true
    }

    /// 恢复原文：把引擎原文写回 text，句子回到未修改状态。没改过的句子不变，返回 false
    @discardableResult
    public mutating func restore(sentence id: String) -> Bool {
        guard let i = sentenceIndex(id), case var .sentence(s) = items[i],
              let original = s.original else { return false }
        s.text = original
        s.original = nil
        items[i] = .sentence(s)
        return true
    }

    func sentenceIndex(_ id: String) -> Int? {
        items.firstIndex { if case let .sentence(s) = $0 { s.id == id } else { false } }
    }
}
