import Foundation

/// “系统录音”授权的查询结果。查询接口取不到时按未决定处理（照常建，由系统弹授权框）
public enum SystemSoundAuthorization: Sendable {
    case authorized
    case denied
    case undetermined
}

/// 授权在子进程里查（spec「录音中的行为」）：`TCCAccessPreflight` 的结果在调用它的进程里缓存，
/// 本进程查不到之后的变化。App 用自己的可执行文件带 `queryArgument` 起一个短命子进程，子进程只查授权、
/// 把 `childOutput` 写到 stdout 就退出；主进程用 `init(childOutput:exitStatus:)` 解析
extension SystemSoundAuthorization {
    /// 子进程模式的命令行参数：带着它启动时只查授权，不启动界面、不初始化别的
    public static let queryArgument = "--query-system-sound-authorization"

    /// 子进程里：按 `TCCAccessPreflight("kTCCServiceAudioCapture")` 的返回值（0 = 已授权，1 = 拒绝，
    /// 2 = 未决定）。接口取不到（nil）或返回别的值都按未决定
    public init(preflightResult: Int32?) {
        switch preflightResult {
        case 0: self = .authorized
        case 1: self = .denied
        default: self = .undetermined
        }
    }

    /// 子进程写到 stdout 的一行
    public var childOutput: String {
        switch self {
        case .authorized: "authorized"
        case .denied: "denied"
        case .undetermined: "undetermined"
        }
    }

    /// 主进程里解析子进程的结果。子进程没跑起来、超时被杀（都传 nil）、退出码不是 0、输出不是恰好一个
    /// 认得的结果，都按未决定：不判为不可用
    public init(childOutput: String?, exitStatus: Int32?) {
        guard exitStatus == 0, let text = childOutput?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            self = .undetermined
            return
        }
        self = [Self.authorized, .denied].first { $0.childOutput == text } ?? .undetermined
    }
}

/// 系统声音为什么不可用
public enum SystemSoundUnavailableReason: Equatable, Sendable {
    /// 授权查询为拒绝。定时用子进程重查，查到已授权就重建采集，不用重新打开 Faymee
    case notAuthorized
    /// tap、聚合设备、IOProc、启动任一步出错
    case startFailed
    /// 运行中聚合设备失效（`kAudioDevicePropertyDeviceIsAlive` 变为 0）
    case deviceLost

    /// 菜单栏面板里的说明
    public var menuText: String {
        switch self {
        case .notAuthorized:
            "系统声音不可用：没有“系统录音”授权。请到“系统设置 › 隐私与安全性 › 录屏与系统录音”里打开 Faymee，"
                + "打开后自动恢复。麦克风照常在录。"
        case .startFailed, .deviceLost:
            "系统声音不可用，正在自动重试。麦克风照常在录。"
        }
    }

    /// 不在录音时菜单栏面板里的说明：和录音中一样，只是不说麦克风在录
    public var idleMenuText: String {
        switch self {
        case .notAuthorized:
            "系统声音不可用：没有“系统录音”授权。请到“系统设置 › 隐私与安全性 › 录屏与系统录音”里打开 Faymee。"
        case .startFailed, .deviceLost:
            "系统声音不可用。"
        }
    }

    /// 通知的标题和正文（无声，只在屏幕可见时发）
    public var notice: (title: String, body: String) {
        switch self {
        case .notAuthorized:
            ("系统声音不可用", "没有“系统录音”授权，只录到麦克风。可以在系统设置 › 隐私与安全性 › 录屏与系统录音里打开 Faymee，"
                + "打开后自动恢复。")
        case .startFailed, .deviceLost:
            ("系统声音不可用", "暂时只录到麦克风，恢复后自动接着录系统声音。")
        }
    }
}

