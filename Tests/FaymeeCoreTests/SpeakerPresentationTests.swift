import Foundation
import Testing
@testable import FaymeeCore

private func speaker(_ id: String, _ name: String? = nil, duration: TimeInterval = 1) -> Speaker {
    Speaker(id: id, name: name, nameSource: name == nil ? nil : .user, voiceprint: Voiceprint([1]),
            speechDuration: duration)
}

/// 每个元素是一句的说话人；"gap" 表示一段合盖空白
private func transcript(_ entries: [String?], speakers: [Speaker]?) -> Transcript {
    Transcript(engine: "fake/1", createdAt: Date(timeIntervalSince1970: 0), hotwords: [],
               items: entries.enumerated().map { i, spk in
                   spk == "gap"
                       ? .gap(.init(start: Double(i), end: Double(i + 1), reason: .lidClosed))
                       : .sentence(.init(id: "s\(i + 1)", start: Double(i), end: Double(i + 1), text: "句子",
                                         speaker: spk))
               },
               diarization: speakers.map {
                   Diarization(engine: "fake-diarizer/1", voiceprintModel: "fake-embedding/1",
                               speakersCreatedAt: Date(timeIntervalSince1970: 0), speakers: $0)
               })
}

@Suite struct SpeakerTurnTests {
    @Test func 相邻同一说话人归成一段只在段首显示名字() {
        let t = transcript(["spk1", "spk1", "spk2", "spk1"],
                           speakers: [speaker("spk1", "张三"), speaker("spk2")])
        #expect(t.speakerTurns.map { $0?.name } == ["张三", nil, "说话人 2", "张三"])
    }

    @Test func 未知的句子也归成一段() {
        let t = transcript(["spk1", nil, nil, "spk2"], speakers: [speaker("spk1"), speaker("spk2")])
        #expect(t.speakerTurns.map { $0?.name } == ["说话人 1", "未知", nil, "说话人 2"])
        #expect(t.speakerTurns[1]?.speakerID == nil)
    }

    /// 句子指向列表里没有的说话人时当作未知，和真正的未知归成一段
    @Test func 悬空的说话人当作未知() {
        let t = transcript(["spk1", "spk9", nil, "spk2"], speakers: [speaker("spk1"), speaker("spk2")])
        #expect(t.speakerTurns.map { $0?.name } == ["说话人 1", "未知", nil, "说话人 2"])
    }

    /// 合盖空白自己一行、不带名字；空白之后即使还是同一人也重新显示名字
    @Test func 合盖空白打断段落() {
        let t = transcript(["spk1", "gap", "spk1", "spk2"], speakers: [speaker("spk1"), speaker("spk2")])
        #expect(t.speakerTurns.map { $0?.name } == ["说话人 1", nil, "说话人 1", "说话人 2"])
    }

    /// 段首给“自动认出”标记用：只有声纹认出的名字算，手动起的、没名字的不算
    @Test func 段首标出声纹自动认出的人() {
        let recognized = Speaker(id: "spk2", name: "张三", nameSource: .voiceprint, personID: "p1",
                                 voiceprint: Voiceprint([1]), speechDuration: 1)
        let t = transcript(["spk1", "spk2", "spk3", nil],
                           speakers: [speaker("spk1", "李四"), recognized, speaker("spk3")])
        #expect(t.speakerTurns.map { $0?.isRecognized } == [false, true, false, false])
    }

    @Test func 只有一个说话人或没区分过时没有段首() {
        #expect(transcript(["spk1", nil, "spk1"], speakers: [speaker("spk1")]).speakerTurns == [nil, nil, nil])
        #expect(transcript([nil, nil], speakers: nil).speakerTurns == [nil, nil])
    }
}

@Suite struct SpeakerColorTests {
    /// 颜色按编号取，合并掉 spk1 之后 spk2、spk3 的颜色不变；未知没有颜色
    @Test func 颜色按编号分配不随列表位置变化() {
        let t = transcript(["spk2", "spk3", nil], speakers: [speaker("spk2"), speaker("spk3")])
        #expect(t.speakerTurns.map { $0?.colorIndex } == [1, 2, nil])
    }
}

@Suite struct SpeakerListTests {
    /// 按编号顺序列出，带发言时长和句数；单句改走了所有句子的说话人不列出
    @Test func 列出有句子的说话人() {
        let t = transcript(["spk1", "spk3", "spk1", nil],
                           speakers: [speaker("spk1", "张三", duration: 30), speaker("spk2", duration: 5),
                                      speaker("spk3", duration: 12)])
        #expect(t.speakerList.map(\.speaker.id) == ["spk1", "spk3"])
        #expect(t.speakerList.map(\.sentenceCount) == [2, 1])
        #expect(t.speakerList.map(\.speaker.speechDuration) == [30, 12])
    }

    @Test func 没区分过时没有说话人列表() {
        #expect(transcript([nil], speakers: nil).speakerList.isEmpty)
    }
}

