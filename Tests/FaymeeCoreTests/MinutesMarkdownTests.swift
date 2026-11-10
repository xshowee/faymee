import Foundation
import Testing
@testable import FaymeeCore

private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
/// 2026-11-10 10:00 北京时间
private let start = try! Date("2026-11-10T02:00:00Z", strategy: .iso8601)

private func meeting(title: String = "产品周会", duration: TimeInterval? = 52 * 60) -> Meeting {
    Meeting(id: "m1", title: title, startedAt: start, status: .done, recording: "recording.m4a", duration: duration)
}

private func minutes(_ sections: [MinutesSection]) -> Minutes {
    Minutes(model: "fake", template: "general", createdAt: start,
            source: MinutesSource(transcriptCreatedAt: start, textHash: "sha256:x"), sections: sections)
}

private func ref(_ seconds: TimeInterval) -> MinutesRef { MinutesRef(id: "s1", start: seconds) }

/// spec「复制与导出」的示例
private let example = minutes([
    MinutesSection(kind: .overview, title: "概要", items: [
        MinutesItem(id: "o1", text: "讨论了 v2.3 的发布时间，因支付接口未就绪推迟一周", refs: [ref(760)]),
    ]),
    MinutesSection(kind: .decisions, title: "决议", items: [
        MinutesItem(id: "d1", text: "v2.3 推迟到 11 月 24 日发布", refs: [ref(902)]),
    ]),
    MinutesSection(kind: .actions, title: "待办", items: [
        MinutesItem(id: "a1", text: "把报价单发给客户", owner: "张三", due: "下周三",
                    dueDate: CalendarDate("2026-11-18"), refs: [ref(1880.2)]),
    ]),
    MinutesSection(kind: .questions, title: "未决问题", items: [
        MinutesItem(id: "q1", text: "海外版的预算还没定", refs: [ref(2645)]),
    ]),
])

