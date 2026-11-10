import Foundation

/// 转写、纪要完成或失败时发的系统通知内容；nil 表示不发。通知本身不带声音（会议中不能出声），由 App 负责
public struct MeetingNotice: Hashable, Sendable {
    /// 点通知时要做的事。经通知的 userInfo 传回 App
    public enum Action: String, Hashable, Sendable {
        /// 打开设置里的模型下载
        case openModelDownload

        /// userInfo 里存动作的键
        public static let userInfoKey = "faymee.action"

        /// 从点开的通知的 userInfo 里取动作；不是本类发的、或没有动作时为 nil
        public init?(userInfo: [AnyHashable: Any]) {
            guard let raw = userInfo[Self.userInfoKey] as? String else { return nil }
            self.init(rawValue: raw)
        }
    }

    public var title: String
    public var body: String
    /// 点通知时要做的事；nil 时只是打开 App
    public var action: Action?

    public init(title: String, body: String, action: Action? = nil) {
        self.title = title
        self.body = body
        self.action = action
    }

    /// 放进通知 content.userInfo 的内容，没有动作时为空
    public var userInfo: [String: String] {
        action.map { [Action.userInfoKey: $0.rawValue] } ?? [:]
    }

    /// 转写完成或失败。`minutes` 是转写完成后纪要会怎样（见 `MinutesPipeline.followUp(for:)`）：
    /// - 没排队（不会自动生成）：照旧发“转写完成”
    /// - 排了队、马上就能开始：不发，纪要完成时再发一条，免得一场会连收两条
    /// - 排了队、在等电源或模型：照发，并附一句说明，免得纪要卡在队列里用户不知道；等模型的点开去下载
    public static func transcription(_ outcome: TranscriptionOutcome, meetingTitle: String,
                                     isRecording: Bool, minutes: MinutesFollowUp = .notQueued) -> MeetingNotice? {
        // 正在录音说明在开会，转写的消息不值得打断，详情页里能看到状态
        guard !isRecording else { return nil }
        switch outcome {
        case .done:
            switch minutes {
            case .notQueued:
                return MeetingNotice(title: "转写完成", body: meetingTitle)
            case .queued(waitingFor: .model):
                return MeetingNotice(title: "转写完成", body: "\(meetingTitle)\n生成纪要需要先下载模型",
                                     action: .openModelDownload)
            case .queued(waitingFor: .power):
                return MeetingNotice(title: "转写完成", body: "\(meetingTitle)\n接通电源后生成纪要")
            case .queued(waitingFor: .transcription), .queued(waitingFor: nil):
                return nil
            }
        case let .failed(reason):
            return MeetingNotice(title: "转写失败", body: "\(meetingTitle)：\(reason)")
        }
    }

    /// 纪要生成完成或失败。完成时标题带待办条数（待办节里没删除的条目），没有待办时写“没有待办”
    public static func minutes(_ outcome: MinutesOutcome, meetingTitle: String,
                               isRecording: Bool) -> MeetingNotice? {
        guard !isRecording else { return nil }
        switch outcome {
        case let .done(minutes):
            let actions = minutes.sections.filter { $0.kind == .actions }
                .flatMap(\.items).count { !$0.deleted }
            let summary = actions == 0 ? "没有待办" : "\(actions) 条待办"
            return MeetingNotice(title: "纪要已生成：\(summary)", body: meetingTitle)
        case let .failed(reason):
            return MeetingNotice(title: "纪要生成失败", body: "\(meetingTitle)：\(reason)")
        }
    }
}

/// 转写完成后，这场会议的纪要接下来会怎样，用来决定转写通知
public enum MinutesFollowUp: Hashable, Sendable {
    /// 不在纪要队列里：不会自动生成（开关关、内容太少、有人工改动）
    case notQueued
    /// 在纪要队列里（或正在生成）。`waitingFor` 同 `MinutesPipeline.waitReason(for:)`：
    /// `.model`、`.power` 需要用户处理；`.transcription` 或 nil 表示很快就会开始
    case queued(waitingFor: MinutesWaitReason?)
}
