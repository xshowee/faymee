import Foundation
import Testing
@testable import FaymeeCore

private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
/// 2026-11-10 10:00 北京时间，周二
private let meetingStart = try! Date("2026-11-10T02:00:00Z", strategy: .iso8601)

private func action(due: String?, dueDate: String?) -> MinutesItem {
    MinutesItem(id: "a1", text: "把报价单发给客户", owner: "张三", due: due,
                dueDate: dueDate.flatMap { CalendarDate($0) }, refs: [])
}

@Suite struct MinutesDueTextTests {
    @Test func 原话和换算日期都有时一起显示_日期带星期() {
        #expect(action(due: "下周三", dueDate: "2026-11-18").dueText(meetingStartedAt: meetingStart, timeZone: shanghai)
            == "下周三（11 月 18 日，周三）")
    }

    @Test func 换算不出来时只显示原话() {
        #expect(action(due: "月底前", dueDate: nil).dueText(meetingStartedAt: meetingStart, timeZone: shanghai)
            == "月底前")
    }

    @Test func 只有日期时显示日期和星期() {
        #expect(action(due: nil, dueDate: "2026-11-22").dueText(meetingStartedAt: meetingStart, timeZone: shanghai)
            == "11 月 22 日（周日）")
    }

    @Test func 都没有时为nil() {
        #expect(action(due: nil, dueDate: nil).dueText(meetingStartedAt: meetingStart, timeZone: shanghai) == nil)
    }

    @Test func 和会议不在同一年时日期带年份() {
        #expect(action(due: "下个月初", dueDate: "2027-01-04").dueText(meetingStartedAt: meetingStart, timeZone: shanghai)
            == "下个月初（2027 年 1 月 4 日，周一）")
    }

    @Test func 年份按会议所在时区判断() {
        // 北京时间 2027-01-01 01:00，UTC 还是 2026 年
        let newYear = try! Date("2026-12-31T17:00:00Z", strategy: .iso8601)
        #expect(action(due: nil, dueDate: "2027-01-08").dueText(meetingStartedAt: newYear, timeZone: shanghai)
            == "1 月 8 日（周五）")
        #expect(action(due: nil, dueDate: "2027-01-08").dueText(meetingStartedAt: newYear, timeZone: .gmt)
            == "2027 年 1 月 8 日（周五）")
    }

    @Test func 原话两边的空白不显示_空白原话当作没有() {
        #expect(action(due: "  下周三 ", dueDate: nil).dueText(meetingStartedAt: meetingStart, timeZone: shanghai)
            == "下周三")
        #expect(action(due: " ", dueDate: nil).dueText(meetingStartedAt: meetingStart, timeZone: shanghai) == nil)
    }

    @Test func 日期单独显示供导出等复用() {
        let d = CalendarDate("2026-11-18")!
        #expect(d.displayText(meetingStartedAt: meetingStart, timeZone: shanghai) == "11 月 18 日（周三）")
        #expect(d.weekdayText == "周三")
        #expect(CalendarDate("2028-02-29")!.weekdayText == "周二")
    }
}

private let transcript = Transcript(
    engine: "apple/speechanalyzer", createdAt: meetingStart.addingTimeInterval(3600), hotwords: [],
    items: [
        .sentence(TranscriptSentence(id: "s1", start: 195.4, end: 199, text: "支付接口还没准备好")),
        .gap(TranscriptGap(start: 200, end: 260, reason: .lidClosed)),
        .sentence(TranscriptSentence(id: "s2", start: 3723, end: 3730, text: "那就推迟一周",
                                     original: "那就推迟一州")),
    ])

@Suite struct MinutesRefChipTests {
    @Test func 同步时显示该句时间_悬停显示原句() {
        let chip = MinutesRef(id: "s1", start: 195.4).chip(in: transcript, sync: .inSync)
        #expect(chip.label == "03:15")
        #expect(chip.hint == "支付接口还没准备好")
        #expect(chip.target == MinutesRefTarget(time: 195.4, sentenceID: "s1", quote: "支付接口还没准备好"))
    }

