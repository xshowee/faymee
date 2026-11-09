import Foundation

/// 转写完成或失败时发的系统通知内容；nil 表示不发。通知本身不带声音（会议中不能出声），由 App 负责
public struct TranscriptionNotice: Hashable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    public static func make(for outcome: TranscriptionOutcome, meetingTitle: String,
                            isRecording: Bool) -> TranscriptionNotice? {
        // 正在录音说明在开会，转写的消息不值得打断，详情页里能看到状态
        guard !isRecording else { return nil }
        return switch outcome {
        case .done:
            TranscriptionNotice(title: "转写完成", body: meetingTitle)
        case let .failed(reason):
            TranscriptionNotice(title: "转写失败", body: "\(meetingTitle)：\(reason)")
        }
    }
}
