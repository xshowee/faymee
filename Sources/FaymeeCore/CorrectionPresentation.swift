import Foundation

/// 转写稿顶部的纠错状态行（spec「界面」）：只有「已纠错 N 句 · 撤销全部」「纠错失败 · 重试」两种。
/// 排队、进行中显示在会议列表的进度里（纪要前面的一步），不在这里
public enum CorrectionStatus: Hashable, Sendable {
    case hidden
    /// 纠错完成，还有 N 句是纠错改过的
    case corrected(count: Int)
    case failed(reason: String?)

    public init(state: CorrectionState?, transcript: Transcript?) {
        switch state?.status {
        case .failed: self = .failed(reason: state?.error)
        case .done:
            let count = transcript?.correctedCount ?? 0
            self = count > 0 ? .corrected(count: count) : .hidden
        case .queued, .running, nil: self = .hidden
        }
    }

    public var text: String? {
        switch self {
        case .hidden: nil
        case let .corrected(count): "已纠错 \(count) 句"
        case .failed: "纠错失败"
        }
    }

    /// 状态行上的按钮：撤销全部、重试
    public var actionTitle: String? {
        switch self {
        case .hidden: nil
        case .corrected: "撤销全部"
        case .failed: "重试"
        }
    }
}

/// 设置「转写」区域「纠错转写稿」开关下的说明，随纪要引擎变化，不是警示（spec「开关与引擎」）
public enum CorrectionCaption {
    public enum Engine: Hashable, Sendable {
        /// 本机纪要模型，如「Qwen3.5 4B」
        case local(modelName: String)
        /// 在线服务商与模型
        case online(provider: String, model: String)
        /// 纪要模型没下载好，或在线配置没补齐
        case notReady
    }

    public static func text(_ engine: Engine) -> String {
        switch engine {
        case let .local(name): "用纪要模型（本机 \(name)）改正听错的字词；接通电源时才开始"
        case let .online(provider, model): "用纪要模型（在线 · \(provider) \(model)）改正识别错误"
        case .notReady: "纪要模型就绪后才能纠错"
        }
    }
}
