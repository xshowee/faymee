import Foundation
import Testing
@testable import FaymeeCore

private let created = Date(timeIntervalSince1970: 1_700_000_000)

/// 三个说话人：spk1 说 s1、s3，spk2 说 s2，spk3 说 s4；s5 与任何片段都不重合（未知）
private func transcript() -> Transcript {
    Transcript(engine: "test", createdAt: created, hotwords: [], items: [
        .sentence(TranscriptSentence(id: "s1", start: 1, end: 3, text: "我们先过一下上周的待办", speaker: "spk1")),
        .sentence(TranscriptSentence(id: "s2", start: 4, end: 6, text: "我这边接口已经联调完了", speaker: "spk2")),
        .gap(TranscriptGap(start: 12, end: 72, reason: .lidClosed)),
        .sentence(TranscriptSentence(id: "s3", start: 73, end: 75, text: "好，那测试什么时候能开始", speaker: "spk1")),
        .sentence(TranscriptSentence(id: "s4", start: 76, end: 78, text: "下周一", speaker: "spk3")),
        .sentence(TranscriptSentence(id: "s5", start: 80, end: 81, text: "嗯")),
    ], diarization: Diarization(engine: "fake", voiceprintModel: "fake-vp", speakersCreatedAt: created, speakers: [
        Speaker(id: "spk1", voiceprint: Voiceprint([1, 0]), speechDuration: 10),
        Speaker(id: "spk2", name: "张三", nameSource: .voiceprint, personID: "p1",
                voiceprint: Voiceprint([0, 1]), speechDuration: 30),
        Speaker(id: "spk3", voiceprint: Voiceprint([1, 1]), speechDuration: 2),
    ]))
}

private func sentence(_ t: Transcript, _ id: String) -> TranscriptSentence? {
    t.sentences.first { $0.id == id }
}

/// 改某一句的说话人
@Suite struct 改单句的说话人 {
    @Test func 改成已有说话人时记下区分结果原值() {
        var t = transcript()
        let changed = t.setSpeaker(sentence: "s3", to: "spk2")

        #expect(changed)
        #expect(sentence(t, "s3") == TranscriptSentence(
            id: "s3", start: 73, end: 75, text: "好，那测试什么时候能开始",
            speaker: "spk2", originalSpeaker: OriginalSpeaker(speaker: "spk1")))
        #expect(t.speakers == transcript().speakers)
    }

    @Test func 再改一次时原值仍是区分结果() {
        var t = transcript()
        t.setSpeaker(sentence: "s3", to: "spk2")
        t.setSpeaker(sentence: "s3", to: "spk3")

        #expect(sentence(t, "s3")?.speaker == "spk3")
        #expect(sentence(t, "s3")?.originalSpeaker == OriginalSpeaker(speaker: "spk1"))
    }

    @Test func 改回区分结果等于恢复() {
        var t = transcript()
        t.setSpeaker(sentence: "s3", to: "spk2")
        let changed = t.setSpeaker(sentence: "s3", to: "spk1")

        #expect(changed)
        #expect(t == transcript())
    }

    /// 区分结果是“未知”的句子也能改，原值记为未知，与“没改过”分开
    @Test func 未知的句子改给某人时原值记为未知() {
        var t = transcript()
        t.setSpeaker(sentence: "s5", to: "spk3")

        #expect(sentence(t, "s5")?.speaker == "spk3")
        #expect(sentence(t, "s5")?.originalSpeaker == OriginalSpeaker(speaker: nil))
    }

    @Test func 没有变化或说话人不存在时不改() {
        var t = transcript()

        let same = t.setSpeaker(sentence: "s1", to: "spk1")
        let missingSpeaker = t.setSpeaker(sentence: "s1", to: "spk9")
        let missingSentence = t.setSpeaker(sentence: "s9", to: "spk2")

        #expect(!same && !missingSpeaker && !missingSentence)
        #expect(t == transcript())
    }

    @Test func 恢复后回到区分结果() {
        var t = transcript()
        t.setSpeaker(sentence: "s5", to: "spk3")
        t.setSpeaker(sentence: "s3", to: "spk2")
        t.setSpeaker(sentence: "s3", to: "spk3")

        let restored3 = t.restoreSpeaker(sentence: "s3")
        let restored5 = t.restoreSpeaker(sentence: "s5")
        let untouched = t.restoreSpeaker(sentence: "s1")

        #expect(restored3 && restored5 && !untouched)
        #expect(t == transcript())
    }

    /// 纠正两个人被并成一个：把句子改给一个新说话人，编号接在最后
    @Test func 改给新说话人() {
        var t = transcript()
        let id = t.setNewSpeaker(sentence: "s3")

        #expect(id == "spk4")
        #expect(t.speakers.map(\.id) == ["spk1", "spk2", "spk3", "spk4"])
        #expect(t.speaker("spk4") == Speaker(id: "spk4", voiceprint: Voiceprint([]), speechDuration: 0))
        #expect(t.speaker("spk4")?.displayName == "说话人 4")
        #expect(sentence(t, "s3")?.speaker == "spk4")
        #expect(sentence(t, "s3")?.originalSpeaker == OriginalSpeaker(speaker: "spk1"))
    }

    @Test func 没区分过或句子不存在时不新建说话人() {
        var t = transcript()
        let missing = t.setNewSpeaker(sentence: "s9")
        var plain = Transcript(engine: "test", createdAt: created, hotwords: [], items: [
            .sentence(TranscriptSentence(id: "s1", start: 1, end: 3, text: "你好")),
        ])
        let undiarized = plain.setNewSpeaker(sentence: "s1")

        #expect(missing == nil && undiarized == nil)
        #expect(t == transcript())
        #expect(plain.diarization == nil)
    }
}

