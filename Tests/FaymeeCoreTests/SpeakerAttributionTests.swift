import Foundation
import Testing
@testable import FaymeeCore

private let createdAt = Date(timeIntervalSince1970: 1_762_743_660)

private func sentence(_ id: String, _ start: TimeInterval, _ end: TimeInterval, _ text: String = "",
                      original: String? = nil) -> TranscriptItem {
    .sentence(.init(id: id, start: start, end: end, text: text.isEmpty ? id : text, original: original))
}

private func transcript(_ items: [TranscriptItem]) -> Transcript {
    Transcript(engine: "fake/1", createdAt: Date(timeIntervalSince1970: 0), hotwords: [], items: items)
}

private func seg(_ start: TimeInterval, _ end: TimeInterval, _ speaker: Int) -> SpeakerSegment {
    SpeakerSegment(start: start, end: end, speaker: speaker)
}

private func attribute(_ t: Transcript, _ segments: [SpeakerSegment],
                       voiceprints: [Int: Voiceprint] = [:]) -> Transcript {
    t.withSpeakers(DiarizationResult(segments: segments, voiceprints: voiceprints),
                   engine: "fake-diarizer/1", voiceprintModel: "fake-embedding/1", createdAt: createdAt)
}

/// 句子 id → 说话人 id，nil 为未知
private func speakers(_ t: Transcript) -> [String: String?] {
    Dictionary(uniqueKeysWithValues: t.sentences.map { ($0.id, $0.speaker) })
}

@Suite struct SpeakerAttributionTests {
    @Test func 每句归给重合最长的说话人() {
        let t = attribute(transcript([sentence("s1", 0, 4), sentence("s2", 5, 9)]),
                          [seg(0, 4.5, 0), seg(4.5, 9, 1)])
        #expect(speakers(t) == ["s1": "spk1", "s2": "spk2"])
    }

    /// 重合按说话人累计，不按单个片段：B 有最长的一段，但 A 的几段加起来更长
    @Test func 重合按说话人累计() {
        let t = attribute(transcript([sentence("s1", 0, 10)]),
                          [seg(0, 3, 0), seg(3, 3.5, 1), seg(3.5, 6.5, 0), seg(6.5, 10, 1)])
        // A（0）共 6 秒，B（1）共 4 秒，B 的 6.5–10 是最长的单段
        #expect(speakers(t) == ["s1": "spk1"])
        #expect(t.speakers.map(\.id) == ["spk1"])
    }

    @Test func 与任何片段都不重合的句子没有说话人() {
        let t = attribute(transcript([sentence("s1", 0, 2), sentence("s2", 3, 4), sentence("s3", 5, 7)]),
                          [seg(0, 2, 0), seg(5, 7, 1)])
        #expect(speakers(t) == ["s1": "spk1", "s2": nil, "s3": "spk2"])
    }

    @Test func 横跨两人的句子按多数归属() {
        let t = attribute(transcript([sentence("s1", 0, 2), sentence("s2", 2, 6), sentence("s3", 6, 8)]),
                          [seg(0, 3, 0), seg(3, 8, 1)])
        // s2 与 A 重合 1 秒、与 B 重合 3 秒
        #expect(speakers(t) == ["s1": "spk1", "s2": "spk2", "s3": "spk2"])
    }

    /// 重合一样长时归给先开口的说话人
    @Test func 平票归给先开口的() {
        let t = attribute(transcript([sentence("s1", 0, 1), sentence("s2", 2, 4)]),
                          [seg(0, 1, 5), seg(2, 3, 9), seg(3, 4, 5)])
        #expect(speakers(t) == ["s1": "spk1", "s2": "spk1"])
    }