/// 不在录音时打开系统声音开关要做的事（spec 用户故事 6、7）：录音前就弹授权框、就说没有授权，
/// 不等到开始录音。只看此刻的授权查询结果；关掉开关时 App 清掉这里给出的提示
public enum SystemSoundSwitchOn: Equatable, Sendable {
    /// 已授权：什么都不做
    case nothing
    /// 未决定：让系统弹出“系统录音”授权框（App 建一次采集、含不启动的 IOProc，保留到用户回答，不录、不写盘；
    /// 见 `SystemSoundAuthorizationPrompt`）
    case requestAuthorization
    /// 菜单栏面板提示系统声音不可用。录音前不开不可用时段：还没有会议
    case showUnavailable(SystemSoundUnavailableReason)

    public init(authorization: SystemSoundAuthorization) {
        switch authorization {
        case .authorized: self = .nothing
        case .undetermined: self = .requestAuthorization
        case .denied: self = .showUnavailable(.notAuthorized)
        }
    }

    /// 要在面板里提示的不可用原因，没有为 nil
    public var unavailableReason: SystemSoundUnavailableReason? {
        if case let .showUnavailable(reason) = self { reason } else { nil }
    }
}

/// 录音中系统声音那一路是否可用、要不要重试（判断规则见 spec「实现决定 › 录音中的行为」）。
///
/// 判断可用与否的输入只有四种：每次开始采集前的授权查询结果、建立的结果、未决定时建好后复查的授权、运行中设备失效。
/// 没有回调、回调全零都不是输入：没有声音播放时本来就没有回调，播放过之后没声音时回调全零，没有授权时也只是全零，
/// 判断不了。授权要在子进程里查（本进程的查询会缓存），App 负责查，这里只看结果。
/// 一次尝试分几步、中间要等（起子进程查授权、建立可能卡在授权框上）：`beginAttempt` → `shouldStart` →
/// `started` / `startFailed`，结果出来之前不开始下一次。
/// 另外管两件跟着建立走的事：什么时候提醒（`takeNotice`）、tap 格式变化后什么时候重建（`formatChanged`）。
/// 每次录音（或每次打开开关）用一个新的值
public struct SystemSoundAvailability: Equatable, Sendable {
    /// 不可用时定时重试（没有授权时是定时重查授权）的间隔
    public static let retryInterval: TimeInterval = 10
    /// 设备变化触发的重试、tap 格式变化触发的重建，与上次尝试至少隔开这么久：私有聚合设备建了又拆本身就会触发
    /// 设备列表变化，新建的 tap 也可能马上又报格式变化
    public static let minimumRetrySpacing: TimeInterval = 2

    /// nil 表示可用（或还没开始）
    public private(set) var unavailableReason: SystemSoundUnavailableReason?
    /// 建好时授权还是未决定（建立时系统弹了授权框）：建好后要用子进程再查一次，见 `authorizationResolved`
    public private(set) var awaitsAuthorization = false
    /// 上次开始（或重试）采集的时刻
    public private(set) var lastAttempt: Date?
    /// 有一次尝试开始了、还没有结果（在查授权或在建立）
    public private(set) var isAttempting = false
    private var pendingAuthorization: SystemSoundAuthorization?
    /// 这次不可用已经提醒过（恢复可用时复位）
    private var noticeGiven = false
    /// 设备失效后在马上重建，结果出来之前先不提醒
    private var noticeHeld = false
    /// tap 格式变了、还没重建（离上次尝试太近，等定时检查补一次）
    private var formatRebuildPending = false

    public init() {}

    public var isAvailable: Bool { unavailableReason == nil }

    /// 开始（或重试、重建）采集，在查授权之前调用。重试的间隔从这里算起
    public mutating func beginAttempt(at date: Date) {
        lastAttempt = date
        isAttempting = true
        // 每次建立都按当时的格式读，格式变化等着补的重建不用再做
        formatRebuildPending = false
    }

    /// 拿到这次尝试的授权查询结果。拒绝时判为没有授权、返回 false，不要建（这次尝试到此结束）；
    /// 否则返回 true，调用方去建，再报 `started()` 或 `startFailed()`
    public mutating func shouldStart(authorization: SystemSoundAuthorization) -> Bool {
        guard authorization != .denied else {
            isAttempting = false
            unavailableReason = .notAuthorized
            awaitsAuthorization = false
            noticeHeld = false
            return false
        }
        pendingAuthorization = authorization
        return true
    }

