import Foundation

/// “系统录音”授权的查询结果。查询接口取不到时按未决定处理（照常建，由系统弹授权框）
public enum SystemSoundAuthorization: Sendable {
    case authorized
    case denied
    case undetermined
}

/// 系统声音为什么不可用
public enum SystemSoundUnavailableReason: Equatable, Sendable {
    /// 授权查询为拒绝。授权结果在进程内缓存，重试没有用，要用户授权后重新打开 Faymee
    case notAuthorized
    /// tap、聚合设备、IOProc、启动任一步出错
    case startFailed
    /// 运行中聚合设备失效（`kAudioDevicePropertyDeviceIsAlive` 变为 0）
    case deviceLost

    /// 建不起来、运行中出错这两种自动重试；没有授权的不重试
    public var retries: Bool { self != .notAuthorized }

    /// 菜单栏面板里的说明
    public var menuText: String {
        switch self {
        case .notAuthorized:
            "系统声音不可用：没有“系统录音”授权。请到“系统设置 › 隐私与安全性 › 录屏与系统录音”里打开 Faymee，"
                + "然后重新打开 Faymee。麦克风照常在录。"
        case .startFailed, .deviceLost:
            "系统声音不可用，正在自动重试。麦克风照常在录。"
        }
    }

    /// 不在录音时菜单栏面板里的说明：和录音中一样，只是不说麦克风在录
    public var idleMenuText: String {
        switch self {
        case .notAuthorized:
            "系统声音不可用：没有“系统录音”授权。请到“系统设置 › 隐私与安全性 › 录屏与系统录音”里打开 Faymee，"
                + "然后重新打开 Faymee。"
        case .startFailed, .deviceLost:
            "系统声音不可用。"
        }
    }

    /// 通知的标题和正文（无声，只在屏幕可见时发）
    public var notice: (title: String, body: String) {
        switch self {
        case .notAuthorized:
            ("系统声音不可用", "没有“系统录音”授权，只录到麦克风。可以在系统设置 › 隐私与安全性 › 录屏与系统录音里打开 Faymee，"
                + "然后重新打开 Faymee。")
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
    /// 未决定：让系统弹出“系统录音”授权框（App 短暂建一次采集再拆掉，不录、不写盘）
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
/// 输入只有三种：每次开始采集前的授权查询结果、建立的结果、运行中设备失效。没有回调、回调全零都不是输入：
/// 没有声音播放时本来就没有回调，播放过之后没声音时回调全零，没有授权时也只是全零，判断不了。
/// 每次录音（或每次打开开关）用一个新的值
public struct SystemSoundAvailability: Equatable, Sendable {
    /// 不可用时定时重试的间隔
    public static let retryInterval: TimeInterval = 10
    /// 设备变化触发的重试与上次尝试至少隔开这么久：私有聚合设备建了又拆本身就会触发设备列表变化
    public static let minimumRetrySpacing: TimeInterval = 2

    /// nil 表示可用（或还没开始）
    public private(set) var unavailableReason: SystemSoundUnavailableReason?
    /// 建好时授权还是未决定（系统在弹授权框）：之后要再查，用户点了拒绝就判为没有授权
    public private(set) var awaitsAuthorization = false
    /// 上次开始（或重试）采集的时刻
    public private(set) var lastAttempt: Date?
    private var pendingAuthorization: SystemSoundAuthorization?

    public init() {}

    public var isAvailable: Bool { unavailableReason == nil }

    /// 开始（或重试）采集前调用，传入此刻的授权查询结果。拒绝时判为没有授权、返回 false，不要建；
    /// 否则返回 true，调用方去建，再报 `started()` 或 `startFailed()`
    public mutating func shouldStart(authorization: SystemSoundAuthorization, at date: Date) -> Bool {
        lastAttempt = date
        guard authorization != .denied else {
            unavailableReason = .notAuthorized
            awaitsAuthorization = false
            return false
        }
        pendingAuthorization = authorization
        return true
    }

    /// 各步都建好了
    public mutating func started() {
        unavailableReason = nil
        awaitsAuthorization = pendingAuthorization == .undetermined
    }

    /// 某一步建立失败
    public mutating func startFailed() {
        unavailableReason = .startFailed
        awaitsAuthorization = false
    }

    /// 运行中聚合设备失效。调用方停掉采集，按 `isRetryDue` 重建
    public mutating func deviceLost() {
        unavailableReason = .deviceLost
        awaitsAuthorization = false
    }

    /// 在等授权框时再查到的结果。查到拒绝时判为没有授权、返回 true：调用方要停掉采集
    public mutating func authorizationResolved(_ authorization: SystemSoundAuthorization) -> Bool {
        guard awaitsAuthorization, authorization != .undetermined else { return false }
        awaitsAuthorization = false
        guard authorization == .denied else { return false }
        unavailableReason = .notAuthorized
        return true
    }

    /// 此刻该不该重试：不可用、原因可以重试，且离上次尝试已过定时间隔；
    /// 设备有变化（输出设备变了、设备列表变了）时只要隔开最小间隔就重试
    public func isRetryDue(at date: Date, deviceChanged: Bool) -> Bool {
        guard let unavailableReason, unavailableReason.retries, let lastAttempt else { return false }
        let since = date.timeIntervalSince(lastAttempt)
        return since >= (deviceChanged ? Self.minimumRetrySpacing : Self.retryInterval)
    }
}
