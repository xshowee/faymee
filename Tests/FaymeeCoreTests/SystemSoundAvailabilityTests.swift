import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-10T02:00:00Z", strategy: .iso8601)

/// 相对 t0 的墙钟时间
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

@Suite struct SystemSoundAvailabilityTests {
    @Test func 授权为拒绝时不建不可用且不重试() {
        var a = SystemSoundAvailability()
        let starts = a.shouldStart(authorization: .denied, at: at(0))
        #expect(!starts)
        #expect(a.unavailableReason == .notAuthorized)
        #expect(!a.isRetryDue(at: at(600), deviceChanged: false))
        #expect(!a.isRetryDue(at: at(600), deviceChanged: true))
    }

    /// 未决定时由系统弹授权框；查询接口取不到也按未决定处理
    @Test func 授权为未决定时照常建() {
        var a = SystemSoundAvailability()
        let starts = a.shouldStart(authorization: .undetermined, at: at(0))
        #expect(starts)
        a.started()
        #expect(a.isAvailable)
    }

    @Test func 已授权时建好就可用() {
        var a = SystemSoundAvailability()
        let starts = a.shouldStart(authorization: .authorized, at: at(0))
        #expect(starts)
        a.started()
        #expect(a.isAvailable)
        #expect(!a.awaitsAuthorization)
    }

    @Test func 建立失败时不可用并定时重试() {
        var a = SystemSoundAvailability()
        _ = a.shouldStart(authorization: .authorized, at: at(0))
        a.startFailed()
        #expect(a.unavailableReason == .startFailed)
        #expect(!a.isRetryDue(at: at(SystemSoundAvailability.retryInterval - 1), deviceChanged: false))
        #expect(a.isRetryDue(at: at(SystemSoundAvailability.retryInterval), deviceChanged: false))
    }

    @Test func 重试成功后恢复() {
        var a = SystemSoundAvailability()
        _ = a.shouldStart(authorization: .authorized, at: at(0))
        a.startFailed()
        let starts = a.shouldStart(authorization: .authorized, at: at(10))
        #expect(starts)
        a.started()
        #expect(a.isAvailable)
        #expect(!a.isRetryDue(at: at(100), deviceChanged: true))
    }

    /// 重试时授权变成了拒绝（同一进程里实测不会变，但每次建之前都查）：改按没有授权处理，不再重试
    @Test func 重试前查到拒绝时改为没有授权() {
        var a = SystemSoundAvailability()
        _ = a.shouldStart(authorization: .authorized, at: at(0))
        a.startFailed()
        let starts = a.shouldStart(authorization: .denied, at: at(10))
        #expect(!starts)
        #expect(a.unavailableReason == .notAuthorized)
        #expect(!a.isRetryDue(at: at(100), deviceChanged: true))
    }

    @Test func 运行中设备失效时不可用并在设备变化时立即重试() {
        var a = SystemSoundAvailability()
        _ = a.shouldStart(authorization: .authorized, at: at(0))
        a.started()
        a.deviceLost(at: at(60))
        #expect(a.unavailableReason == .deviceLost)
        #expect(a.isRetryDue(at: at(60), deviceChanged: true))
        #expect(a.isRetryDue(at: at(60), deviceChanged: false))
    }

    /// 私有聚合设备建了又拆会触发设备列表变化：失败后马上又因“设备变化”重试会停不下来
    @Test func 设备变化触发的重试与上次尝试至少隔开一段时间() {
        var a = SystemSoundAvailability()
        _ = a.shouldStart(authorization: .authorized, at: at(0))
        a.startFailed()
        let spacing = SystemSoundAvailability.minimumRetrySpacing
        #expect(!a.isRetryDue(at: at(spacing - 0.1), deviceChanged: true))
        #expect(a.isRetryDue(at: at(spacing), deviceChanged: true))
    }

