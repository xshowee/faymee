import Foundation

/// 详情页转写稿标题旁的状态。由会议上的持久状态和管线的内存状态派生，不写盘
public enum TranscriptionStatus: Hashable, Sendable {
    /// 从未转写（v0.1 旧会议）
    case notTranscribed
    /// 排队中，附上在等什么；只是排在别的会议后面或录音暂停时为 nil
    case queued(TranscriptionWaitReason?)
    case preparing(Double)
    /// 转写中；刚开始或暂停瞬间还没有进度时为 nil
    case transcribing(Double?)
    /// 正在区分说话人（由 `SpeakerStatus` 显示，转写状态不重复显示）
    case diarizing
    case failed(String)
    case done

    /// - Parameters:
    ///   - state: `meeting.transcription`
    ///   - activity: `TranscriptionPipeline.activity(for:)`，有值时以它为准（磁盘上的状态可能还没跟上）
    ///   - waitReason: `TranscriptionPipeline.waitReason(for:)`
    public init(state: TranscriptionState?, activity: TranscriptionActivity?,
                waitReason: TranscriptionWaitReason?) {
        switch (activity, state?.status) {
        case let (.preparing(p)?, _): self = .preparing(p)
        case let (.transcribing(p)?, _): self = .transcribing(p)
        case (.diarizing?, _): self = .diarizing
        case (nil, nil): self = .notTranscribed
        case (nil, .queued): self = .queued(waitReason)
        case (nil, .running): self = .transcribing(nil)
        case (nil, .failed): self = .failed(state?.error ?? "转写失败")
        case (nil, .done): self = .done
        }
    }

    public var text: String? {
        switch self {
        case .notTranscribed, .diarizing, .done: nil
        case .queued(nil): "排队中"
        case .queued(.onlineConfig): "等待配置在线转写"
        case .queued(.modelDownload): "等待下载转写模型"
        case let .preparing(p): "正在准备转写引擎（\(formatPercent(p))）"
        case let .transcribing(p?): "转写中 \(formatPercent(p))"
        case .transcribing(nil): "转写中…"
        case let .failed(error): error
        }
    }

    public var actionTitle: String? {
        switch self {
        case .notTranscribed: "转写"
        case .queued(.onlineConfig): "前往设置"
        case .failed: "重试"
        default: nil
        }
    }

    /// 点击按钮是否打开设置窗口（等待配置在线转写时），而不是触发转写
    public var opensSettings: Bool {
        self == .queued(.onlineConfig)
    }

    public var progress: Double? {
        switch self {
        case let .preparing(p): p
        case let .transcribing(p): p
        default: nil
        }
    }
}

extension Transcript {
    /// 在线转写来源标识；本机转写引擎（`apple/`、本机模型目录里的 `sherpa-onnx/`）或为空时返回 nil，界面不显示。
    /// 按前缀而不按目录判断：目录以后删掉的模型，旧转写稿照样认作本机
    public var onlineEngineLabel: String? {
        engine.isEmpty || Self.localEnginePrefixes.contains { engine.hasPrefix($0) } ? nil : engine
    }

    static let localEnginePrefixes = ["apple/", "sherpa-onnx/"]
}
