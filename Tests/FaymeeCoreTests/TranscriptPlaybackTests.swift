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
        #expect(t.plainText == """
            [00:00] 我们先过一下上周的待办
            [01:05] 然后看一下数据
            [10:00] 合盖，未录到声音（10:00–13:00，03:00）
            [1:02:05] 好的，今天先到这里
            """)
    }

    @Test func 空转写稿是空字符串() {
        #expect(transcript([]).plainText == "")
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
        #expect(t.plainText == """
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
        #expect(t.plainText == """
            [03:15] 我们先过一下上周的待办
            [03:21] 嗯
            """)
    }
}
