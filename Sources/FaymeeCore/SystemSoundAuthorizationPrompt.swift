import Foundation

/// 录音前打开开关时，为弹出“系统录音”授权框而建的采集（tap + 只含 tap 的聚合设备 + 不启动的空 IOProc）保留多久
/// （spec 用户故事 6）。
///
/// 建完马上拆掉的话，授权框还开着，用户之后点的“允许”没有被记住（ticket 15）。所以建好后一直保留，
/// 每隔 `recheckInterval` 用子进程查一次授权，查到不再是未决定（用户点了按钮）、或建好后超过 `maximumHold`，
/// 才拆掉。授权框在建 IOProc 时弹出，建立通常卡到用户回答才返回，也可能马上返回，两种情况都在建好后马上查第一次。
///
/// 在等的期间，录音中的采集尝试（开始录音、重试、重建）不自己查授权、不另建，等这里有结果再说
/// （`capturesWait`），不然会弹第二个授权框。App 负责建、拆、查子进程、计时，这里只做判断
public struct SystemSoundAuthorizationPrompt: Equatable, Sendable {
    /// 仍是未决定时，隔多久再用子进程查一次
    public static let recheckInterval: TimeInterval = 1
    /// 建好后最多保留多久，到时拆掉，按未决定处理
    public static let maximumHold: TimeInterval = 120

    /// 用子进程查到授权之后该做什么
    public enum Step: Equatable, Sendable {
        /// 用户还没回答：保留采集，隔这么久再查
        case recheck(after: TimeInterval)
        /// 拆掉采集，带上结果：已授权、拒绝，或一直没回答（超时，未决定）
        case release(SystemSoundAuthorization)
    }

    /// 在等授权框：从开始建立到拆掉
    public private(set) var isPending = false
    /// 建好的时刻，超时从这里算起
    private var heldSince: Date?

    public init() {}

    /// 采集尝试（开始录音、重试、重建）要不要先等授权框有结果，而不是自己查授权、建立
    public var capturesWait: Bool { isPending }

    /// 开始建弹框用的采集
    public mutating func begin() {
        isPending = true
        heldSince = nil
    }

    /// 建好了（建立返回，可能已经等用户回答过）。接着马上用子进程查第一次
    public mutating func held(at date: Date) {
        heldSince = date
    }

    /// 建不起来：没有在等的授权框（开始录音时照常按建立失败处理）
    public mutating func holdFailed() {
        isPending = false
        heldSince = nil
    }

    /// 关掉开关：不再等，App 拆掉采集
    public mutating func cancel() {
        isPending = false
        heldSince = nil
    }

    /// 子进程查到的授权。已授权或拒绝就拆掉；仍是未决定时，建好未满 `maximumHold` 就保留、过一会儿再查，
    /// 满了就拆掉、按未决定处理
    public mutating func checked(_ authorization: SystemSoundAuthorization, at date: Date) -> Step {
        let expired = heldSince.map { date.timeIntervalSince($0) >= Self.maximumHold } ?? false
        guard authorization == .undetermined, !expired else {
            isPending = false
            heldSince = nil
            return .release(authorization)
        }
        return .recheck(after: Self.recheckInterval)
    }
}