    /// 没有声音播放时可能完全没有回调，播放过之后没声音时回调全零：这两种都不是输入，
    /// 建好之后只要设备没失效，过多久都是可用、不重试
    @Test func 没有回调或回调全零都不判为不可用() {
        var a = SystemSoundAvailability()
        _ = a.shouldStart(authorization: .authorized, at: at(0))
        a.started()
        #expect(a.isAvailable)
        #expect(!a.isRetryDue(at: at(3600), deviceChanged: false))
    }

    /// 未决定时建好的 tap 在等用户回答授权框：之后查到拒绝就判为没有授权，要停掉采集
    @Test func 未决定时建好后查到拒绝改为没有授权() {
        var a = SystemSoundAvailability()
        _ = a.shouldStart(authorization: .undetermined, at: at(0))
        a.started()
        #expect(a.awaitsAuthorization)
        let stopsOnUndetermined = a.authorizationResolved(.undetermined)
        #expect(!stopsOnUndetermined)
        #expect(a.awaitsAuthorization)
        let stopsOnDenied = a.authorizationResolved(.denied)
        #expect(stopsOnDenied)
        #expect(a.unavailableReason == .notAuthorized)
        #expect(!a.awaitsAuthorization)
        #expect(!a.isRetryDue(at: at(600), deviceChanged: true))
    }

    @Test func 未决定时建好后查到已授权照常可用() {
        var a = SystemSoundAvailability()
        _ = a.shouldStart(authorization: .undetermined, at: at(0))
        a.started()
        let stops = a.authorizationResolved(.authorized)
        #expect(!stops)
        #expect(a.isAvailable)
        #expect(!a.awaitsAuthorization)
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
        _ = a.shouldStart(authorization: .authorized, at: at(0))
        a.startFailed()
        #expect(a.takeNotice() == .startFailed)
        #expect(a.takeNotice() == nil)
        _ = a.shouldStart(authorization: .authorized, at: at(10))
        a.startFailed()
        #expect(a.takeNotice() == nil)
        _ = a.shouldStart(authorization: .authorized, at: at(20))
        a.started()
        #expect(a.takeNotice() == nil)
        _ = a.shouldStart(authorization: .denied, at: at(30))
        #expect(a.takeNotice() == .notAuthorized)
    }

    /// 运行中设备失效、离上次建立已隔开最小间隔：马上重建一次，重建前先不提醒；建好了就不提醒（只是一闪）
    @Test func 设备失效后马上重建成功不提醒() {
        var a = SystemSoundAvailability()
        _ = a.shouldStart(authorization: .authorized, at: at(0))
        a.started()
        let rebuildsNow = a.deviceLost(at: at(60))
        #expect(rebuildsNow)
        #expect(!a.isAvailable)
        #expect(a.takeNotice() == nil)
        _ = a.shouldStart(authorization: .authorized, at: at(60))
        a.started()
        #expect(a.isAvailable)
        #expect(a.takeNotice() == nil)
    }

    @Test func 设备失效后马上重建失败才提醒() {
        var a = SystemSoundAvailability()
        _ = a.shouldStart(authorization: .authorized, at: at(0))
        a.started()
        _ = a.deviceLost(at: at(60))
        _ = a.shouldStart(authorization: .authorized, at: at(60))
        a.startFailed()
        #expect(a.takeNotice() == .startFailed)
        #expect(a.takeNotice() == nil)
    }

    /// 刚建好不到最小间隔又失效：不马上重建（免得建了又坏停不下来），直接提醒，之后按定时重试
    @Test func 刚建好就失效时不马上重建并直接提醒() {
        var a = SystemSoundAvailability()
        _ = a.shouldStart(authorization: .authorized, at: at(0))
        a.started()
        let rebuildsNow = a.deviceLost(at: at(SystemSoundAvailability.minimumRetrySpacing - 0.5))
        #expect(!rebuildsNow)
        #expect(a.takeNotice() == .deviceLost)
    }
}
