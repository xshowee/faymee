import Foundation
import Testing
@testable import FaymeeCore

private func sentence(_ id: String, _ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptItem {
    .sentence(TranscriptSentence(id: id, start: start, end: end, text: text))
}

private func lidGap(_ start: TimeInterval, _ end: TimeInterval) -> TranscriptItem {
    .gap(TranscriptGap(start: start, end: end, reason: .lidClosed))
}

private func transcript(_ items: [TranscriptItem]) -> Transcript {
    Transcript(engine: "test", createdAt: Date(timeIntervalSince1970: 0), hotwords: [], items: items)
}

/// 回放时高亮哪一条
@Suite struct 当前条目定位 {
    let t = transcript([
        sentence("s1", 1.0, 3.0, "我们先过一下上周的待办"),
        sentence("s2", 3.0, 5.5, "然后看一下数据"),
        sentence("s3", 8.0, 10.0, "好的"),
        lidGap(12.0, 72.0),
        sentence("s4", 73.0, 75.0, "刚才说到哪了"),
    ])

    @Test func 落在句子内时是这一句() {
        #expect(t.itemIndex(at: 1.0) == 0)
        #expect(t.itemIndex(at: 4.0) == 1)
        #expect(t.itemIndex(at: 74.9) == 4)
    }

    /// 停顿时保持高亮刚说完的那句，不让高亮一闪一闪
    @Test func 落在两句之间时仍是上一句() {
        #expect(t.itemIndex(at: 6.0) == 1)
        #expect(t.itemIndex(at: 11.9) == 2)
        #expect(t.itemIndex(at: 72.5) == 3)
    }

    @Test func 第一句之前没有当前条目() {
        #expect(t.itemIndex(at: 0) == nil)
        #expect(t.itemIndex(at: 0.99) == nil)
    }

    @Test func 最后一句之后仍是最后一句() {
        #expect(t.itemIndex(at: 80) == 4)
    }

    @Test func 空转写稿没有当前条目() {
        #expect(transcript([]).itemIndex(at: 5) == nil)
    }

    @Test func 落在合盖空白内时是空白条目() {
        #expect(t.itemIndex(at: 12.0) == 3)
        #expect(t.itemIndex(at: 40) == 3)
    }

    /// 转写管线保留中点在空白外的跨界句子，所以句子可能伸进空白
    @Test func 句子伸进空白时空白开始后算空白() {
        let t = transcript([
            sentence("s1", 10.5, 13.0, "我们先到这里"),
            lidGap(12.0, 72.0),
        ])
        #expect(t.itemIndex(at: 11.0) == 0)
        #expect(t.itemIndex(at: 12.5) == 1)
    }

    /// 录音中也可能有长度为 0 的空白，标记插在句子中间
    @Test func 句子中间长度为零的空白不抢高亮() {
        let t = transcript([
            sentence("s1", 20.0, 25.0, "这一句说得比较长"),
            lidGap(22.0, 22.0),
            sentence("s2", 26.0, 27.0, "好"),
        ])
        #expect(t.itemIndex(at: 22.0) == 0)
        #expect(t.itemIndex(at: 23.0) == 0)
        #expect(t.itemIndex(at: 25.5) == 0)
        #expect(t.itemIndex(at: 26.0) == 2)
    }
}

/// 全选复制得到的纯文本
@Suite struct 复制文本 {
    @Test func 每行是开始时间加文本_合盖空白单独一行() {
        let t = transcript([
            sentence("s1", 0.48, 3.2, "我们先过一下上周的待办"),
            sentence("s2", 65.9, 70, "然后看一下数据"),
            lidGap(600, 780.5),
            sentence("s3", 3725.2, 3730, "好的，今天先到这里"),
        ])
        #expect(t.plainText(meeting: nil) == """
            [00:00] 我们先过一下上周的待办
            [01:05] 然后看一下数据
            [10:00] 合盖，未录到声音（10:00–13:00，03:00）
            [1:02:05] 好的，今天先到这里
            """)
    }

    @Test func 空转写稿是空字符串() {
        #expect(transcript([]).plainText(meeting: nil) == "")
    }
}

/// 区分过说话人时复制全文每行带上说话人（spec 55、57）
@Suite struct 复制文本带说话人 {
    private func said(_ id: String, _ start: TimeInterval, _ speaker: String?, _ text: String) -> TranscriptItem {
        .sentence(TranscriptSentence(id: id, start: start, end: start + 5, text: text, speaker: speaker))
    }

    private func diarized(_ items: [TranscriptItem], _ speakers: [Speaker]) -> Transcript {
        Transcript(engine: "test", createdAt: Date(timeIntervalSince1970: 0), hotwords: [], items: items,
                   diarization: Diarization(engine: "fake", voiceprintModel: "fake",
                                            speakersCreatedAt: Date(timeIntervalSince1970: 60), speakers: speakers))
    }

    private func speaker(_ id: String, _ name: String? = nil) -> Speaker {
        Speaker(id: id, name: name, nameSource: name == nil ? nil : .user, voiceprint: Voiceprint([1]),
                speechDuration: 30)
    }

    /// 没命名的按编号显示；找不到说话人的句子写“未知”；合盖空白不带说话人
    @Test func 两个说话人时每句带上名字_未知写未知_合盖空白不带() {
        let t = diarized([
            said("s1", 195, "spk1", "我们先过一下上周的待办"),
            said("s2", 201, "spk2", "报价单我周三前发"),
            said("s3", 207, nil, "嗯"),
            lidGap(600, 780),
            said("s4", 3725, "spk1", "好，今天就到这里"),
        ], [speaker("spk1", "张三"), speaker("spk2")])
        #expect(t.plainText(meeting: nil) == """
            [03:15] 张三：我们先过一下上周的待办
            [03:21] 说话人 2：报价单我周三前发
            [03:27] 未知：嗯
            [10:00] 合盖，未录到声音（10:00–13:00，03:00）
            [1:02:05] 张三：好，今天就到这里
            """)
    }

    /// 一个人加几句未知也算只有一个说话人；列表里有但一句都没有的不算
    @Test func 只有一个说话人时不带前缀() {
        let t = diarized([
            said("s1", 195, "spk1", "我们先过一下上周的待办"),
            said("s2", 201, nil, "嗯"),
        ], [speaker("spk1", "张三"), speaker("spk2")])
        #expect(t.plainText(meeting: nil) == """
            [03:15] 我们先过一下上周的待办
            [03:21] 嗯
            """)
    }
}

/// 复制全文、导出转写稿时，笔记按时间插成 `[12:03] 笔记：……` 一行，标记不写（spec 46）
@Suite struct 复制文本带笔记 {
    private static let t0 = try! Date("2026-11-10T02:00:00Z", strategy: .iso8601)

    /// 两个分片，中间有 100 秒没录到：墙钟 0–300 秒是录音 0–300，墙钟 400–1000 秒是录音 300–900
    static func meeting(segments: [Segment]? = nil, annotations: [Annotation]) -> Meeting {
        func segment(_ file: String, _ wall: TimeInterval, _ offset: TimeInterval, _ duration: TimeInterval) -> Segment {
            Segment(file: file, startedAt: t0.addingTimeInterval(wall), sampleRate: 48000, channels: 1,
                    device: "MacBook Pro 麦克风", deviceUID: "BuiltIn", offset: offset, duration: duration)
        }
        return Meeting(id: "m", title: "会议", startedAt: t0, endedAt: t0.addingTimeInterval(1000), status: .done,
                       segments: segments ?? [segment("0001.caf", 0, 0, 300), segment("0002.caf", 400, 300, 600)],
                       recording: "recording.m4a", duration: 900, annotations: annotations)
    }

    static func mark(_ id: String, _ wall: TimeInterval) -> Annotation {
        Annotation(id: id, at: t0.addingTimeInterval(wall), kind: .mark)
    }

    static func note(_ id: String, _ wall: TimeInterval, _ text: String) -> Annotation {
        Annotation(id: id, at: t0.addingTimeInterval(wall), kind: .note, text: text)
    }

    /// 笔记的时间经录音时间线换算（墙钟 460 秒是录音里的 06:00，不是 07:40）；与句子同一时刻时排在句子前面；
    /// 晚于最后一句的排在最后
    @Test func 笔记按录音里的时间插成一行_标记不写() {
        let t = transcript([
            sentence("s1", 0.5, 3, "我们先过一下上周的待办"),
            sentence("s2", 50, 55, "预算这块谁来跟"),
            sentence("s3", 355, 362, "老王说周五前给"),
            sentence("s4", 370, 375, "好"),
        ])
        let m = Self.meeting(annotations: [
            Self.note("a1", 50, "预算"),
            Self.mark("a2", 100),
            Self.note("a3", 460, "预算 → 老王确认"),
            Self.note("a4", 990, "散会后找法务"),
        ])
        #expect(t.plainText(meeting: m) == """
            [00:00] 我们先过一下上周的待办
            [00:50] 笔记：预算
            [00:50] 预算这块谁来跟
            [05:55] 老王说周五前给
            [06:00] 笔记：预算 → 老王确认
            [06:10] 好
            [14:50] 笔记：散会后找法务
            """)
    }

    /// 笔记不是谁说的话，显示说话人时也不带说话人前缀（同合盖空白行）
    @Test func 显示说话人时笔记行不带说话人() {
        let speakers = ["张三", nil].enumerated().map { i, name in
            Speaker(id: "spk\(i + 1)", name: name, nameSource: name == nil ? nil : .user, voiceprint: Voiceprint([1]),
                    speechDuration: 30)
        }
        let t = Transcript(engine: "test", createdAt: Self.t0, hotwords: [], items: [
            .sentence(TranscriptSentence(id: "s1", start: 40, end: 45, text: "报价单谁来发", speaker: "spk1")),
            .sentence(TranscriptSentence(id: "s2", start: 60, end: 65, text: "我周三前发给客户", speaker: "spk2")),
            .gap(TranscriptGap(start: 200, end: 260, reason: .lidClosed)),
        ], diarization: Diarization(engine: "fake", voiceprintModel: "fake", speakersCreatedAt: Self.t0,
                                    speakers: speakers))
        let m = Self.meeting(annotations: [Self.note("a1", 63, "报价单 周三"), Self.mark("a2", 64)])
        #expect(t.plainText(meeting: m) == """
            [00:40] 张三：报价单谁来发
            [01:00] 说话人 2：我周三前发给客户
            [01:03] 笔记：报价单 周三
            [03:20] 合盖，未录到声音（03:20–04:20，01:00）
            """)
    }

    /// 没有分片（录音没留下）时算不出笔记在录音里的位置，不写笔记行
    @Test func 没有分片时不写笔记() {
        let t = transcript([sentence("s1", 5, 9, "我们先过一下上周的待办")])
        let m = Self.meeting(segments: [], annotations: [Self.note("a1", 5, "待办")])
        #expect(t.plainText(meeting: m) == "[00:05] 我们先过一下上周的待办")
    }
}

/// 会后转写稿里标记的旗子挂在离标记最近的句子旁（spec 39）
@Suite struct 转写稿里的旗子 {
    private typealias F = 复制文本带笔记

    /// 标记的时间经录音时间线换算：墙钟 460 秒是录音里的 06:00（朴素相减是 07:40，会挂到 s3 上）。笔记不挂旗子
    @Test func 标记挂在它所在的那句旁_经时间线换算() {
        let t = transcript([
            sentence("s1", 0.5, 3, "我们先过一下上周的待办"),
            sentence("s2", 355, 362, "老王说周五前给"),
            sentence("s3", 440, 470, "这个月底必须上线"),
        ])
        let m = F.meeting(annotations: [F.mark("a1", 460), F.note("a2", 2, "待办")])
        #expect(t.markedItems(m.transcriptMarks) == [1: [TranscriptMark(id: "a1", offset: 360)]])
    }

    /// 两句之间挂离得近的一句，一样近挂前一句；第一句之前挂第一句，最后一句之后挂最后一句。
    /// 挂在同一句旁的几个标记按时间先后（与创建顺序无关）
    @Test func 两句之间挂近的一句_一样近挂前一句_首尾之外挂首尾() {
        let t = transcript([
            sentence("s1", 10, 20, "第一句"),
            sentence("s2", 30, 40, "第二句"),
            sentence("s3", 100, 110, "第三句"),
        ])
        let m = F.meeting(annotations: [
            F.mark("a1", 280),  // 最后一句之后
            F.mark("a2", 3),    // 第一句之前
            F.mark("a3", 27),   // 离 s2 3 秒、离 s1 7 秒
            F.mark("a4", 25),   // 离 s1、s2 都是 5 秒
            F.mark("a5", 70),   // 离 s2、s3 都是 30 秒
            F.mark("a6", 104),  // 落在 s3 里，比 a1 早
        ])
        #expect(t.markedItems(m.transcriptMarks) == [
            0: [TranscriptMark(id: "a2", offset: 3), TranscriptMark(id: "a4", offset: 25)],
            1: [TranscriptMark(id: "a3", offset: 27), TranscriptMark(id: "a5", offset: 70)],
            2: [TranscriptMark(id: "a6", offset: 104), TranscriptMark(id: "a1", offset: 280)],
        ])
    }

    /// 合盖空白不挂旗子：标记落在空白里时挂离得最近的句子
    @Test func 落在合盖空白里时挂最近的句子() {
        let t = transcript([
            sentence("s1", 10, 20, "合盖前"),
            lidGap(20, 200),
            sentence("s2", 200, 210, "开盖后"),
        ])
        let m = F.meeting(annotations: [F.mark("a1", 50), F.mark("a2", 180)])
        #expect(t.markedItems(m.transcriptMarks) == [
            0: [TranscriptMark(id: "a1", offset: 50)],
            2: [TranscriptMark(id: "a2", offset: 180)],
        ])
    }

    /// 没有句子（只有空白、空转写稿）或没有分片（算不出位置）时都不挂
    @Test func 没有句子或没有分片时不挂() {
        let m = F.meeting(annotations: [F.mark("a1", 50)])
        #expect(transcript([lidGap(0, 100)]).markedItems(m.transcriptMarks).isEmpty)
        #expect(transcript([]).markedItems(m.transcriptMarks).isEmpty)
        let noSegments = F.meeting(segments: [], annotations: [F.mark("a1", 15)])
        #expect(noSegments.transcriptMarks.isEmpty)
    }
}
