import Foundation

/// 人工修改纪要：改条目的文字、负责人、截止时间，恢复原文，删除与撤销，在节末新增。
/// 改完由调用方用 `MeetingStore.saveMinutes` 整份原子写盘
extension Minutes {
    /// 人工改动的处数（修改 + 删除 + 新增），重新生成、切换模板前提示“会丢弃 N 处修改”用，
    /// 为 0 时重新转写后可以自动重新生成。按条目计：同一条改几次、改了又删都只算一处；
    /// 加了又删的手动条目等于没加，不算
    public var editCount: Int {
        sections.reduce(0) { n, section in
            n + section.items.count { item in
                switch item.origin {
                case .model: item.original != nil || item.deleted
                case .manual: !item.deleted
                }
            }
        }
    }

    /// 把条目改成给定内容（四项整体替换），第一次修改时把模型原文存进 original。
    /// 手动添加的条目没有模型原文，直接改
    /// - 去掉首尾空白，句中换行换成空格；负责人、截止时间清空等于没有
    /// - 待办以外的条目只改文字：负责人、截止时间只有待办有，其他节写盘时也不写
    /// - 文字清空不算修改（要去掉就删除）
    /// - 改回模型原文等于恢复原文，不再算修改
    /// - 已删除的条目不能改，要改先撤销删除
    /// 返回纪要是否有变化，没有变化就不必写盘
    @discardableResult
    public mutating func edit(item id: String, text: String, owner: String? = nil, due: String? = nil,
                              dueDate: CalendarDate? = nil) -> Bool {
        guard let text = normalized(text), let (s, i) = itemIndex(id, deleted: false) else { return false }
        var item = sections[s].items[i]
        let isAction = sections[s].kind == .actions
        let content = isAction
            ? MinutesItem.Original(text: text, owner: owner.flatMap(normalized), due: due.flatMap(normalized),
                                   dueDate: dueDate)
            : MinutesItem.Original(text: text)
        guard content != item.content else { return false }
        let original = item.original ?? item.content
        item.text = content.text
        item.owner = content.owner
        item.due = content.due
        item.dueDate = content.dueDate
        item.original = item.origin == .manual || content == original ? nil : original
        sections[s].items[i] = item
        return true
    }

    /// 在某节末尾手动新增条目，没有出处。文字为空或没有这一节时不加，返回 nil；否则返回新条目的 id。
    /// id 为 m1、m2…：避开模型条目的形式（o1、a1、commitments-1…），也不复用已删除条目的编号
    @discardableResult
    public mutating func addItem(to kind: MinutesSectionKind, text: String, owner: String? = nil,
                                 due: String? = nil, dueDate: CalendarDate? = nil) -> String? {
        guard let text = normalized(text), let s = sections.firstIndex(where: { $0.kind == kind }) else { return nil }
        let used = sections.flatMap(\.items).compactMap { item -> Int? in
            let n = item.id.dropFirst()
            guard item.id.first == "m", !n.isEmpty, n.allSatisfy(\.isASCII), n.allSatisfy(\.isNumber) else { return nil }
            return Int(n)
        }
        let id = "m\((used.max() ?? 0) + 1)"
        let isAction = kind == .actions
        sections[s].items.append(MinutesItem(
            id: id, text: text, owner: isAction ? owner.flatMap(normalized) : nil,
            due: isAction ? due.flatMap(normalized) : nil, dueDate: isAction ? dueDate : nil,
            refs: [], origin: .manual))
        return id
    }

    /// 恢复原文：把模型原文写回文字、负责人、截止时间，条目回到未修改状态。
    /// 没改过的、已删除的条目不变，返回 false
    @discardableResult
    public mutating func restore(item id: String) -> Bool {
        guard let (s, i) = itemIndex(id, deleted: false), let original = sections[s].items[i].original else { return false }
        sections[s].items[i].text = original.text
        sections[s].items[i].owner = original.owner
        sections[s].items[i].due = original.due
        sections[s].items[i].dueDate = original.dueDate
        sections[s].items[i].original = nil
        return true
    }

    /// 删除条目：只做标记，不再显示，可以撤销。已删除的返回 false
    @discardableResult
    public mutating func delete(item id: String) -> Bool {
        guard let (s, i) = itemIndex(id, deleted: false) else { return false }
        sections[s].items[i].deleted = true
        return true
    }

    /// 撤销删除，条目回到删除前的样子（修改仍在）。没删除的返回 false
    @discardableResult
    public mutating func undoDelete(item id: String) -> Bool {
        guard let (s, i) = itemIndex(id, deleted: true) else { return false }
        sections[s].items[i].deleted = false
        return true
    }

    /// 条目所在的节和位置；只找删除状态为 `deleted` 的
    private func itemIndex(_ id: String, deleted: Bool) -> (Int, Int)? {
        for s in sections.indices {
            if let i = sections[s].items.firstIndex(where: { $0.id == id }) {
                return sections[s].items[i].deleted == deleted ? (s, i) : nil
            }
        }
        return nil
    }
}

extension MinutesItem {
    /// 可以人工修改的部分，形状和 `original` 一样
    fileprivate var content: Original { Original(text: text, owner: owner, due: due, dueDate: dueDate) }
}

/// 一条一行：换行换成空格，去掉首尾空白；什么都不剩时为 nil
private func normalized(_ s: String) -> String? {
    let s = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}