@Suite struct MinutesMarkdownTests {
    @Test func 与spec示例逐字一致() {
        #expect(example.markdown(meeting: meeting(), timeZone: shanghai) == """
        # 产品周会（2026-11-10 10:00，52 分钟）

        ## 概要
        - 讨论了 v2.3 的发布时间，因支付接口未就绪推迟一周（12:40）

        ## 决议
        - v2.3 推迟到 11 月 24 日发布（15:02）

        ## 待办
        - [ ] 张三：把报价单发给客户，截止 11 月 18 日（周三）（31:20）

        ## 未决问题
        - 海外版的预算还没定（44:05）

        """)
    }

    @Test func 已删除的不导出_手动添加和未找到出处的照常导出且不带标记() {
        let m = minutes([
            MinutesSection(kind: .overview, title: "概要", items: [
                MinutesItem(id: "o1", text: "讨论了发布时间", refs: [ref(760)], deleted: true),
                MinutesItem(id: "o2", text: "回顾了上周待办", refs: [ref(30)]),
                MinutesItem(id: "o3", text: "模型说了但找不到出处", refs: []),
                MinutesItem(id: "m1", text: "会后补充：周五再对一次", refs: [], origin: .manual),
            ]),
            MinutesSection(kind: .decisions, title: "决议", items: [
                MinutesItem(id: "d1", text: "删掉了", refs: [ref(902)], deleted: true),
            ]),
            MinutesSection(kind: .questions, title: "未决问题", items: []),
            MinutesSection(kind: .custom("commitments"), title: "我方承诺", items: [
                MinutesItem(id: "c1", text: "月底前给出排期", refs: [ref(61), ref(3725)]),
            ]),
        ])
        #expect(m.markdown(meeting: meeting(), timeZone: shanghai) == """
        # 产品周会（2026-11-10 10:00，52 分钟）

        ## 概要
        - 回顾了上周待办（00:30）
        - 模型说了但找不到出处
        - 会后补充：周五再对一次

        ## 决议
        无

        ## 未决问题
        无

        ## 我方承诺
        - 月底前给出排期（01:01、1:02:05）

        """)
    }

    @Test func 待办_负责人和截止时间缺哪项就不写哪项_只有原话时写原话() {
        let m = minutes([
            MinutesSection(kind: .actions, title: "待办", items: [
                MinutesItem(id: "a1", text: "整理会议记录", refs: [], origin: .manual),
                MinutesItem(id: "a2", text: "确认预算", owner: "李四", due: "月底前", refs: [ref(300)]),
                MinutesItem(id: "a3", text: "回复法务", owner: " ", due: "15 号前", refs: [ref(301)]),
                MinutesItem(id: "a4", text: "出排期", due: "  ", dueDate: CalendarDate("2026-11-22"), refs: [ref(302)]),
                MinutesItem(id: "a5", text: "年后复盘", owner: "王五", due: "下个月初",
                            dueDate: CalendarDate("2027-01-04"), refs: [ref(303)]),
            ]),
        ])
        #expect(m.markdown(meeting: meeting(), timeZone: shanghai) == """
        # 产品周会（2026-11-10 10:00，52 分钟）

        ## 待办
        - [ ] 整理会议记录
        - [ ] 李四：确认预算，截止月底前（05:00）
        - [ ] 回复法务，截止 15 号前（05:01）
        - [ ] 出排期，截止 11 月 22 日（周日）（05:02）
        - [ ] 王五：年后复盘，截止 2027 年 1 月 4 日（周一）（05:03）

        """)
    }

    @Test(arguments: [
        (nil, "# 周会（2026-11-10 10:00）"),
        (20, "# 周会（2026-11-10 10:00，不到 1 分钟）"),
        (90, "# 周会（2026-11-10 10:00，2 分钟）"),
        (3600, "# 周会（2026-11-10 10:00，1 小时）"),
        (3600 + 12 * 60 + 40, "# 周会（2026-11-10 10:00，1 小时 13 分钟）"),
    ] as [(TimeInterval?, String)])
    func 标题行_时长按分钟取整_超过一小时写小时_没有时长不写(duration: TimeInterval?, heading: String) {
        let md = minutes([]).markdown(meeting: meeting(title: "周会", duration: duration), timeZone: shanghai)
        #expect(md == heading + "\n")
    }

    @Test func 标题行的开始时间按传入的时区显示() {
        let md = minutes([]).markdown(meeting: meeting(duration: nil), timeZone: .gmt)
        #expect(md == "# 产品周会（2026-11-10 02:00）\n")
    }

    @Test func 附上转写稿全文_用修改后的文字_合盖空白单独一段() {
        let transcript = Transcript(engine: "fake", createdAt: start, hotwords: [], items: [
            .sentence(TranscriptSentence(id: "s1", start: 5, end: 9, text: "我们先过一下上周的待办")),
            .sentence(TranscriptSentence(id: "s2", start: 9.5, end: 14, text: "报价单周三前发给客户", original: "报价单周三钱发给客户")),
            .gap(TranscriptGap(start: 600, end: 780, reason: .lidClosed)),
            .sentence(TranscriptSentence(id: "s3", start: 3725, end: 3730, text: "好，今天就到这里")),
        ])
        let m = minutes([
            MinutesSection(kind: .overview, title: "概要", items: [
                MinutesItem(id: "o1", text: "回顾了上周待办", refs: [MinutesRef(id: "s1", start: 5)]),
            ]),
        ])
        #expect(m.markdown(meeting: meeting(), transcript: transcript, timeZone: shanghai) == """
        # 产品周会（2026-11-10 10:00，52 分钟）

        ## 概要
        - 回顾了上周待办（00:05）

        ## 转写稿

        [00:05] 我们先过一下上周的待办

        [00:09] 报价单周三前发给客户

        [10:00] 合盖，未录到声音（10:00–13:00，03:00）

        [1:02:05] 好，今天就到这里

        """)
    }

    @Test func 转写稿为空时只写标题和说明() {
        let transcript = Transcript(engine: "fake", createdAt: start, hotwords: [], items: [])
        #expect(minutes([]).markdown(meeting: meeting(duration: nil), transcript: transcript, timeZone: shanghai) == """
        # 产品周会（2026-11-10 10:00）

        ## 转写稿

        无

        """)
    }

    @Test func 文字里的换行换成空格_免得拆散列表或段落() {
        let transcript = Transcript(engine: "fake", createdAt: start, hotwords: [], items: [
            .sentence(TranscriptSentence(id: "s1", start: 5, end: 9, text: "第一行\n第二行")),
        ])
        let m = minutes([
            MinutesSection(kind: .actions, title: "待办", items: [
                MinutesItem(id: "a1", text: "发报价单\r\n 附上合同 ", owner: "张\n三", due: "下周\n三", refs: []),
            ]),
        ])
        #expect(m.markdown(meeting: meeting(duration: nil), transcript: transcript, timeZone: shanghai) == """
        # 产品周会（2026-11-10 10:00）

        ## 待办
        - [ ] 张 三：发报价单 附上合同，截止下周 三

        ## 转写稿

        [00:05] 第一行 第二行

        """)
    }
}

@Suite struct MinutesExportFileNameTests {
    @Test func 用会议标题作文件名() {
        #expect(meeting(title: "产品周会").minutesFileName == "产品周会.md")
    }

    @Test func 路径分隔符和冒号换成横线_两边空白去掉() {
        #expect(meeting(title: " 1/2 周会: 评审 ").minutesFileName == "1-2 周会- 评审.md")
    }

    @Test func 标题为空或只剩点时用默认名() {
        #expect(meeting(title: "  ").minutesFileName == "会议纪要.md")
        #expect(meeting(title: "..").minutesFileName == "会议纪要.md")
    }
}