    @Test func 转写稿句子被修改时悬停显示修改后的文字_超过一小时显示小时() {
        let chip = MinutesRef(id: "s2", start: 3723).chip(in: transcript, sync: .edited)
        #expect(chip.label == "1:02:03")
        #expect(chip.hint == "那就推迟一周")
    }

    @Test func 重新转写后按生成时的时间显示和跳转_原句不可用() {
        // 重转后 s1 指向别的句子：不能再按 id 取文字和时间
        let chip = MinutesRef(id: "s1", start: 3725).chip(in: transcript, sync: .retranscribed)
        #expect(chip.label == "1:02:05")
        #expect(chip.hint == "转写稿已更新，原句不可用")
        #expect(chip.target.time == 3725)
        #expect(chip.target.sentenceID == "s2")
    }

    /// 详情页用 MinutesRefResolver 一次解析整份纪要：同步状态按纪要的 source 算，
    /// 改条目不用重建，转写稿或 source 变了才要重建
    @Test func 解析器按纪要和转写稿算出同步状态_只在source或转写稿变了时过期() {
        var minutes = Minutes(model: "fake", template: "general", createdAt: meetingStart,
                              source: MinutesSource(transcriptCreatedAt: transcript.createdAt,
                                                    textHash: transcript.textHash),
                              sections: [])
        let resolver = MinutesRefResolver(minutes: minutes, transcript: transcript, meeting: nil)
        #expect(resolver.sync == .inSync)
        #expect(resolver.chip(MinutesRef(id: "s2", start: 3723)).hint == "那就推迟一周")

        minutes.template = "weekly"
        #expect(resolver.isCurrent(minutes: minutes, transcript: transcript, meeting: nil))
        var edited = transcript
        edited.items[0] = .sentence(TranscriptSentence(id: "s1", start: 195.4, end: 199, text: "支付接口准备好了"))
        #expect(!resolver.isCurrent(minutes: minutes, transcript: edited, meeting: nil))
        #expect(MinutesRefResolver(minutes: minutes, transcript: edited, meeting: nil).sync == .edited)
        #expect(!resolver.isCurrent(minutes: nil, transcript: transcript, meeting: nil))
        #expect(resolver.updated(minutes: minutes, transcript: edited, meeting: nil).sync == .edited)
        #expect(resolver.updated(minutes: minutes, transcript: transcript, meeting: nil).isCurrent(minutes: minutes,
                                                                                    transcript: transcript,
                                                                                    meeting: nil))

        let empty = MinutesRefResolver(minutes: nil, transcript: nil, meeting: nil)
        #expect(empty.sync == .inSync)
        #expect(empty.chip(MinutesRef(id: "s1", start: 195.4)).hint == "转写稿不可用，原句无法显示")
    }

    @Test func 没有转写稿时按生成时的时间跳转_不定位句子() {
        let chip = MinutesRef(id: "s1", start: 195.4).chip(in: nil, sync: .inSync)
        #expect(chip.label == "03:15")
        #expect(chip.hint == "转写稿不可用，原句无法显示")
        #expect(chip.target == MinutesRefTarget(time: 195.4, sentenceID: nil, quote: nil))
    }
}

@Suite struct MinutesSectionDisplayTests {
    @Test func 已删除的条目不显示_全删光的节和空节一样显示无() {
        let section = MinutesSection(kind: .decisions, title: "决议", items: [
            MinutesItem(id: "d1", text: "推迟一周", refs: [MinutesRef(id: "s2", start: 3723)]),
            MinutesItem(id: "d2", text: "不做海外版", refs: [], deleted: true),
            MinutesItem(id: "d3", text: "预算另议", refs: []),
        ])
        #expect(section.visibleItems.map(\.id) == ["d1", "d3"])
        #expect(section.visibleItems.map(\.isUnsourced) == [false, true])

        var allDeleted = section
        allDeleted.items = allDeleted.items.map { var i = $0; i.deleted = true; return i }
        #expect(allDeleted.visibleItems.isEmpty)
    }