/// 给说话人改名
@Suite struct 改名 {
    @Test func 去首尾空白后改名_来源记为手动() {
        var t = transcript()
        let result = t.renameSpeaker("spk1", to: "  李四\n")

        #expect(result == .renamed)
        #expect(t.speaker("spk1") == Speaker(id: "spk1", name: "李四", nameSource: .user,
                                             voiceprint: Voiceprint([1, 0]), speechDuration: 10))
        #expect(t.sentences == transcript().sentences)
    }

    /// 声纹认出的人改成别的名字，就不再是声纹库里那个人
    @Test func 改掉声纹认出的名字时清掉声纹库关联() {
        var t = transcript()
        t.renameSpeaker("spk2", to: "王五")

        #expect(t.speaker("spk2")?.name == "王五")
        #expect(t.speaker("spk2")?.nameSource == .user)
        #expect(t.speaker("spk2")?.personID == nil)
    }

    /// 改成本场另一个人的显示名（含“说话人 N”）时不直接改，交给界面确认合并
    @Test func 改成本场已有的名字时返回需要合并() {
        var t = transcript()
        let toName = t.renameSpeaker("spk1", to: "张三")
        let toNumber = t.renameSpeaker("spk1", to: "说话人 3")

        #expect(toName == .needsMerge(into: "spk2"))
        #expect(toNumber == .needsMerge(into: "spk3"))
        #expect(t == transcript())
    }

    @Test func 名字没变时不改() {
        var t = transcript()
        let sameName = t.renameSpeaker("spk2", to: " 张三 ")
        let sameNumber = t.renameSpeaker("spk1", to: "说话人 1")
        let missing = t.renameSpeaker("spk9", to: "李四")

        #expect(sameName == .unchanged && sameNumber == .unchanged && missing == .unchanged)
        #expect(t == transcript())
    }

    /// 清空名字退回“说话人 N”
    @Test func 清空名字退回编号() {
        var t = transcript()
        t.renameSpeaker("spk1", to: "李四")
        let cleared = t.renameSpeaker("spk1", to: "  ")
        let again = t.renameSpeaker("spk1", to: "")

        #expect(cleared == .renamed && again == .unchanged)
        #expect(t == transcript())
    }
}

/// 声纹认错了人：点“不是此人”退回“说话人 N”
@Suite struct 不是此人 {
    @Test func 清掉名字和声纹库关联() {
        var t = transcript()
        let changed = t.rejectRecognizedPerson("spk2")

        #expect(changed)
        #expect(t.speaker("spk2") == Speaker(id: "spk2", voiceprint: Voiceprint([0, 1]), speechDuration: 30))
        #expect(t.speaker("spk2")?.displayName == "说话人 2")
        #expect(t.sentences == transcript().sentences)
    }