    /// 各步都建好了
    public mutating func started() {
        isAttempting = false
        unavailableReason = nil
        awaitsAuthorization = pendingAuthorization == .undetermined
        noticeGiven = false
        noticeHeld = false
    }

    /// 某一步建立失败
    public mutating func startFailed() {
        isAttempting = false
        unavailableReason = .startFailed
        awaitsAuthorization = false
        noticeHeld = false
    }

    /// 运行中聚合设备失效：不可用（调用方停掉采集，开一段不可用时段）。离上次尝试已隔开最小间隔时返回 true，
    /// 调用方马上重建一次，结果出来之前先不提醒：马上建好的话只是一闪，不打扰。
    /// 返回 false 时不马上重建（刚建好就坏，马上重建可能停不下来），直接提醒，之后按定时重试
    @discardableResult
    public mutating func deviceLost(at date: Date) -> Bool {
        unavailableReason = .deviceLost
        awaitsAuthorization = false
        noticeHeld = isRetryDue(at: date, deviceChanged: true)
        return noticeHeld
    }

    /// 该不该提醒“系统声音不可用”，该提醒时返回原因。每段不可用只提醒一次（重试又失败、原因变了都不再提醒），
    /// 设备失效后马上重建的结果出来之前不提醒。调用方每次更新状态后取一次
    public mutating func takeNotice() -> SystemSoundUnavailableReason? {
        guard let unavailableReason, !noticeHeld, !noticeGiven else { return nil }
        noticeGiven = true
        return unavailableReason
    }

    /// 未决定时建好的采集，建好后（授权框已经关掉）用子进程再查一次授权，之后该做什么
    public enum AuthorizationFollowUp: Equatable, Sendable {
        /// 照常用这次建的采集
        case keep
        /// 点了“允许”：停掉、按已授权重建一次，用授权之后建的 tap
        case rebuild
        /// 点了“不允许”：停掉，已判为没有授权（之后定时重查）
        case stop
    }

    /// 建好后复查到的授权。只查这一次：仍是未决定（子进程查不到之类）就照常用，不再查
    public mutating func authorizationResolved(_ authorization: SystemSoundAuthorization) -> AuthorizationFollowUp {
        guard awaitsAuthorization else { return .keep }
        awaitsAuthorization = false
        switch authorization {
        case .undetermined:
            return .keep
        case .authorized:
            return .rebuild
        case .denied:
            unavailableReason = .notAuthorized
            return .stop
        }
    }

    /// 此刻该不该重试：不可用、没有尝试在进行，且离上次尝试已过定时间隔；
    /// 设备有变化（输出设备变了、设备列表变了）时只要隔开最小间隔就重试。没有授权和设备无关，只按定时重查
    public func isRetryDue(at date: Date, deviceChanged: Bool) -> Bool {
        guard !isAttempting, let unavailableReason, let lastAttempt else { return false }
        let since = date.timeIntervalSince(lastAttempt)
        let byDevice = deviceChanged && unavailableReason != .notAuthorized
        return since >= (byDevice ? Self.minimumRetrySpacing : Self.retryInterval)
    }

    /// 采集在跑时 tap 的格式变了。离上次尝试已隔开最小间隔就返回 true，调用方马上重建；
    /// 否则记下、返回 false，由定时检查 `isFormatRebuildDue` 到时补一次（连着变几次也只补一次）。
    /// 不能干脆丢掉：格式监听只在变化时通知，丢了就一直按旧格式解读数据
    public mutating func formatChanged(at date: Date) -> Bool {
        let rebuildsNow = lastAttempt.map { date.timeIntervalSince($0) >= Self.minimumRetrySpacing } ?? true
        formatRebuildPending = !rebuildsNow
        return rebuildsNow
    }

    /// 有格式变化等着补重建，且离上次尝试已隔开最小间隔
    public func isFormatRebuildDue(at date: Date) -> Bool {
        guard formatRebuildPending, let lastAttempt else { return false }
        return date.timeIntervalSince(lastAttempt) >= Self.minimumRetrySpacing
    }
}
