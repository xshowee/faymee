import Foundation

extension Transcript {
    /// 区分说话人之后认出声纹库里的人：把名字写到说话人上，来源 `voiceprint`，记下人员 id。
    /// 匹配规则（模型过滤、阈值、一人一个、不覆盖手动名字）见 `VoiceprintLibrary.match`。
    ///
    /// 没被认出的说话人保持原样，包括重新区分时沿用来的声纹名字（声纹库删了此人也不改写已经显示的名字）；
    /// 只有它对应的人（同一人员 id，或同名）这次认给了别的说话人时清掉，退回“说话人 N”，一场里不出现两个同一人
    public func recognizingSpeakers(with library: VoiceprintLibrary,
                                    threshold: Float = VoiceprintLibrary.defaultMatchThreshold) -> Transcript {
        guard let diarization else { return self }
        let matches = Dictionary(
            library.match(diarization.speakers, voiceprintModel: diarization.voiceprintModel, threshold: threshold)
                .map { ($0.speakerID, $0) }) { a, _ in a }
        let recognized = Set(matches.values.map(\.personID))
        let recognizedNames = Set(matches.values.map(\.name))
        func takenByOthers(_ s: Speaker) -> Bool {
            if let p = s.personID, recognized.contains(p) { return true }
            guard let name = s.name?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return recognizedNames.contains(name)
        }
        var out = self
        for (i, speaker) in diarization.speakers.enumerated() {
            if let m = matches[speaker.id] {
                out.diarization!.speakers[i].name = m.name
                out.diarization!.speakers[i].nameSource = .voiceprint
                out.diarization!.speakers[i].personID = m.personID
            } else if speaker.nameSource == .voiceprint, takenByOthers(speaker) {
                out.diarization!.speakers[i].name = nil
                out.diarization!.speakers[i].nameSource = nil
                out.diarization!.speakers[i].personID = nil
            }
        }
        return out
    }
}