    @Test func 没有名字或说话人不存在时不改() {
        var t = transcript()
        let unnamed = t.rejectRecognizedPerson("spk1")
        let missing = t.rejectRecognizedPerson("spk9")

        #expect(!unnamed && !missing)
        #expect(t == transcript())
    }
}

/// 重新区分、重新转写前提示“会丢弃 N 处修改”的 N
@Suite struct 说话人修改数 {
    /// 按单句改过说话人的句子计；合并也记为相关句子的修改；改回原值不算
    @Test func 按改过说话人的句子计() {
        var t = transcript()
        #expect(t.speakerEditCount == 0)

        t.setSpeaker(sentence: "s4", to: "spk2")
        t.setSpeaker(sentence: "s4", to: "spk1")
        t.setSpeaker(sentence: "s5", to: "spk1")
        #expect(t.speakerEditCount == 2)

        t.mergeSpeaker("spk1", into: "spk2")
        #expect(t.speakerEditCount == 4)

        t.renameSpeaker("spk2", to: "李四")
        t.restoreSpeaker(sentence: "s5")
        #expect(t.speakerEditCount == 3)
    }

    /// 重新转写会同时丢掉文字修改和说话人修改：同一句既改了文字又改了说话人算两处
    @Test func 重新转写的修改数加上说话人修改() {
        var t = transcript()
        t.edit(sentence: "s1", to: "我们先过一下上周的待办事项")
        t.setSpeaker(sentence: "s1", to: "spk2")
        t.setSpeaker(sentence: "s4", to: "spk2")

        #expect(t.speakerEditCount == 2)
        #expect(t.editCount == 3)
    }

    /// 这次转写会区分说话人时，名字按时间重合沿用到新说话人，不算丢失
    @Test func 重新转写会区分说话人时名字不算修改() {
        var t = transcript()
        t.edit(sentence: "s1", to: "我们先过一下上周的待办事项")
        t.renameSpeaker("spk1", to: "李四")

        #expect(t.retranscribeEditCount(diarizes: true) == 1)
    }

    /// 开关关着（或没有区分引擎）时新稿没有说话人，手动起的名字（含合并、采纳建议）也会丢，每个名字算一处；
    /// 声纹认出的名字不是人工修改，下次区分还会认出来，不算
    @Test func 重新转写不区分说话人时手动起的名字也算修改() {
        var t = transcript()
        t.edit(sentence: "s1", to: "我们先过一下上周的待办事项")
        t.setSpeaker(sentence: "s4", to: "spk2")
        #expect(t.retranscribeEditCount(diarizes: false) == 2)

        t.renameSpeaker("spk1", to: "李四")
        t.renameSpeaker("spk3", to: "王五")
        #expect(t.retranscribeEditCount(diarizes: false) == 4)
    }
}

