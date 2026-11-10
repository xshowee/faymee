import Foundation

/// 改名的结果
public enum SpeakerRenameResult: Hashable, Sendable {
    case renamed
    /// 名字没变（或说话人不存在），不必写盘
    case unchanged
    /// 新名字是本场另一个说话人的显示名：没有改名，界面提示“合并为同一人”，确认后合并到这个 id
    case needsMerge(into: String)
}

/// 人工修改说话人：改单句的说话人、合并、改名、不是此人。
/// 改完由调用方用 `MeetingStore.saveTranscript` 整份原子写盘。都不改句子文字和时间，所以 `textHash` 不变
extension Transcript {
    /// 单句改过说话人的句子数（合并也记为相关句子的单句修改），重新区分说话人前提示“会丢弃 N 处说话人修改”用。
    /// 重新转写的 `editCount` 已经包含它
    public var speakerEditCount: Int {
        sentences.count { $0.originalSpeaker != nil }
    }

    /// 声纹认错了人：清掉名字、名字来源和声纹库关联，退回“说话人 N”。
    /// 不看名字来源，手动起的名字也一样清掉（按钮只对声纹认出的人显示是界面的事）。
    /// 本来就没有名字、说话人不存在时返回 false
    @discardableResult
    public mutating func rejectRecognizedPerson(_ id: String) -> Bool {
        guard var s = speaker(id), s.name != nil || s.nameSource != nil || s.personID != nil else { return false }
        s.name = nil
        s.nameSource = nil
        s.personID = nil
        replaceSpeaker(s)
        return true
    }

    /// 把某句改给已有的说话人 id。第一次改时把区分结果原值存进 `originalSpeaker`，
    /// 改回原值等于恢复，不再算修改。说话人不在列表里、句子不存在、没有变化时返回 false
    @discardableResult
    public mutating func setSpeaker(sentence id: String, to speaker: String) -> Bool {
        guard self.speaker(speaker) != nil, let i = sentenceIndex(id), case var .sentence(s) = items[i],
              s.speaker != speaker else { return false }
        let original = s.originalSpeaker ?? OriginalSpeaker(speaker: s.speaker)
        s.originalSpeaker = original.speaker == speaker ? nil : original
        s.speaker = speaker
        items[i] = .sentence(s)
        return true
    }

    /// 把某句改给一个新建的说话人，返回新 id；没区分过、句子不存在时返回 nil。
    /// 新说话人没有声纹（空向量，不能登记、不参与识别）、发言时长为 0（时长只来自区分结果），排在列表最后。
    /// 编号大于列表、合并掉的说话人、句子说话人和区分结果原值里出现过的所有编号，不复用合并掉的 id，
    /// 免得原值或纪要负责人记的旧 id 指到新人身上
    @discardableResult
    public mutating func setNewSpeaker(sentence id: String) -> String? {
        guard let merged = diarization.map({ $0.mergedSpeakers ?? [] }), sentenceIndex(id) != nil else { return nil }
        let used = speakers.map(\.id) + merged
            + sentences.flatMap { [$0.speaker, $0.originalSpeaker?.speaker] }.compactMap { $0 }
        let next = (used.compactMap(Self.speakerNumber).max() ?? 0) + 1
        let newID = "spk\(next)"
        diarization?.speakers.append(Speaker(id: newID, voiceprint: Voiceprint([]), speechDuration: 0))
        setSpeaker(sentence: id, to: newID)
        return newID
    }

    /// 把 source 的所有句子并入 target，source 从列表移除，返回是否合并了。
    /// - 每句按单句修改记下区分结果原值；原本属于 target 的句子回到 target 就不再算修改
    /// - target 的声纹按两人发言时长加权平均，时长相加；一方没有声纹（空向量）时用另一方的，
    ///   维数不同（不该发生）时保留 target 的
    /// - 名字：target 有名字就用 target 的，否则用 source 的（连同声纹库关联）；合并后有名字时来源记为 `user`
    /// - 同一个人、任一方不在列表里时返回 false
    @discardableResult
    public mutating func mergeSpeaker(_ source: String, into target: String) -> Bool {
        guard source != target, let from = speaker(source), var into = speaker(target) else { return false }
        for s in sentences where s.speaker == source {
            setSpeaker(sentence: s.id, to: target)
        }
        into.voiceprint = Self.weightedAverage(into.voiceprint, into.speechDuration,
                                               from.voiceprint, from.speechDuration)
        into.speechDuration += from.speechDuration
        if into.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            into.name = from.name
            into.personID = from.personID
        }
        into.nameSource = into.name == nil ? nil : .user
        let merged = (diarization?.mergedSpeakers ?? []) + [source]
        diarization?.speakers.removeAll { $0.id == source }
        diarization?.mergedSpeakers = merged
        replaceSpeaker(into)
        return true
    }

    /// 给说话人改名。名字去首尾空白；清空等于退回“说话人 N”。
    /// - 与本场另一个说话人的显示名（含“说话人 N”）相同时不改，返回 `.needsMerge(into:)`，
    ///   界面确认后调 `mergeSpeaker(id, into:)`
    /// - 改后名字来源记为 `user`，声纹库关联清掉（换了名字就不再是认出的那个人）
    /// - 与自己当前显示名相同、说话人不存在时返回 `.unchanged`
    public mutating func renameSpeaker(_ id: String, to name: String) -> SpeakerRenameResult {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var s = speaker(id) else { return .unchanged }
        if name.isEmpty {
            guard s.name != nil || s.nameSource != nil || s.personID != nil else { return .unchanged }
            s.name = nil
            s.nameSource = nil
        } else {
            guard name != s.displayName else { return .unchanged }
            if let other = speakers.first(where: { $0.id != id && $0.displayName == name }) {
                return .needsMerge(into: other.id)
            }
            s.name = name
            s.nameSource = .user
        }
        s.personID = nil
        replaceSpeaker(s)
        return .renamed
    }

    private mutating func replaceSpeaker(_ s: Speaker) {
        if let i = diarization?.speakers.firstIndex(where: { $0.id == s.id }) {
            diarization?.speakers[i] = s
        }
    }

    private static func weightedAverage(_ a: Voiceprint, _ wa: TimeInterval,
                                        _ b: Voiceprint, _ wb: TimeInterval) -> Voiceprint {
        if b.vector.isEmpty || a.vector.count != b.vector.count && !a.vector.isEmpty { return a }
        if a.vector.isEmpty { return b }
        let total = wa + wb
        let (fa, fb) = total > 0 ? (Float(wa / total), Float(wb / total)) : (0.5, 0.5)
        return Voiceprint(zip(a.vector, b.vector).map { $0 * fa + $1 * fb })
    }

    private static func speakerNumber(_ id: String) -> Int? {
        id.hasPrefix("spk") ? Int(id.dropFirst(3)) : nil
    }

    /// 恢复单句的说话人：写回区分结果原值（可能是未知），句子回到未修改状态。
    /// 没改过的句子不变；原值那个说话人已经被合并掉时也不变（写回会指向不存在的 id），都返回 false
    @discardableResult
    public mutating func restoreSpeaker(sentence id: String) -> Bool {
        guard let i = sentenceIndex(id), case var .sentence(s) = items[i],
              let original = s.originalSpeaker,
              original.speaker.map({ self.speaker($0) != nil }) ?? true else { return false }
        s.speaker = original.speaker
        s.originalSpeaker = nil
        items[i] = .sentence(s)
        return true
    }
}
