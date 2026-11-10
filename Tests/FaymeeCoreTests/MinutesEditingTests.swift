import Foundation
import Testing
@testable import FaymeeCore

private func minutes() -> Minutes {
    Minutes(model: "test", template: "general", createdAt: Date(timeIntervalSince1970: 0),
            source: MinutesSource(transcriptCreatedAt: Date(timeIntervalSince1970: 0), textHash: "sha256:x"),
            sections: [
                MinutesSection(kind: .overview, title: "概要", items: [
                    MinutesItem(id: "o1", text: "讨论了 v2.3 的发布时间", refs: [MinutesRef(id: "s1", start: 1)]),
                ]),
                MinutesSection(kind: .decisions, title: "决议", items: [
                    MinutesItem(id: "d1", text: "v2.3 推迟一周", refs: [MinutesRef(id: "s2", start: 5)]),
                ]),
                MinutesSection(kind: .actions, title: "待办", items: [
                    MinutesItem(id: "a1", text: "把报价单发给客户", owner: "张三", due: "下周三",
                                dueDate: CalendarDate("2026-11-18"), refs: [MinutesRef(id: "s3", start: 9)]),
                ]),
                MinutesSection(kind: .questions, title: "未决问题", items: []),
            ])
}

private func item(_ m: Minutes, _ id: String) -> MinutesItem? {
    m.sections.lazy.flatMap(\.items).first { $0.id == id }
}