/// 合并两个说话人：纠正同一个人被拆成两个
@Suite struct 合并说话人 {
    @Test func 句子归目标且记为单句修改_来源从列表移除() {
        var t = transcript()
        let changed = t.mergeSpeaker("spk1", into: "spk2")

        #expect(changed)
        #expect(t.speakers.map(\.id) == ["spk2", "spk3"])
        #expect(t.sentences.map(\.speaker) == ["spk2", "spk2", "spk2", "spk3", nil])
        #expect(t.sentences.map(\.originalSpeaker) == [
            OriginalSpeaker(speaker: "spk1"), nil, OriginalSpeaker(speaker: "spk1"), nil, nil,
        ])
    }

    /// 声纹按发言时长加权平均：[1,0]×10 秒 + [0,1]×30 秒 → [0.25,0.75]，时长相加
    @Test func 声纹按发言时长加权平均_时长相加() {
        var t = transcript()
        t.mergeSpeaker("spk1", into: "spk2")

        #expect(t.speaker("spk2") == Speaker(id: "spk2", name: "张三", nameSource: .user, personID: "p1",
                                             voiceprint: Voiceprint([0.25, 0.75]), speechDuration: 40))
    }

    /// 目标没名字时用来源的名字，“合并到……”不丢掉已经改好的名字
    @Test func 目标没名字时沿用来源的名字() {
        var t = transcript()
        t.mergeSpeaker("spk2", into: "spk3")

        #expect(t.speaker("spk3") == Speaker(id: "spk3", name: "张三", nameSource: .user, personID: "p1",
                                             voiceprint: Voiceprint([0.0625, 1]), speechDuration: 32))
    }

    /// 两个都没名字时仍显示“说话人 N”，不记名字来源（没有人手动命名过）
    @Test func 都没名字时合并后仍没名字() {
        var t = transcript()
        t.mergeSpeaker("spk3", into: "spk1")

        #expect(t.speaker("spk1")?.name == nil)
        #expect(t.speaker("spk1")?.nameSource == nil)
        #expect(t.speaker("spk1")?.displayName == "说话人 1")
    }

    /// 原本属于目标、被单句改给来源的句子，合并后回到区分结果，不再算修改
    @Test func 改给来源的句子合并回原说话人时不再算修改() {
        var t = transcript()
        t.setSpeaker(sentence: "s2", to: "spk3")
        t.mergeSpeaker("spk3", into: "spk2")

        #expect(sentence(t, "s2")?.speaker == "spk2")
        #expect(sentence(t, "s2")?.originalSpeaker == nil)
        #expect(sentence(t, "s4")?.originalSpeaker == OriginalSpeaker(speaker: "spk3"))
    }

    /// 新建的说话人没有声纹：合并时不参与平均，时长为 0 也不拉低
    @Test func 没有声纹的一方不参与平均() {
        var t = transcript()
        t.setNewSpeaker(sentence: "s5")
        t.mergeSpeaker("spk4", into: "spk1")
        #expect(t.speaker("spk1")?.voiceprint == Voiceprint([1, 0]))
        #expect(t.speaker("spk1")?.speechDuration == 10)

        var u = transcript()
        u.setNewSpeaker(sentence: "s5")
        u.mergeSpeaker("spk3", into: "spk4")
        #expect(u.speaker("spk4")?.voiceprint == Voiceprint([1, 1]))
        #expect(u.speaker("spk4")?.speechDuration == 2)
    }

    @Test func 同一个人或说话人不存在时不合并() {
        var t = transcript()
        let same = t.mergeSpeaker("spk1", into: "spk1")
        let missingSource = t.mergeSpeaker("spk9", into: "spk1")
        let missingTarget = t.mergeSpeaker("spk1", into: "spk9")

        #expect(!same && !missingSource && !missingTarget)
        #expect(t == transcript())
    }

    /// 合并掉的 id 不再出现：新建说话人不复用它，原值指向它的句子不能恢复（会指向不存在的人）
    @Test func 合并掉的编号不复用_原值指向它的句子不能恢复() {
        var t = transcript()
        t.setSpeaker(sentence: "s4", to: "spk1")
        t.mergeSpeaker("spk3", into: "spk2")
        let restored = t.restoreSpeaker(sentence: "s4")
        let newID = t.setNewSpeaker(sentence: "s5")

        #expect(!restored)
        #expect(sentence(t, "s4")?.speaker == "spk1")
        #expect(newID == "spk4")
    }

    /// 合并掉、已经没有任何句子或原值引用的编号也不复用：纪要负责人、姓名建议可能还记着它，
    /// 复用就会指到新的人身上。写盘再读回（退出再打开）后仍然记得
    @Test func 不再被引用的合并掉的编号也不复用_写盘后仍然记得() throws {
        var t = transcript()
        #expect(t.setNewSpeaker(sentence: "s5") == "spk4")
        // s5 原本是未知，并回 spk1 后 spk4 不再被任何句子或原值引用
        t.mergeSpeaker("spk4", into: "spk1")
        #expect(!t.sentences.contains { $0.speaker == "spk4" || $0.originalSpeaker?.speaker == "spk4" })

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var reopened = try decoder.decode(Transcript.self, from: encoder.encode(t))

        #expect(reopened.setNewSpeaker(sentence: "s3") == "spk5")
    }
}
