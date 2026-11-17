import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-10T02:00:00Z", strategy: .iso8601)

/// 相对 t0 的墙钟时间
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// 从 t0 录到 t0 + duration 的会议；duration 为 nil 时还在录
private func meeting(duration: TimeInterval? = 3600, systemSound: [WallClockPeriod] = []) -> Meeting {
    var m = Meeting(id: "m", title: "会议", startedAt: t0, status: duration == nil ? .recording : .done)
    m.endedAt = duration.map(at)
    m.systemSoundPeriodList = systemSound
    return m
}

private func period(_ start: TimeInterval, _ end: TimeInterval?) -> WallClockPeriod {
    WallClockPeriod(start: at(start), end: end.map(at))
}

/// 详情页标题下的音源标记（spec 28）：全程开着系统声音、部分时段开着、没开过三种
@Suite struct AudioSourceTextTests {
    @Test func 没开过系统声音不显示() {
        #expect(meeting().audioSourceText == nil)
    }

    @Test func 全程开着显示麦克风加系统声音() {
        #expect(meeting(systemSound: [period(0, 3600)]).audioSourceText == "麦克风 + 系统声音")
    }

    @Test func 开始和结束时差一两秒仍算全程() {
        // 时段的起止由 App 另取当前时间，和会议的开始、结束对不齐
        #expect(meeting(systemSound: [period(1.5, 3598)]).audioSourceText == "麦克风 + 系统声音")
    }

    @Test func 时段没有结束算开到录音结束() {
        // 录音中断（崩溃）后时段可能没关
        #expect(meeting(systemSound: [period(0, nil)]).audioSourceText == "麦克风 + 系统声音")
    }

    @Test func 还在录且一直开着算全程() {
        #expect(meeting(duration: nil, systemSound: [period(0, nil)]).audioSourceText == "麦克风 + 系统声音")
    }

    @Test func 中途打开显示部分时段() {
        #expect(meeting(systemSound: [period(600, 3600)]).audioSourceText == "部分时段含系统声音")
    }

    @Test func 中途关闭显示部分时段() {
        #expect(meeting(systemSound: [period(0, 1200)]).audioSourceText == "部分时段含系统声音")
    }

    @Test func 关掉又打开显示部分时段() {
        #expect(meeting(systemSound: [period(0, 1200), period(1800, 3600)]).audioSourceText == "部分时段含系统声音")
    }

    @Test func 还在录但已经关掉显示部分时段() {
        #expect(meeting(duration: nil, systemSound: [period(0, 1200)]).audioSourceText == "部分时段含系统声音")
    }
}

private func lid(_ start: TimeInterval, _ end: TimeInterval?) -> Gap {
    Gap(start: at(start), end: end.map(at), reason: .lidClosed)
}

/// 详情页列出的合盖时段（spec「会议详情」）：按系统声音的状态分组说明，
/// 开着系统声音的合盖时段不再说“内置麦克风没有录到声音”
@Suite struct LidGapNoticeTests {
    private let micMissed = "以下时段因合盖，内置麦克风没有录到声音"
    private let systemSoundOnly = "以下时段因合盖，只录到系统声音"
    private let nothing = "以下时段因合盖且系统声音不可用，没有录到声音"

    @Test func 没有合盖不列() {
        #expect(meeting(systemSound: [period(0, 3600)]).lidGapNotices.isEmpty)
    }

    @Test func 没开系统声音时照旧() {
        var m = meeting()
        m.lidGaps = [lid(600, 900), lid(1800, nil)]
        #expect(m.lidGapNotices == [LidGapNotice(title: micMissed, gaps: [lid(600, 900), lid(1800, nil)])])
    }

    @Test func 开着系统声音时说只录到系统声音() {
        var m = meeting(systemSound: [period(0, 3600)])
        m.lidGaps = [lid(600, 900)]
        #expect(m.lidGapNotices == [LidGapNotice(title: systemSoundOnly, gaps: [lid(600, 900)])])
    }

    @Test func 还没开盖且系统声音还开着() {
        var m = meeting(duration: nil, systemSound: [period(0, nil)])
        m.lidGaps = [lid(600, nil)]
        #expect(m.lidGapNotices == [LidGapNotice(title: systemSoundOnly, gaps: [lid(600, nil)])])
    }

    @Test func 系统声音不可用时说没有录到声音() {
        var m = meeting(systemSound: [period(0, 3600)])
        m.systemSoundUnavailablePeriodList = [period(500, 1000)]
        m.lidGaps = [lid(600, 900)]
        #expect(m.lidGapNotices == [LidGapNotice(title: nothing, gaps: [lid(600, 900)])])
    }

    @Test func 合盖跨过开关切换时拆开分别说明() {
        var m = meeting(systemSound: [period(700, 3600)])
        m.lidGaps = [lid(600, 900)]
        #expect(m.lidGapNotices == [
            LidGapNotice(title: micMissed, gaps: [lid(600, 700)]),
            LidGapNotice(title: systemSoundOnly, gaps: [lid(700, 900)]),
        ])
    }

    @Test func 合盖跨过不可用的起止时拆开分别说明() {
        var m = meeting(systemSound: [period(0, 3600)])
        m.systemSoundUnavailablePeriodList = [period(700, 800)]
        m.lidGaps = [lid(600, 900)]
        #expect(m.lidGapNotices == [
            LidGapNotice(title: systemSoundOnly, gaps: [lid(600, 700), lid(800, 900)]),
            LidGapNotice(title: nothing, gaps: [lid(700, 800)]),
        ])
    }

    @Test func 时段与合盖的起止差几秒时不拆出零碎的一段() {
        // 合着盖停止录音：合盖空白在 endedAt 结束，系统声音时段由 App 另取当前时间，可能早一点结束
        var m = meeting(systemSound: [period(0.5, 3599.9)])
        m.lidGaps = [lid(0, 1200), lid(3000, 3600)]
        #expect(m.lidGapNotices == [LidGapNotice(title: systemSoundOnly, gaps: [lid(0, 1200), lid(3000, 3600)])])
    }

    @Test func 切换点不改变说明时不拆开() {
        // 系统声音关着时，不可用的起止对说明没有影响
        var m = meeting(systemSound: [period(1200, 3600)])
        m.systemSoundUnavailablePeriodList = [period(700, 800)]
        m.lidGaps = [lid(600, 900)]
        #expect(m.lidGapNotices == [LidGapNotice(title: micMissed, gaps: [lid(600, 900)])])
    }

    @Test func 同一种说明的多段列在一起_先出现的排在前() {
        var m = meeting(systemSound: [period(1200, 2400)])
        m.lidGaps = [lid(1300, 1400), lid(2000, 2100), lid(2500, 2600)]
        #expect(m.lidGapNotices == [
            LidGapNotice(title: systemSoundOnly, gaps: [lid(1300, 1400), lid(2000, 2100)]),
            LidGapNotice(title: micMissed, gaps: [lid(2500, 2600)]),
        ])
    }
}
