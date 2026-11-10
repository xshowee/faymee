import Foundation

/// 转写稿里一段的段首：相邻同一说话人的句子归成一段，名字和颜色只在段首显示一次
public struct SpeakerTurn: Hashable, Sendable {
    /// nil 表示未知（没有说话人，或指向已不在列表里的说话人）
    public var speakerID: String?
    public var name: String
    /// 调色板下标，见 `Speaker.colorIndex`；未知为 nil（界面用中性色）
    public var colorIndex: Int?
    /// 名字是声纹自动认出的，段首带一个不显眼的“自动认出”标记
    public var isRecognized = false
    /// 这个说话人第一次开口的一段（未知不算）。姓名建议只挂在这里，不在每一段都重复
    public var isFirstOfSpeaker = false
}

extension Transcript {
    /// 与 `items` 一一对应：一段的第一句为该段的段首，其余句子和合盖空白为 nil。
    /// 合盖空白打断段落，空白之后即使还是同一人也重新显示段首。
    /// 不显示说话人（`showsSpeakers` 为 false）时全为 nil
    public var speakerTurns: [SpeakerTurn?] {
        guard showsSpeakers else { return Array(repeating: nil, count: items.count) }
        let byID = Dictionary(speakers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var previous: String??
        var seen = Set<String>()
        return items.map { item in
            guard case let .sentence(s) = item else {
                previous = nil
                return nil
            }
            let speaker = s.speaker.flatMap { byID[$0] }
            defer { previous = .some(speaker?.id) }
            if let previous, previous == speaker?.id { return nil }
            return SpeakerTurn(speakerID: speaker?.id, name: speaker?.displayName ?? Speaker.unknownName,
                               colorIndex: speaker?.colorIndex, isRecognized: speaker?.isRecognized ?? false,
                               isFirstOfSpeaker: speaker.map { seen.insert($0.id).inserted } ?? false)
        }
    }
}

/// 详情页说话人列表的一项
public struct SpeakerListEntry: Hashable, Sendable {
    public var speaker: Speaker
    /// 当前归给他的句数
    public var sentenceCount: Int
}

extension Transcript {
    /// 详情页的说话人列表，按编号顺序（第一次开口的先后）。
    /// 一句都没有的说话人（单句改走了他所有的句子）不列出：他还留在数据里，供“恢复”写回
    public var speakerList: [SpeakerListEntry] {
        var counts: [String: Int] = [:]
        for s in sentences { if let id = s.speaker { counts[id, default: 0] += 1 } }
        return speakers.compactMap { s in
            counts[s.id].map { SpeakerListEntry(speaker: s, sentenceCount: $0) }
        }
    }
}

extension Transcript {
    /// 单句菜单里要不要给“恢复说话人”：改过说话人，且原值是未知或原说话人还在（没被合并掉）。
    /// 与 `restoreSpeaker(sentence:)` 能不能成功同一个判断。界面每行都会问，不复制转写稿
    public func canRestoreSpeaker(sentence id: String) -> Bool {
        guard let i = sentenceIndex(id), case let .sentence(s) = items[i], let original = s.originalSpeaker else {
            return false
        }
        return original.speaker.map { speaker($0) != nil } ?? true
    }
}

/// 详情页转写稿标题行里的说话人状态
public enum SpeakerStatus: Hashable, Sendable {
    /// 不显示：没有转写稿、转写排队或进行中（由转写状态说明）、没有区分引擎又从未区分过
    case hidden
    /// 有转写稿、没有说话人（v0.3 旧会议、开关关着转写的），可以补区分
    case notDiarized
    /// 排队只区分说话人
    case queued
    /// 区分中；刚开始、还没有进度时为 nil
    case diarizing(Double?)
    /// 区分失败。没有区分引擎时不能重试
    case failed(String, canRetry: Bool)
    /// 转写稿有说话人
    case done

    /// - Parameters:
    ///   - transcription: `meeting.transcription`
    ///   - diarization: `meeting.diarization`
    ///   - activity: `TranscriptionPipeline.activity(for:)`，区分中以它的进度为准
    ///   - transcript: 当前转写稿，没有或读不出来时为 nil（没什么可区分的，不显示）。
    ///     有没有说话人看 `diarization`：管线保存转写稿时同步更新它，完成即新稿有说话人
    ///   - canDiarize: 有没有区分引擎
    public init(transcription: TranscriptionState?, diarization: DiarizationState?,
                activity: TranscriptionActivity?, transcript: Transcript?, canDiarize: Bool) {
        if case let .diarizing(p)? = activity { self = .diarizing(p); return }
        if activity != nil { self = .hidden; return }
        switch transcription?.status {
        case .queued, .running: self = .hidden; return
        case nil, .done, .failed: break
        }
        switch diarization?.status {
        case .queued: self = .queued; return
        case .running: self = .diarizing(nil); return
        case nil, .done, .failed: break
        }
        guard transcript != nil else { self = .hidden; return }
        switch diarization?.status {
        case .failed: self = .failed(diarization?.error ?? "区分说话人失败", canRetry: canDiarize)
        case .done: self = .done
        default: self = canDiarize ? .notDiarized : .hidden
        }
    }

    public var text: String? {
        switch self {
        case .queued: "等待区分说话人"
        case let .diarizing(p?): "区分说话人中 \(formatPercent(p))"
        case .diarizing(nil): "区分说话人中…"
        case let .failed(error, _): error
        case .hidden, .notDiarized, .done: nil
        }
    }

    public var actionTitle: String? {
        switch self {
        case .notDiarized: "区分说话人"
        case .failed(_, canRetry: true): "重试"
        default: nil
        }
    }

    public var progress: Double? {
        if case let .diarizing(p) = self { p } else { nil }
    }

    /// 排队或区分中：结束时说话人整体替换（单句修改、合并都会清掉），这期间不能改说话人
    public var isBusy: Bool {
        switch self {
        case .queued, .diarizing: true
        default: false
        }
    }
}

extension Speaker {
    /// 名字是声纹自动认出的（机器判断，可能出错）：界面带“自动认出”标记，菜单里有“不是此人”
    public var isRecognized: Bool { nameSource == .voiceprint }

    /// 调色板下标，取自 id 的编号（spk1 → 0、spk3 → 2），不随列表位置变：
    /// 合并、新建说话人后其他人的颜色不变。界面按调色板长度取模
    public var colorIndex: Int {
        guard id.hasPrefix("spk"), let n = Int(id.dropFirst(3)), n > 0 else { return 0 }
        return n - 1
    }
}
