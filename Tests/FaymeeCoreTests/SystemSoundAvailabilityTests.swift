import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-10T02:00:00Z", strategy: .iso8601)

/// 相对 t0 的墙钟时间
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private extension SystemSoundAvailability {
    /// 一次完整的尝试：开始（查授权之前）、拿到授权查询结果
    mutating func attempt(_ authorization: SystemSoundAuthorization, at date: Date) -> Bool {
        beginAttempt(at: date)
        return shouldStart(authorization: authorization)
    }
}

@Suite struct SystemSoundAvailabilityTests {
    /// 授权可以在录音中途打开（在子进程里查得到），所以没有授权也定时重查
    @Test func 授权为拒绝时不建_不可用并定时重查() {
        let interval = SystemSoundAvailability.retryInterval
        var a = SystemSoundAvailability()
        let starts = a.attempt(.denied, at: at(0))
        #expect(!starts)
        #expect(a.unavailableReason == .notAuthorized)
        #expect(!a.isRetryDue(at: at(interval - 1), deviceChanged: false))
        #expect(a.isRetryDue(at: at(interval), deviceChanged: false))
    }

    /// 设备变化和授权无关：没有授权时只按定时重查，不因为设备变化提前去查
    @Test func 没有授权时设备变化不提前重查() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.denied, at: at(0))
        #expect(!a.isRetryDue(at: at(SystemSoundAvailability.minimumRetrySpacing), deviceChanged: true))
        #expect(a.isRetryDue(at: at(SystemSoundAvailability.retryInterval), deviceChanged: true))
    }

    @Test func 没有授权时重查到已授权就重建并恢复() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.denied, at: at(0))
        #expect(a.takeNotice() == .notAuthorized)
        let starts = a.attempt(.authorized, at: at(10))
        #expect(starts)
        a.started()
        #expect(a.isAvailable)
        #expect(!a.awaitsAuthorization)
        #expect(a.takeNotice() == nil)
        #expect(!a.isRetryDue(at: at(100), deviceChanged: false))
    }

    @Test func 重查仍是拒绝时照旧不可用_不再提醒() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.denied, at: at(0))
        #expect(a.takeNotice() == .notAuthorized)
        let starts = a.attempt(.denied, at: at(10))
        #expect(!starts)
        #expect(a.unavailableReason == .notAuthorized)
        #expect(a.takeNotice() == nil)
        #expect(a.isRetryDue(at: at(20), deviceChanged: false))
    }

    /// 查授权要起子进程、建立可能卡在授权框上：这次尝试的结果出来之前不再开始下一次
    @Test func 尝试还没有结果时不重试() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.authorized, at: at(0))
        a.startFailed()
        a.beginAttempt(at: at(10))
        #expect(!a.isRetryDue(at: at(600), deviceChanged: false))
        #expect(!a.isRetryDue(at: at(600), deviceChanged: true))
        _ = a.shouldStart(authorization: .authorized)
        #expect(!a.isRetryDue(at: at(600), deviceChanged: false))
        a.startFailed()
        #expect(a.isRetryDue(at: at(20), deviceChanged: false))
    }

    /// 未决定时由系统弹授权框；查询接口取不到也按未决定处理
    @Test func 授权为未决定时照常建() {
        var a = SystemSoundAvailability()
        let starts = a.attempt(.undetermined, at: at(0))
        #expect(starts)
        a.started()
        #expect(a.isAvailable)
    }

    @Test func 已授权时建好就可用() {
        var a = SystemSoundAvailability()
        let starts = a.attempt(.authorized, at: at(0))
        #expect(starts)
        a.started()
        #expect(a.isAvailable)
        #expect(!a.awaitsAuthorization)
    }

    @Test func 建立失败时不可用并定时重试() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.authorized, at: at(0))
        a.startFailed()
        #expect(a.unavailableReason == .startFailed)
        #expect(!a.isRetryDue(at: at(SystemSoundAvailability.retryInterval - 1), deviceChanged: false))
        #expect(a.isRetryDue(at: at(SystemSoundAvailability.retryInterval), deviceChanged: false))
    }

    @Test func 重试成功后恢复() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.authorized, at: at(0))
        a.startFailed()
        let starts = a.attempt(.authorized, at: at(10))
        #expect(starts)
        a.started()
        #expect(a.isAvailable)
        #expect(!a.isRetryDue(at: at(100), deviceChanged: true))
    }

    /// 重试时授权变成了拒绝（录音中途在系统设置里关掉了）：改按没有授权处理，之后定时重查
    @Test func 重试前查到拒绝时改为没有授权() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.authorized, at: at(0))
        a.startFailed()
        let starts = a.attempt(.denied, at: at(10))
        #expect(!starts)
        #expect(a.unavailableReason == .notAuthorized)
        #expect(a.isRetryDue(at: at(20), deviceChanged: false))
    }

    @Test func 运行中设备失效时不可用并在设备变化时立即重试() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.authorized, at: at(0))
        a.started()
        a.deviceLost(at: at(60))
        #expect(a.unavailableReason == .deviceLost)
        #expect(a.isRetryDue(at: at(60), deviceChanged: true))
        #expect(a.isRetryDue(at: at(60), deviceChanged: false))
    }

    /// 私有聚合设备建了又拆会触发设备列表变化：失败后马上又因“设备变化”重试会停不下来
    @Test func 设备变化触发的重试与上次尝试至少隔开一段时间() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.authorized, at: at(0))
        a.startFailed()
        let spacing = SystemSoundAvailability.minimumRetrySpacing
        #expect(!a.isRetryDue(at: at(spacing - 0.1), deviceChanged: true))
        #expect(a.isRetryDue(at: at(spacing), deviceChanged: true))
    }

    /// 没有声音播放时可能完全没有回调，播放过之后没声音时回调全零：这两种都不是输入，
    /// 建好之后只要设备没失效，过多久都是可用、不重试
    @Test func 没有回调或回调全零都不判为不可用() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.authorized, at: at(0))
        a.started()
        #expect(a.isAvailable)
        #expect(!a.isRetryDue(at: at(3600), deviceChanged: false))
    }

    /// 未决定时建立会等用户回答授权框，建好后再查一次：点了“不允许”就判为没有授权、停掉采集
    /// （被拒绝的 tap 只拿到全零），之后定时重查
    @Test func 建立后复查为拒绝时停掉_不可用并定时重查() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.undetermined, at: at(0))
        a.started()
        #expect(a.awaitsAuthorization)
        #expect(a.authorizationResolved(.denied) == .stop)
        #expect(a.unavailableReason == .notAuthorized)
        #expect(!a.awaitsAuthorization)
        #expect(a.isRetryDue(at: at(SystemSoundAvailability.retryInterval), deviceChanged: false))
    }

    /// 点了“允许”：重建一次，用授权之后建的 tap。重建按已授权建，不再复查（不会一直重建）
    @Test func 建立后复查为已授权时重建一次() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.undetermined, at: at(0))
        a.started()
        #expect(a.authorizationResolved(.authorized) == .rebuild)
        #expect(a.isAvailable)
        #expect(!a.awaitsAuthorization)
        _ = a.attempt(.authorized, at: at(3))
        a.started()
        #expect(a.isAvailable)
        #expect(!a.awaitsAuthorization)
        #expect(a.authorizationResolved(.authorized) == .keep)
        #expect(a.takeNotice() == nil)
    }

    /// 复查仍是未决定（比如子进程查不到）：只查这一次，照常用这次建的采集，不判为不可用
    @Test func 建立后复查仍是未决定时照常可用_不再查() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.undetermined, at: at(0))
        a.started()
        #expect(a.authorizationResolved(.undetermined) == .keep)
        #expect(a.isAvailable)
        #expect(!a.awaitsAuthorization)
    }

    @Test func 没有授权的提示不让重新打开Faymee() {
        let reason = SystemSoundUnavailableReason.notAuthorized
        for text in [reason.menuText, reason.idleMenuText, reason.notice.body] {
            #expect(text.contains("录屏与系统录音"))
            #expect(!text.contains("重新打开"))
        }
    }

    // MARK: - 录音前打开开关

    /// 第一次打开开关（还没回答过授权）：录音前就让系统弹出授权框，不等到开始录音
    @Test func 录音前打开开关_授权未决定时弹授权框() {
        #expect(SystemSoundSwitchOn(authorization: .undetermined) == .requestAuthorization)
    }

    /// 拒绝过授权：录音前就在面板里说系统声音不可用、去系统设置打开
    @Test func 录音前打开开关_授权为拒绝时提示没有授权() {
        let action = SystemSoundSwitchOn(authorization: .denied)
        #expect(action == .showUnavailable(.notAuthorized))
        #expect(action.unavailableReason == .notAuthorized)
    }

    @Test func 录音前打开开关_已授权时什么都不做() {
        let action = SystemSoundSwitchOn(authorization: .authorized)
        #expect(action == .nothing)
        #expect(action.unavailableReason == nil)
    }

    /// 录音前的提示不说“麦克风照常在录”：这时还没在录
    @Test func 录音前的没有授权提示不提麦克风在录() {
        let text = SystemSoundUnavailableReason.notAuthorized.idleMenuText
        #expect(text.contains("录屏与系统录音"))
        #expect(!text.contains("麦克风照常在录"))
    }

    // MARK: - 提醒

    /// 建不起来、没有授权：变为不可用时提醒一次，之后重试又失败不再提醒；恢复后再不可用再提醒
    @Test func 变为不可用时提醒一次_恢复后再不可用再提醒() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.authorized, at: at(0))
        a.startFailed()
        #expect(a.takeNotice() == .startFailed)
        #expect(a.takeNotice() == nil)
        _ = a.attempt(.authorized, at: at(10))
        a.startFailed()
        #expect(a.takeNotice() == nil)
        _ = a.attempt(.authorized, at: at(20))
        a.started()
        #expect(a.takeNotice() == nil)
        _ = a.attempt(.denied, at: at(30))
        #expect(a.takeNotice() == .notAuthorized)
    }

    /// 运行中设备失效、离上次建立已隔开最小间隔：马上重建一次，重建前先不提醒；建好了就不提醒（只是一闪）
    @Test func 设备失效后马上重建成功不提醒() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.authorized, at: at(0))
        a.started()
        let rebuildsNow = a.deviceLost(at: at(60))
        #expect(rebuildsNow)
        #expect(!a.isAvailable)
        #expect(a.takeNotice() == nil)
        _ = a.attempt(.authorized, at: at(60))
        a.started()
        #expect(a.isAvailable)
        #expect(a.takeNotice() == nil)
    }

    @Test func 设备失效后马上重建失败才提醒() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.authorized, at: at(0))
        a.started()
        _ = a.deviceLost(at: at(60))
        _ = a.attempt(.authorized, at: at(60))
        a.startFailed()
        #expect(a.takeNotice() == .startFailed)
        #expect(a.takeNotice() == nil)
    }

    /// 刚建好不到最小间隔又失效：不马上重建（免得建了又坏停不下来），直接提醒，之后按定时重试
    @Test func 刚建好就失效时不马上重建并直接提醒() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.authorized, at: at(0))
        a.started()
        let rebuildsNow = a.deviceLost(at: at(SystemSoundAvailability.minimumRetrySpacing - 0.5))
        #expect(!rebuildsNow)
        #expect(a.takeNotice() == .deviceLost)
    }

    // MARK: - tap 格式变化

    @Test func 格式变了且离上次建立够久就马上重建() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.authorized, at: at(0))
        a.started()
        let rebuildsNow = a.formatChanged(at: at(60))
        #expect(rebuildsNow)
    }

    /// 刚建好格式就又变（比如新建的 tap 又报一次变化）：不马上重建，免得一直重建；到了最小间隔补一次
    @Test func 刚建好格式又变时先记下_隔够了补一次() {
        let spacing = SystemSoundAvailability.minimumRetrySpacing
        var a = SystemSoundAvailability()
        _ = a.attempt(.authorized, at: at(0))
        a.started()
        let rebuildsNow = a.formatChanged(at: at(0.5))
        #expect(!rebuildsNow)
        #expect(!a.isFormatRebuildDue(at: at(spacing - 0.1)))
        #expect(a.isFormatRebuildDue(at: at(spacing)))
    }

    @Test func 格式连着变几次只补一次重建() {
        let spacing = SystemSoundAvailability.minimumRetrySpacing
        var a = SystemSoundAvailability()
        _ = a.attempt(.authorized, at: at(0))
        a.started()
        let first = a.formatChanged(at: at(0.2))
        #expect(!first)
        let second = a.formatChanged(at: at(0.6))
        #expect(!second)
        let third = a.formatChanged(at: at(1.0))
        #expect(!third)
        #expect(a.isFormatRebuildDue(at: at(spacing)))
        _ = a.attempt(.authorized, at: at(spacing))
        a.started()
        #expect(!a.isFormatRebuildDue(at: at(spacing * 10)))
    }

    /// 等着补的重建之前，因为别的原因（唤醒、重试）已经重建过：新建的按当时的格式读，不用再补
    @Test func 别的原因重建过就不再补格式变化的重建() {
        var a = SystemSoundAvailability()
        _ = a.attempt(.authorized, at: at(0))
        a.started()
        let rebuildsNow = a.formatChanged(at: at(0.5))
        #expect(!rebuildsNow)
        _ = a.attempt(.authorized, at: at(1))
        a.started()
        #expect(!a.isFormatRebuildDue(at: at(60)))
    }
}