    @Test func 不同步时的提示文字() {
        #expect(MinutesSync.retranscribed.notice == "转写稿已重新生成，纪要的出处可能不准确")
        #expect(MinutesSync.edited.notice == "转写稿有修改")
        #expect(MinutesSync.inSync.notice == nil)
    }
}

/// 有效文字 9 + 6 = 15 个，少于 50
private let shortTranscript = transcript
/// 有效文字 60 个
private let longTranscript = Transcript(
    engine: "apple/speechanalyzer", createdAt: meetingStart, hotwords: [],
    items: [.sentence(TranscriptSentence(id: "s1", start: 0, end: 60,
                                         text: String(repeating: "我们讨论一下发布时间。", count: 6)))])

private func status(_ state: MinutesState?, activity: MinutesActivity? = nil, wait: MinutesWaitReason? = nil,
                    transcript: Transcript? = longTranscript) -> MinutesStatus {
    MinutesStatus(state: state, activity: activity, waitReason: wait, transcript: transcript)
}

@Suite struct MinutesStatusTests {
    @Test func 从未生成_内容太少时说明原因并可手动生成() {
        let s = status(nil, transcript: shortTranscript)
        #expect(s == .notGenerated(tooLittleText: true))
        #expect(s.text == "内容太少，未生成纪要")
        #expect(s.actionTitle == "生成纪要")
    }

    @Test func 从未生成_旧会议或自动生成关着时只提供生成纪要() {
        let s = status(nil)
        #expect(s == .notGenerated(tooLittleText: false))
        #expect(s.text == nil)
        #expect(s.actionTitle == "生成纪要")
    }

    @Test func 从未生成_还没有转写稿时不能生成() {
        let s = status(nil, transcript: nil)
        #expect(s == .awaitingTranscript)
        #expect(s.text == "转写完成后才能生成纪要")
        #expect(s.actionTitle == nil)
    }

    @Test(arguments: [
        (MinutesWaitReason?.none, "排队中", String?.none),
        (.model, "等待下载模型", nil),
        (.power, "等待接通电源", "现在生成"),
        (.transcription, "等待转写完成", nil),
    ])
    func 排队中显示在等什么_只有等电源时可以现在生成(_ wait: MinutesWaitReason?, _ text: String, _ action: String?) {
        let s = status(MinutesState(status: .queued), wait: wait)
        #expect(s == .queued(wait))
        #expect(s.text == text)
        #expect(s.actionTitle == action)
        #expect(s.progress == nil)
        #expect(s.isBusy)
    }

    @Test func 生成中按管线的进度显示_加载模型和生成分开() {
        let loading = status(MinutesState(status: .running), activity: .loading(0.42))
        #expect(loading.text == "正在加载模型（42%）")
        #expect(loading.progress == 0.42)

        let generating = status(MinutesState(status: .running), activity: .generating(0.5))
        #expect(generating.text == "生成中 50%")
        #expect(generating.progress == 0.5)
        #expect(generating.actionTitle == nil)
        #expect(generating.isBusy)
    }

    @Test func 刚开始还没有进度时显示生成中() {
        let s = status(MinutesState(status: .running))
        #expect(s == .generating(nil))
        #expect(s.text == "生成中…")
        #expect(s.progress == nil)
    }

    @Test func 管线已经开始时以管线为准_磁盘上的状态还没跟上() {
        #expect(status(MinutesState(status: .queued), activity: .generating(0.1)) == .generating(0.1))
    }

    @Test func 失败显示原因和重试() {
        let s = status(MinutesState(status: .failed, error: "模型输出无法解析"))
        #expect(s.text == "模型输出无法解析")
        #expect(s.actionTitle == "重试")
        #expect(!s.isBusy)
        #expect(status(MinutesState(status: .failed)).text == "生成纪要失败")
    }

    @Test func 已完成时没有状态文字() {
        let s = status(MinutesState(status: .done), transcript: shortTranscript)
        #expect(s == .done)
        #expect(s.text == nil)
        #expect(s.actionTitle == nil)
        #expect(!s.isBusy)
    }
}
