import Foundation

/// 人工修改转写稿：只改句子文字，不改时间，不合并、不拆分。
/// 改完由调用方用 `MeetingStore.saveTranscript` 整份原子写盘
extension Transcript {
    /// 人工修改过的句子数，重新转写前提示“会丢弃 N 处修改”用
    public var editCount: Int {
        sentences.count { $0.original != nil }
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

    private func sentenceIndex(_ id: String) -> Int? {
        items.firstIndex { if case let .sentence(s) = $0 { s.id == id } else { false } }
    }
}
