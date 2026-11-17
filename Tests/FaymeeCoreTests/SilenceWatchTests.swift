import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-17T02:00:00Z", strategy: .iso8601)

/// 相对 t0 的墙钟时间
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private let quiet: Float = -160
private let loud: Float = -30

/// 系统声音关着时的告警，文字与以前逐字相同
private let micOnlyNotice = MeetingNotice(
    title: "Faymee 可能没录到声音",
    body: "已经 20 秒没有声音了。MacBook 合盖时内置麦克风会被断开，请检查麦克风。")

/// 开着系统声音时的告警：两路都没声音
private let bothNotice = MeetingNotice(
    title: "Faymee 可能没录到声音",
    body: "麦克风和系统声音已经 20 秒都没有声音了。MacBook 合盖时内置麦克风会被断开，请检查麦克风。")

/// 录音中的“没有声音”提醒（spec「录音中的行为」）：系统声音关着时只看麦克风，开着时两路都没声音才提醒
@Suite struct SilenceWatchTests {
    @Test func 系统声音关着_麦克风静二十秒提醒() {
        var watch = SilenceWatch()
        watch.micLevel(quiet, at: at(0))
        let check = watch.check(at: at(20), includesSystemSound: false, canNotify: true)
        #expect(check.isSilent)
        #expect(check.notice == micOnlyNotice)
    }

    @Test func 不够二十秒或麦克风有声音都不算() {
        var watch = SilenceWatch()
        watch.micLevel(quiet, at: at(0))
        #expect(watch.check(at: at(19), includesSystemSound: false, canNotify: true).isSilent == false)
        watch.micLevel(loud, at: at(19.5))
        watch.micLevel(quiet, at: at(19.6))
        #expect(watch.check(at: at(25), includesSystemSound: false, canNotify: true).isSilent == false)
        #expect(watch.check(at: at(39.6), includesSystemSound: false, canNotify: true).isSilent)
    }

    @Test func 只提醒一次_有过声音再静下来才再提醒() {
        var watch = SilenceWatch()
        watch.micLevel(quiet, at: at(0))
        #expect(watch.check(at: at(20), includesSystemSound: false, canNotify: true).notice != nil)
        let again = watch.check(at: at(21), includesSystemSound: false, canNotify: true)
        #expect(again.isSilent)
        #expect(again.notice == nil)

        watch.micLevel(loud, at: at(30))
        #expect(watch.check(at: at(31), includesSystemSound: false, canNotify: true).isSilent == false)
        watch.micLevel(quiet, at: at(31))
        #expect(watch.check(at: at(51), includesSystemSound: false, canNotify: true).notice == micOnlyNotice)
    }

    /// 合盖（由合盖的提醒负责）或看不到屏幕时先不发，等能发时再发，不算已经提醒过
    @Test func 不能提醒时先不发_能发时补发() {
        var watch = SilenceWatch()
        watch.micLevel(quiet, at: at(0))
        let blocked = watch.check(at: at(20), includesSystemSound: false, canNotify: false)
        #expect(blocked.isSilent)
        #expect(blocked.notice == nil)
        #expect(watch.check(at: at(40), includesSystemSound: false, canNotify: true).notice == micOnlyNotice)
    }

    // MARK: - 开着系统声音

    /// 闭麦旁听线上会议：麦克风一直没声音，系统声音里有人在说话
    @Test func 开着系统声音_麦克风没声音但系统声音有就不提醒() {
        var watch = SilenceWatch()
        watch.micLevel(quiet, at: at(0))
        for s in stride(from: 1.0, through: 60, by: 1) {
            watch.systemSoundLevel(loud, at: at(s))
            let check = watch.check(at: at(s), includesSystemSound: true, canNotify: true)
            #expect(check.isSilent == false)
            #expect(check.notice == nil)
        }
    }

    /// 没有声音播放时系统声音可能完全没有数据，没数据就算没声音
    @Test func 开着系统声音_从没收到系统声音数据照常提醒() {
        var watch = SilenceWatch()
        watch.micLevel(quiet, at: at(0))
        let check = watch.check(at: at(20), includesSystemSound: true, canNotify: true)
        #expect(check.isSilent)
        #expect(check.notice == bothNotice)
    }

    @Test func 开着系统声音_两路都静够二十秒才提醒() {
        var watch = SilenceWatch()
        watch.micLevel(quiet, at: at(0))
        watch.systemSoundLevel(loud, at: at(10))
        watch.systemSoundLevel(quiet, at: at(11))
        #expect(watch.check(at: at(29), includesSystemSound: true, canNotify: true).isSilent == false)
        #expect(watch.check(at: at(30), includesSystemSound: true, canNotify: true).notice == bothNotice)
    }

    @Test func 开着系统声音_麦克风有声音就不算() {
        var watch = SilenceWatch()
        watch.systemSoundLevel(quiet, at: at(0))
        watch.micLevel(loud, at: at(25))
        #expect(watch.check(at: at(30), includesSystemSound: true, canNotify: true).isSilent == false)
    }

    @Test func 两路都静时提醒过_系统声音再响过一次后再静才再提醒() {
        var watch = SilenceWatch()
        watch.micLevel(quiet, at: at(0))
        #expect(watch.check(at: at(20), includesSystemSound: true, canNotify: true).notice == bothNotice)
        watch.systemSoundLevel(loud, at: at(30))
        #expect(watch.check(at: at(31), includesSystemSound: true, canNotify: true).isSilent == false)
        #expect(watch.check(at: at(49), includesSystemSound: true, canNotify: true).notice == nil)
        #expect(watch.check(at: at(50), includesSystemSound: true, canNotify: true).notice == bothNotice)
    }

    /// 关掉系统声音后只看麦克风：之前系统声音响过不再算数
    @Test func 系统声音关掉后只看麦克风() {
        var watch = SilenceWatch()
        watch.micLevel(quiet, at: at(0))
        watch.systemSoundLevel(loud, at: at(15))
        #expect(watch.check(at: at(20), includesSystemSound: false, canNotify: true).notice == micOnlyNotice)
    }

    @Test func 面板提示按是否在录系统声音() {
        #expect(SilenceWatch.statusText(includesSystemSound: false) == "长时间没有声音，请检查麦克风。")
        #expect(SilenceWatch.statusText(includesSystemSound: true) == "麦克风和系统声音都长时间没有声音，请检查麦克风。")
    }
}