/// 人工修改纪要：修改条目、恢复原文、删除与撤销、在节末新增
@Suite struct 编辑纪要 {
    @Test func 修改待办后保存模型原文_出处不变() {
        var m = minutes()
        let changed = m.edit(item: "a1", text: "把报价单和合同发给客户", owner: "李四", due: "下周五",
                             dueDate: CalendarDate("2026-11-20"))

        #expect(changed)
        #expect(item(m, "a1") == MinutesItem(
            id: "a1", text: "把报价单和合同发给客户", owner: "李四", due: "下周五", dueDate: CalendarDate("2026-11-20"),
            refs: [MinutesRef(id: "s3", start: 9)],
            original: MinutesItem.Original(text: "把报价单发给客户", owner: "张三", due: "下周三",
                                           dueDate: CalendarDate("2026-11-18"))))
        #expect(item(m, "o1")?.original == nil)
    }

    @Test func 再次修改时原文仍是模型原文_改回原样等于恢复() {
        var m = minutes()
        m.edit(item: "a1", text: "把报价单发给客户", owner: "李四", due: "下周三", dueDate: CalendarDate("2026-11-18"))
        m.edit(item: "a1", text: "把报价单发给客户", owner: "王五", due: "下周三", dueDate: CalendarDate("2026-11-18"))
        #expect(item(m, "a1")?.original?.owner == "张三")

        let changed = m.edit(item: "a1", text: "把报价单发给客户", owner: "张三", due: "下周三",
                             dueDate: CalendarDate("2026-11-18"))

        #expect(changed)
        #expect(m == minutes())
    }

    /// 文字去掉首尾空白，句中换行换成空格（一条一行）；清空文字不算修改（要去掉就删除）；
    /// 负责人、截止时间清空等于没有
    @Test func 输入去掉多余空白_清空文字不算修改() {
        var m = minutes()
        let empty = m.edit(item: "a1", text: "  \n ", owner: "李四")
        let same = m.edit(item: "a1", text: " 把报价单发给客户\n", owner: "张三 ", due: "下周三",
                          dueDate: CalendarDate("2026-11-18"))
        #expect(!empty)
        #expect(!same)
        #expect(m == minutes())

        m.edit(item: "a1", text: " 把报价单\n发给客户 ", owner: "  ", due: "", dueDate: nil)

        #expect(item(m, "a1")?.text == "把报价单 发给客户")
        #expect(item(m, "a1")?.owner == nil)
        #expect(item(m, "a1")?.due == nil)

        // 换行两边的空白和空行一起去掉，只留一个空格，和导出 Markdown 一致
        m.edit(item: "a1", text: "把报价单  \r\n\n  发给客户", owner: "张\n三")
        #expect(item(m, "a1")?.text == "把报价单 发给客户")
        #expect(item(m, "a1")?.owner == "张 三")
    }

    /// 负责人、截止时间只有待办有，其他节写盘时也不写这几项，改了读回来就不一样了
    @Test func 待办以外的条目只改文字() {
        var m = minutes()
        let ownerOnly = m.edit(item: "d1", text: "v2.3 推迟一周", owner: "张三", due: "下周三")
        #expect(!ownerOnly)

        m.edit(item: "d1", text: "v2.3 推迟到 11 月 24 日", owner: "张三", due: "下周三",
               dueDate: CalendarDate("2026-11-18"))

        #expect(item(m, "d1") == MinutesItem(id: "d1", text: "v2.3 推迟到 11 月 24 日",
                                             refs: [MinutesRef(id: "s2", start: 5)],
                                             original: MinutesItem.Original(text: "v2.3 推迟一周")))
    }

    @Test func 恢复原文后回到未修改状态() {
        var m = minutes()
        m.edit(item: "a1", text: "把合同发给客户", owner: nil, due: "月底", dueDate: nil)
        m.edit(item: "a1", text: "把合同发给法务", owner: "李四", due: "月底", dueDate: nil)
        let changed = m.restore(item: "a1")
        let again = m.restore(item: "a1")

        #expect(changed)
        #expect(!again)
        #expect(m == minutes())
    }

    /// 删除只做标记：不再显示，可以撤销
    @Test func 删除后不显示_撤销后回到原样() {
        var m = minutes()
        m.edit(item: "d1", text: "v2.3 推迟到 11 月 24 日")
        let edited = m
        let deleted = m.delete(item: "d1")
        let twice = m.delete(item: "d1")

        #expect(deleted)
        #expect(!twice)
        #expect(item(m, "d1")?.deleted == true)
        #expect(m.sections[1].visibleItems.isEmpty)

        let undone = m.undoDelete(item: "d1")
        let undoneTwice = m.undoDelete(item: "d1")

        #expect(undone)
        #expect(!undoneTwice)
        #expect(m == edited)
    }

    /// 已删除的条目不显示，也就不能改；要改先撤销
    @Test func 已删除的条目不能修改或恢复原文() {
        var m = minutes()
        m.edit(item: "d1", text: "v2.3 推迟到 11 月 24 日")
        m.delete(item: "d1")
        let before = m

        let edited = m.edit(item: "d1", text: "v2.3 不推迟")
        let restored = m.restore(item: "d1")

        #expect(!edited)
        #expect(!restored)
        #expect(m == before)
    }

    /// 手动新增的条目加在节末，没有出处，不算“未找到出处”
    @Test func 在节末新增手动条目() {
        var m = minutes()
        let id = m.addItem(to: .actions, text: " 准备演示环境\n", owner: "王五 ", due: "周五",
                           dueDate: CalendarDate("2026-11-13"))

        #expect(id == "m1")
        #expect(m.sections[2].items.map(\.id) == ["a1", "m1"])
        let added = item(m, "m1")
        #expect(added == MinutesItem(id: "m1", text: "准备演示环境", owner: "王五", due: "周五",
                                     dueDate: CalendarDate("2026-11-13"), refs: [], origin: .manual))
        #expect(added?.isUnsourced == false)
    }

    @Test func 新增时文字为空不加_待办以外不带负责人和截止时间() {
        var m = minutes()
        let empty = m.addItem(to: .questions, text: "  ")
        let missing = m.addItem(to: .custom("commitments"), text: "下周给报价")
        let question = m.addItem(to: .questions, text: "海外版预算", owner: "张三", due: "下周")

        #expect(empty == nil)
        #expect(missing == nil)
        #expect(question != nil)
        #expect(m.sections[3].items == [MinutesItem(id: question!, text: "海外版预算", refs: [], origin: .manual)])
    }

    /// 手动条目的 id 避开模型条目的形式（o1、a1、commitments-1…），删除后也不重复使用，
    /// 免得撤销删除时和新加的撞上
    @Test func 手动条目的编号不和模型条目重复_删除后也不复用() {
        var m = minutes()
        m.sections.append(MinutesSection(kind: .custom("m"), title: "自定义", items: [
            MinutesItem(id: "m-1", text: "模板节里的条目", refs: []),
        ]))
        let first = m.addItem(to: .overview, text: "补一条概要")
        m.delete(item: first!)
        let second = m.addItem(to: .decisions, text: "补一条决议")
        let third = m.addItem(to: .custom("m"), text: "补一条")

        let ids = m.sections.flatMap(\.items).map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect([first, second, third] == ["m1", "m2", "m3"])
    }

    /// 手动条目没有模型原文：修改它不算多一处修改，也没有“恢复原文”
    @Test func 修改手动条目不保存原文() {
        var m = minutes()
        let id = m.addItem(to: .decisions, text: "补一条决议")!
        m.edit(item: id, text: "补一条决议，周五前确认")
        let restored = m.restore(item: id)

        #expect(!restored)
        #expect(item(m, id) == MinutesItem(id: id, text: "补一条决议，周五前确认", refs: [], origin: .manual))
    }

    /// 重新生成前提示“会丢弃 N 处修改”的 N：修改、删除、新增各按条目算，同一条改几次、改了再删都只算一处；
    /// 加了又删的手动条目等于没加，不算
    @Test func 修改数按条目计() {
        var m = minutes()
        #expect(m.editCount == 0)

        m.edit(item: "o1", text: "讨论了发布时间")
        m.edit(item: "o1", text: "讨论了 v2.3 发布时间")
        #expect(m.editCount == 1)

        m.delete(item: "d1")
        #expect(m.editCount == 2)

        m.edit(item: "a1", text: "把报价单发给客户", owner: "李四", due: "下周三", dueDate: CalendarDate("2026-11-18"))
        m.delete(item: "a1")
        #expect(m.editCount == 3)

        let added = m.addItem(to: .questions, text: "海外版预算")!
        let removed = m.addItem(to: .questions, text: "写错了")!
        m.delete(item: removed)
        #expect(m.editCount == 4)

        m.restore(item: "o1")
        m.undoDelete(item: "d1")
        m.delete(item: added)
        #expect(m.editCount == 1)
    }

    /// 修改立即写盘：退出再打开，修改、删除、新增都还在，“恢复原文”仍能还原
    @Test func 改过的纪要写盘读回不变() throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("FaymeeCoreTests-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let meeting = try store.create(startedAt: Date(timeIntervalSince1970: 0))
        var m = minutes()
        m.edit(item: "a1", text: "把报价单和合同发给客户", owner: nil, due: "下周五", dueDate: nil)
        m.edit(item: "d1", text: "v2.3 推迟到 11 月 24 日")
        m.delete(item: "o1")
        m.addItem(to: .actions, text: "准备演示环境", owner: "王五")
        m.addItem(to: .questions, text: "海外版预算")
        try store.saveMinutes(m, for: meeting.id)

        var loaded = try #require(try MeetingStore(root: store.root).loadMinutes(meeting.id))

        #expect(loaded == m)
        #expect(loaded.editCount == 5)
        loaded.restore(item: "a1")
        #expect(item(loaded, "a1") == item(minutes(), "a1"))
    }
}
