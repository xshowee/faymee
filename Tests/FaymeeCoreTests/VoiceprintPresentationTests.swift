import Foundation
import Testing
@testable import FaymeeCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// 一场会议的转写稿，只关心说话人列表
private func meeting(model: String = "vp-a", _ speakers: [Speaker]) -> Transcript {
    Transcript(engine: "test", createdAt: t0, hotwords: [], items: [],
               diarization: Diarization(engine: "fake", voiceprintModel: model, speakersCreatedAt: t0,
                                        speakers: speakers))
}

private func zhang(_ vector: [Float] = [1, 0], duration: TimeInterval = 30,
                   source: SpeakerNameSource = .user) -> Speaker {
    Speaker(id: "spk2", name: "张三", nameSource: source, voiceprint: Voiceprint(vector), speechDuration: duration)
}

private func sample(_ vector: [Float], meeting: String) -> VoiceprintSample {
    VoiceprintSample(voiceprint: Voiceprint(vector), meetingID: meeting, speechDuration: 20, addedAt: t0)
}

/// 说话人菜单里“记住这个声音”一项：标题、能不能点、不能点的原因
@Suite struct 记住这个声音的菜单项 {
    private func option(_ t: Transcript, library: VoiceprintLibrary = VoiceprintLibrary(),
                        current: String? = "vp-a") -> VoiceprintEnrollmentOption {
        library.enrollmentOption(speaker: "spk2", in: t, meetingID: "m1", currentVoiceprintModel: current)
    }

    @Test func 声纹库里还没有此人时是记住这个声音() {
        let o = option(meeting([zhang()]))
        #expect(o.title == "记住这个声音")
        #expect(o.isEnabled)
        #expect(o.unavailableReason == nil)
    }

    @Test func 有效发言不足时不能点并说明原因() {
        let o = option(meeting([zhang(duration: 6.5)]))
        #expect(o.title == "记住这个声音")
        #expect(!o.isEnabled)
        #expect(o.unavailableReason == "张三在这场会议里的有效发言只有 6 秒，至少需要 10 秒才能记住声音")
    }

    @Test func 没命名的说话人不能点() {
        let t = meeting([Speaker(id: "spk2", voiceprint: Voiceprint([1, 0]), speechDuration: 30)])
        #expect(option(t).unavailableReason == "先给这个说话人起名字，再记住声音")
    }

    /// 声纹认出的人、或手动起了声纹库里已有的名字：在不同会议里多加一份样本
    @Test func 声纹库里已有同名的人时是把本场声音也加进去() {
        let library = VoiceprintLibrary(people: [
            VoiceprintPerson(id: "p1", name: "张三", voiceprintModel: "vp-a", samples: [sample([0, 1], meeting: "m0")]),
        ])
        let o = option(meeting([zhang(source: .voiceprint)]), library: library)
        #expect(o.title == "把本场声音也加进去")
        #expect(o.isEnabled)
    }

    /// 与登记一样按名字找人：声纹库里改过名后，认出时的名字已不在库里，点了会新建
    @Test func 按名字找人不看声纹库关联() {
        let library = VoiceprintLibrary(people: [
            VoiceprintPerson(id: "p1", name: "张三丰", voiceprintModel: "vp-a", samples: [sample([0, 1], meeting: "m0")]),
        ])
        var recognized = zhang(source: .voiceprint)
        recognized.personID = "p1"
        #expect(option(meeting([recognized]), library: library).title == "记住这个声音")
    }

    @Test func 本场声音已经加过时不能再点() {
        let library = VoiceprintLibrary(people: [
            VoiceprintPerson(id: "p1", name: "张三", voiceprintModel: "vp-a", samples: [sample([1, 0], meeting: "m1")]),
        ])
        let o = option(meeting([zhang([1, 0])]), library: library)
        #expect(o.title == "已记住本场声音")
        #expect(!o.isEnabled)
        #expect(o.unavailableReason == nil)
    }

    /// 登记后又合并了说话人，声纹变了：再加一次会替换本场原来的样本
    @Test func 加过之后本场声音变了可以再加() {
        let library = VoiceprintLibrary(people: [
            VoiceprintPerson(id: "p1", name: "张三", voiceprintModel: "vp-a", samples: [sample([1, 0], meeting: "m1")]),
        ])
        let o = option(meeting([zhang([0.5, 0.5])]), library: library)
        #expect(o.title == "把本场声音也加进去")
        #expect(o.isEnabled)
    }

    /// 同名的人只有旧声纹模型的样本：点了等于重新登记
    @Test func 同名的人声纹模型不同时是记住这个声音() {
        let library = VoiceprintLibrary(people: [
            VoiceprintPerson(id: "p1", name: "张三", voiceprintModel: "vp-old", samples: [sample([1, 0], meeting: "m1")]),
        ])
        let o = option(meeting([zhang([1, 0])]), library: library)
        #expect(o.title == "记住这个声音")
        #expect(o.isEnabled)
    }

    /// 旧引擎区分的会议：登记进去的声纹与以后的会议不可比，同名的人还会因换模型被清掉现有样本
    @Test func 转写稿的声纹模型与当前引擎不同时不能点() {
        let library = VoiceprintLibrary(people: [
            VoiceprintPerson(id: "p1", name: "张三", voiceprintModel: "vp-a", samples: [sample([0, 1], meeting: "m0")]),
        ])
        let o = option(meeting(model: "vp-old", [zhang()]), library: library, current: "vp-a")
        #expect(!o.isEnabled)
        #expect(o.unavailableReason == "这场会议的说话人是用旧的引擎区分的，重新区分说话人后才能记住声音")
    }

    /// 不知道当前引擎（没有区分引擎）时不拦
    @Test func 不知道当前声纹模型时照常可以登记() {
        #expect(option(meeting(model: "vp-old", [zhang()]), current: nil).isEnabled)
    }
}
