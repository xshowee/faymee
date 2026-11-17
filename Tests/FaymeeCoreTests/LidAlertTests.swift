import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-17T02:00:00Z", strategy: .iso8601)

/// 相对 t0 的墙钟时间
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func lid(_ start: TimeInterval, _ end: TimeInterval?) -> Gap {
    Gap(start: at(start), end: end.map(at), reason: .lidClosed)
}

private func period(_ start: TimeInterval, _ end: TimeInterval?) -> WallClockPeriod {
    WallClockPeriod(start: at(start), end: end.map(at))
}

/// 还在录的会议
private func recording(lidGaps: [Gap], systemSound: [WallClockPeriod] = [],
                       unavailable: [WallClockPeriod] = []) -> Meeting {
    var m = Meeting(id: "m", title: "会议", startedAt: t0, status: .recording)
    m.lidGaps = lidGaps
    m.systemSoundPeriodList = systemSound
    m.systemSoundUnavailablePeriodList = unavailable
    return m
}

/// 录音中合盖的提醒（spec「录音中的行为」）：开着系统声音时不说“现在没有在录”，改为“只录到系统声音”；
/// 关着系统声音时文字与以前逐字相同
@Suite struct LidAlertTests {
    // MARK: - 合盖当下

    @Test func 合盖通知_没在录系统声音时照旧() {
        #expect(LidAlert.closedNotice(capturingSystemSound: false) == MeetingNotice(
            title: "内置麦克风已断开",
            body: "MacBook 合盖后内置麦克风无法收音，现在没有在录。请打开盖子，或改用外接麦克风。"))
    }

    @Test func 合盖通知_在录系统声音时说只录到系统声音() {
        #expect(LidAlert.closedNotice(capturingSystemSound: true) == MeetingNotice(
            title: "内置麦克风已断开",
            body: "MacBook 合盖后内置麦克风无法收音，现在只录到系统声音。请打开盖子，或改用外接麦克风。"))
    }

    @Test func 面板里合盖中的提示() {
        #expect(LidAlert.closedStatus(capturingSystemSound: false)
            == "已合盖，内置麦克风被断开，现在没有在录。请打开盖子，或改用外接麦克风。")
        #expect(LidAlert.closedStatus(capturingSystemSound: true)
            == "已合盖，内置麦克风被断开，现在只录到系统声音。请打开盖子，或改用外接麦克风。")
    }

    // MARK: - 开盖后

    @Test func 开盖通知_没开系统声音时照旧() {
        let gap = lid(600, 900)
        let m = recording(lidGaps: [gap])
        #expect(m.lidReopenedNotice(for: gap) == MeetingNotice(title: "合盖期间没有录到声音",
                                                               body: formatTimeRange(gap)))
    }

    @Test func 开盖通知_整段开着系统声音说只录到系统声音() {
        let gap = lid(600, 900)
        let m = recording(lidGaps: [gap], systemSound: [period(0, nil)])
        #expect(m.lidReopenedNotice(for: gap) == MeetingNotice(title: "合盖期间只录到系统声音",
                                                               body: formatTimeRange(gap)))
    }

    /// 开着但不可用：两路都没录到，和没开一样说没有录到声音
    @Test func 开盖通知_系统声音不可用说没有录到声音() {
        let gap = lid(600, 900)
        let m = recording(lidGaps: [gap], systemSound: [period(0, nil)], unavailable: [period(500, nil)])
        #expect(m.lidReopenedNotice(for: gap).title == "合盖期间没有录到声音")
    }

    /// 合盖中途打开系统声音：前一部分什么也没录到
    @Test func 开盖通知_只有部分时段录到系统声音() {
        let gap = lid(600, 900)
        let m = recording(lidGaps: [gap], systemSound: [period(700, nil)])
        #expect(m.lidReopenedNotice(for: gap) == MeetingNotice(title: "合盖期间部分时段没有录到声音",
                                                               body: formatTimeRange(gap)))
    }

    /// 起止差几毫秒（同一时刻各取各的当前时间）不算部分时段
    @Test func 开盖通知_系统声音晚开几毫秒仍算整段() {
        let gap = lid(600, 900)
        let m = recording(lidGaps: [gap], systemSound: [period(600.003, nil)])
        #expect(m.lidReopenedNotice(for: gap).title == "合盖期间只录到系统声音")
    }

    // MARK: - 面板里的合盖摘要

    @Test func 摘要_没有合盖过或还在合盖不显示() {
        #expect(recording(lidGaps: []).lidGapSummary == nil)
        #expect(recording(lidGaps: [lid(600, nil)]).lidGapSummary == nil)
    }

    @Test func 摘要_没开系统声音时照旧() {
        let m = recording(lidGaps: [lid(600, 900), lid(1200, 1300), lid(1800, nil)])
        #expect(m.lidGapSummary == "本次有 2 段因合盖没有录到声音，可在会议记录里查看")
    }

    @Test func 摘要_开着系统声音的合盖只录到系统声音() {
        let m = recording(lidGaps: [lid(600, 900), lid(1200, 1300)], systemSound: [period(0, nil)])
        #expect(m.lidGapSummary == "本次有 2 段合盖时只录到系统声音，可在会议记录里查看")
    }

    @Test func 摘要_两种都有() {
        let m = recording(lidGaps: [lid(600, 900), lid(1200, 1300), lid(2000, 2100)],
                          systemSound: [period(1000, nil)], unavailable: [period(1900, nil)])
        #expect(m.lidGapSummary == "本次有 2 段因合盖没有录到声音、1 段只录到系统声音，可在会议记录里查看")
    }

    /// 合盖中途打开系统声音，一段拆成两部分，和会议记录里列的段数一致
    @Test func 摘要_一段合盖中途打开系统声音按拆开的段数() {
        let m = recording(lidGaps: [lid(600, 900)], systemSound: [period(700, nil)])
        #expect(m.lidGapSummary == "本次有 1 段因合盖没有录到声音、1 段只录到系统声音，可在会议记录里查看")
    }
}
