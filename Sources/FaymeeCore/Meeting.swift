import Foundation

public enum MeetingStatus: String, Codable, Sendable {
    /// 正在录音。App 启动时仍处于此状态的会议，说明上次录音被中断（崩溃、强退、断电）
    case recording
    /// 录音已结束，正在把分片合并压缩为 recording.m4a
    case finalizing
    case done
    case failed
}

/// 一个录音分片。录音按固定时长切成多个 CAF 文件，崩溃时最多损失最后一个分片尚未落盘的几秒
public struct Segment: Codable, Hashable, Sendable {
    public var file: String
    public var startedAt: Date
    public var sampleRate: Double
    public var channels: Int
    public var device: String
    public var deviceUID: String?
    /// 在 recording.m4a 中的起点（秒），整理成功时写入。v0.1 的旧会议没有此字段
    public var offset: TimeInterval?
    /// 实际并入 recording.m4a 的音频时长（秒），被整理跳过的分片为 0。v0.1 的旧会议没有此字段
    public var duration: TimeInterval?

    public init(file: String, startedAt: Date, sampleRate: Double, channels: Int,
                device: String, deviceUID: String?,
                offset: TimeInterval? = nil, duration: TimeInterval? = nil) {
        self.file = file
        self.startedAt = startedAt
        self.sampleRate = sampleRate
        self.channels = channels
        self.device = device
        self.deviceUID = deviceUID
        self.offset = offset
        self.duration = duration
    }
}

public enum GapReason: String, Codable, Sendable {
    /// 合盖导致内置麦克风被硬件断开
    case lidClosed
}

/// 录音时间线上没有收到有效声音的一段。录音文件里这段是静音，
/// 记录下来以便回放、转写和摘要时标出“这里没录到”，而不是一段说不清的空白
public struct Gap: Codable, Hashable, Sendable {
    public var start: Date
    /// nil 表示仍在持续
    public var end: Date?
    public var reason: GapReason

    public init(start: Date, end: Date? = nil, reason: GapReason) {
        self.start = start
        self.end = end
        self.reason = reason
    }
}

public struct Meeting: Codable, Identifiable, Hashable, Sendable {
    /// 同时也是会议目录名
    public var id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: MeetingStatus
    public var segments: [Segment] = []
    /// 合并后的录音文件名（相对会议目录）
    public var recording: String?
    public var duration: TimeInterval?
    public var error: String?
    /// 可选是为了兼容没有此字段的旧 meeting.json，读写请用 lidGaps
    public var gaps: [Gap]?
    /// 转写状态，nil 表示从未转写（含 v0.1 的旧会议）。转写内容在 transcript.json，不在这里
    public var transcription: TranscriptionState?

    public var lidGaps: [Gap] {
        get { gaps ?? [] }
        set { gaps = newValue }
    }

    public var openGap: Int? { lidGaps.lastIndex { $0.end == nil } }
}

/// 转写是建立在录音之上的独立流程，不并入 MeetingStatus：
/// 那个表示录音本身的状态（done 意味着可以回放），转写失败不影响回放
public struct TranscriptionState: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case queued, running, done, failed
    }

    public var status: Status
    /// 失败原因，给用户看
    public var error: String?

    public init(status: Status, error: String? = nil) {
        self.status = status
        self.error = error
    }
}

public func formatTimeRange(_ gap: Gap) -> String {
    let start = gap.start.formatted(date: .omitted, time: .shortened)
    guard let end = gap.end else { return "\(start) 起" }
    return "\(start)–\(end.formatted(date: .omitted, time: .shortened))（\(formatDuration(end.timeIntervalSince(gap.start)))）"
}

public func formatDuration(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    let h = s / 3600, m = s / 60 % 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}
