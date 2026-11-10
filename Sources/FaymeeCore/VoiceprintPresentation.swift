import Foundation

/// 说话人菜单里登记声纹的一项。登记只在用户点它时发生
public struct VoiceprintEnrollmentOption: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// 声纹库里还没有这个名字的人（或只有旧声纹模型的样本，点了等于重新登记）
        case remember
        /// 声纹库里已有同名的人，本场的声音还没加过（或加过之后合并说话人、声音变了）
        case addSample
        /// 本场这个声音已经在此人的样本里
        case added
    }

    public var kind: Kind
    /// 不能登记的原因，菜单里显示在这一项下面；nil 表示可以点
    public var unavailableReason: String?

    public var title: String {
        switch kind {
        case .remember: "记住这个声音"
        case .addSample: "把本场声音也加进去"
        case .added: "已记住本场声音"
        }
    }

    public var isEnabled: Bool { kind != .added && unavailableReason == nil }
}

extension VoiceprintLibrary {
    /// 某场会议里一个说话人的“记住这个声音”菜单项。
    /// 与 `enroll` 一样按名字（去首尾空白）找声纹库里的人，不看说话人上的声纹库关联：
    /// 声纹库改名不回写会议，按关联找会出现“说加进去、实际新建”
    public func enrollmentOption(speaker id: String, in transcript: Transcript, meetingID: String,
                                 currentVoiceprintModel: String?) -> VoiceprintEnrollmentOption {
        // 在副本上试登记一次：菜单的判断与真正登记同一套规则
        var trial = self
        var reason: String?
        do {
            try trial.enroll(speaker: id, from: transcript, meetingID: meetingID, newID: { "" })
        } catch {
            reason = error.localizedDescription
        }
        let speaker = transcript.speaker(id)
        let name = speaker?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = transcript.diarization?.voiceprintModel
        // 旧引擎区分的会议：声纹与以后的会议不可比，登记进同名的人还会清掉他现有的样本
        if reason == nil, let currentVoiceprintModel, let model, model != currentVoiceprintModel {
            reason = "这场会议的说话人是用旧的引擎区分的，重新区分说话人后才能记住声音"
        }
        guard let speaker, let person = people.first(where: { $0.name == name }), person.voiceprintModel == model else {
            return VoiceprintEnrollmentOption(kind: .remember, unavailableReason: reason)
        }
        if person.samples.contains(where: { $0.meetingID == meetingID && $0.voiceprint == speaker.voiceprint }) {
            return VoiceprintEnrollmentOption(kind: .added)
        }
        return VoiceprintEnrollmentOption(kind: .addSample, unavailableReason: reason)
    }
}