    /// 引擎的编号（7、2）与先后无关，转写稿里按第一次开口先后编为 spk1、spk2、spk3
    @Test func 按第一次开口先后编号() {
        let t = attribute(transcript([sentence("s1", 0, 2), sentence("s2", 2, 4), sentence("s3", 4, 6),
                                      sentence("s4", 6, 8)]),
                          [seg(4, 6, 0), seg(0, 2, 7), seg(2, 4, 2), seg(6, 8, 7)],
                          voiceprints: [7: Voiceprint([1, 0]), 2: Voiceprint([0, 1]), 0: Voiceprint([1, 1])])
        #expect(speakers(t) == ["s1": "spk1", "s2": "spk2", "s3": "spk3", "s4": "spk1"])
        #expect(t.speakers == [
            Speaker(id: "spk1", voiceprint: Voiceprint([1, 0]), speechDuration: 4),
            Speaker(id: "spk2", voiceprint: Voiceprint([0, 1]), speechDuration: 2),
            Speaker(id: "spk3", voiceprint: Voiceprint([1, 1]), speechDuration: 2),
        ])
        #expect(t.diarization?.engine == "fake-diarizer/1")
        #expect(t.diarization?.voiceprintModel == "fake-embedding/1")
        #expect(t.speakersCreatedAt == createdAt)
    }

    /// 没分到句子的说话人（只有零碎片段）不进列表，编号不跳号
    @Test func 没分到句子的说话人不进列表() {
        let t = attribute(transcript([sentence("s1", 0, 3), sentence("s2", 4, 6)]),
                          [seg(0, 2.5, 0), seg(2.5, 3, 1), seg(4, 6, 2)])
        #expect(speakers(t) == ["s1": "spk1", "s2": "spk2"])
        #expect(t.speakers.map(\.speechDuration) == [2.5, 2])
    }

    /// 合盖时录音是静音，落在空白里的片段（和片段落在空白里的部分）不算
    @Test func 落在合盖空白里的片段忽略() {
        let t = attribute(transcript([sentence("s1", 9, 13), .gap(.init(start: 10, end: 20, reason: .lidClosed)),
                                      sentence("s2", 20, 22)]),
                          [seg(9.5, 10, 0), seg(12, 19, 1), seg(18, 25, 2)])
        // s1 跨过空白起点：1 的 12–13 在空白里，不算；0 的 9.5–10 在空白外
        #expect(speakers(t) == ["s1": "spk1", "s2": "spk2"])
        // 2 的 18–25 只算空白外的 20–25
        #expect(t.speakers.map(\.speechDuration) == [0.5, 5])
    }

    /// 同一人的片段有重叠时，发言时长不重复计算
    @Test func 发言时长按片段并集计算() {
        let t = attribute(transcript([sentence("s1", 0, 4)]), [seg(0, 3, 0), seg(2, 4, 0), seg(5, 6, 0)])
        #expect(t.speakers.map(\.speechDuration) == [5])
    }

    /// 补说话人、重新区分都在已有转写稿上做：只改说话人，句子 id、文字、修改记录、空白都不动；
    /// 原来的说话人和单句修改作废
    @Test func 只改说话人字段() {
        var old = transcript([sentence("s1", 0, 2, "回来了", original: "灰来了"),
                              .gap(.init(start: 2, end: 2, reason: .lidClosed)), sentence("s7", 3, 5, "好")])
        old.items[2] = .sentence(.init(id: "s7", start: 3, end: 5, text: "好", speaker: "spk1",
                                       originalSpeaker: .init(speaker: "spk3")))
        old.diarization = Diarization(engine: "old/1", voiceprintModel: "old-embedding/1",
                                      speakersCreatedAt: Date(timeIntervalSince1970: 0),
                                      speakers: [Speaker(id: "spk1", name: "张三", nameSource: .user,
                                                         voiceprint: Voiceprint([1]), speechDuration: 1)])

        let t = attribute(old, [seg(0, 2, 0), seg(3, 5, 1)])
        #expect(t.items == [
            .sentence(.init(id: "s1", start: 0, end: 2, text: "回来了", original: "灰来了", speaker: "spk1")),
            .gap(.init(start: 2, end: 2, reason: .lidClosed)),
            .sentence(.init(id: "s7", start: 3, end: 5, text: "好", speaker: "spk2")),
        ])
        #expect(t.engine == old.engine && t.createdAt == old.createdAt && t.hotwords == old.hotwords)
        #expect(t.speakers.allSatisfy { $0.name == nil && $0.nameSource == nil && $0.personID == nil })
        #expect(t.diarization?.engine == "fake-diarizer/1")
    }

    @Test func 引擎没给声纹的说话人声纹为空() {
        let t = attribute(transcript([sentence("s1", 0, 2)]), [seg(0, 2, 3)])
        #expect(t.speakers.first?.voiceprint == Voiceprint([]))
    }

    @Test func 没有任何片段时句子都是未知() {
        let t = attribute(transcript([sentence("s1", 0, 2)]), [])
        #expect(speakers(t) == ["s1": nil])
        #expect(t.diarization != nil)
        #expect(t.speakers.isEmpty)
    }
}