@Suite struct SpeakerRestoreAvailabilityTests {
    @Test func 改过说话人的句子可以恢复() {
        var t = transcript(["spk1", nil, "spk2"], speakers: [speaker("spk1"), speaker("spk2")])
        t.setSpeaker(sentence: "s1", to: "spk2")
        t.setSpeaker(sentence: "s2", to: "spk1")
        #expect(t.canRestoreSpeaker(sentence: "s1"))
        // 原值是未知也可以恢复回未知
        #expect(t.canRestoreSpeaker(sentence: "s2"))
        #expect(!t.canRestoreSpeaker(sentence: "s3"))
    }

    /// 原值那个说话人被合并掉了，写回会是悬空 id，不提供恢复
    @Test func 原说话人已被合并掉时不能恢复() {
        var t = transcript(["spk1", "spk2", "spk3"],
                           speakers: [speaker("spk1"), speaker("spk2"), speaker("spk3")])
        t.setSpeaker(sentence: "s1", to: "spk3")
        t.mergeSpeaker("spk1", into: "spk2")
        #expect(!t.canRestoreSpeaker(sentence: "s1"))
    }
}

@Suite struct SpeakerStatusTests {
    private let diarized = transcript(["spk1", "spk2"], speakers: [speaker("spk1"), speaker("spk2")])
    private let plain = transcript([nil, nil], speakers: nil)

    private func status(transcription: TranscriptionState? = TranscriptionState(status: .done),
                        diarization: DiarizationState? = nil, activity: TranscriptionActivity? = nil,
                        transcript: Transcript?, canDiarize: Bool = true) -> SpeakerStatus {
        SpeakerStatus(transcription: transcription, diarization: diarization, activity: activity,
                      transcript: transcript, canDiarize: canDiarize)
    }

    /// v0.3 的旧会议：有转写稿、没有说话人，给“区分说话人”
    @Test func 旧会议可以补区分说话人() {
        let s = status(transcript: plain)
        #expect(s == .notDiarized)
        #expect(s.actionTitle == "区分说话人")
    }

    /// 没有区分引擎时点了也不会入队，不给按钮
    @Test func 没有引擎时不提供区分说话人() {
        #expect(status(transcript: plain, canDiarize: false) == .hidden)
    }

    /// 判断有没有说话人看转写稿：开关关着重新转写后说话人状态还是旧的 done，但新稿没有说话人
    @Test func 有没有说话人看转写稿不看说话人状态() {
        #expect(status(diarization: .init(status: .done), transcript: diarized) == .done)
        #expect(status(diarization: .init(status: .done), transcript: plain) == .notDiarized)
    }

    @Test func 区分中显示进度() {
        let s = status(diarization: .init(status: .running), activity: .diarizing(0.4), transcript: diarized)
        #expect(s == .diarizing(0.4))
        #expect(s.progress == 0.4)
        #expect(s.isBusy)
        // 管线刚开始、还没有进度
        #expect(status(diarization: .init(status: .running), transcript: plain) == .diarizing(nil))
    }

    /// 完整转写的区分说话人一步不写说话人状态，进行中只靠 activity
    @Test func 完整转写里的区分说话人也显示进度() {
        #expect(status(transcription: .init(status: .running), activity: .diarizing(0.2), transcript: nil)
            == .diarizing(0.2))
    }

    @Test func 排队只区分说话人() {
        let s = status(diarization: .init(status: .queued), transcript: plain)
        #expect(s == .queued)
        #expect(s.text == "等待区分说话人")
        #expect(s.isBusy)
    }

    /// 转写排队或进行中时由转写状态说明，说话人这里不重复
    @Test func 转写中不单独显示说话人状态() {
        #expect(status(transcription: .init(status: .queued), diarization: .init(status: .queued),
                       transcript: diarized) == .hidden)
        #expect(status(transcription: .init(status: .running), activity: .transcribing(0.5),
                       transcript: diarized) == .hidden)
    }

    @Test func 区分失败显示原因和重试() {
        let s = status(diarization: .init(status: .failed, error: "模型加载失败"), transcript: plain)
        #expect(s == .failed("模型加载失败", canRetry: true))
        #expect(s.text == "模型加载失败")
        #expect(s.actionTitle == "重试")
        #expect(!s.isBusy)
        #expect(status(diarization: .init(status: .failed), transcript: plain, canDiarize: false)
            == .failed("区分说话人失败", canRetry: false))
        #expect(status(diarization: .init(status: .failed), transcript: plain, canDiarize: false)
            .actionTitle == nil)
    }

    /// 没有转写稿（没转写过、读不出来）时没什么可区分的
    @Test func 没有转写稿时不显示() {
        #expect(status(transcription: nil, transcript: nil) == .hidden)
        #expect(status(diarization: .init(status: .failed), transcript: nil) == .hidden)
    }
}
