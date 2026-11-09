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

    public init(file: String, startedAt: Date, sampleRate: Double, channels: Int,
                device: String, deviceUID: String?) {
        self.file = file
        self.startedAt = startedAt
        self.sampleRate = sampleRate
        self.channels = channels
        self.device = device
        self.deviceUID = deviceUID
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

    public var lidGaps: [Gap] {
        get { gaps ?? [] }
        set { gaps = newValue }
    }

    public var openGap: Int? { lidGaps.lastIndex { $0.end == nil } }
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
