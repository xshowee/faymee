import Foundation
import Testing
@testable import FaymeeCore

private func speaker(_ id: String, _ name: String? = nil) -> Speaker {
    Speaker(id: id, name: name, nameSource: name == nil ? nil : .user, voiceprint: Voiceprint([1]), speechDuration: 1)
}

private func transcript(_ sentenceSpeakers: [String?], speakers: [Speaker]?) -> Transcript {
    Transcript(engine: "fake/1", createdAt: Date(timeIntervalSince1970: 0), hotwords: [],
               items: sentenceSpeakers.enumerated().map { i, spk in
                   .sentence(.init(id: "s\(i + 1)", start: Double(i), end: Double(i + 1), text: "句子", speaker: spk))
               },
               diarization: speakers.map {
                   Diarization(engine: "fake-diarizer/1", voiceprintModel: "fake-embedding/1",
                               speakersCreatedAt: Date(timeIntervalSince1970: 0), speakers: $0)
               })
}

@Suite struct SpeakerDisplayTests {
    @Test func 没有名字时按编号显示说话人N() {
        #expect(speaker("spk1").displayName == "说话人 1")
        #expect(speaker("spk12").displayName == "说话人 12")
    }

    @Test func 有名字时显示名字() {
        #expect(speaker("spk2", "王总").displayName == "王总")
    }

    @Test func 名字为空白时按编号显示() {
        #expect(speaker("spk2", "  ").displayName == "说话人 2")
    }

    /// 编号取自 id，不是列表位置：合并掉 spk1 之后 spk2 仍是“说话人 2”
    @Test func 编号取自id而非列表位置() {
        let t = transcript(["spk2", "spk3"], speakers: [speaker("spk2"), speaker("spk3")])
        #expect(t.speakerName(for: t.sentences[0]) == "说话人 2")
        #expect(t.speakerName(for: t.sentences[1]) == "说话人 3")
    }

    @Test func 句子的说话人显示名() {
        let t = transcript(["spk1", nil, "spk2"], speakers: [speaker("spk1", "张三"), speaker("spk2")])
        #expect(t.sentences.map { t.speakerName(for: $0) } == ["张三", "未知", "说话人 2"])
    }

    @Test func 两个及以上说话人时显示说话人() {
        #expect(transcript(["spk1", "spk2"], speakers: [speaker("spk1"), speaker("spk2")]).showsSpeakers)
    }

    /// 独白、没区分过、只有一个人加几句未知，都不显示说话人
    @Test func 只有一个说话人时不显示说话人() {
        #expect(!transcript(["spk1", "spk1"], speakers: [speaker("spk1")]).showsSpeakers)
        #expect(!transcript(["spk1", nil], speakers: [speaker("spk1")]).showsSpeakers)
        #expect(!transcript([nil, nil], speakers: nil).showsSpeakers)
        #expect(!transcript([nil], speakers: []).showsSpeakers)
    }

    /// 列表里有、但一句都没有的说话人不算（例如单句改走了他所有的句子）
    @Test func 只按句子实际用到的说话人判断() {
        #expect(!transcript(["spk1", "spk1"], speakers: [speaker("spk1"), speaker("spk2")]).showsSpeakers)
    }
}
