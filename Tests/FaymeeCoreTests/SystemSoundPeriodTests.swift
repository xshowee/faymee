import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-10T02:00:00Z", strategy: .iso8601)

/// 相对 t0 的墙钟时间
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func meeting() -> Meeting {
    Meeting(id: "m", title: "会议", startedAt: t0, status: .recording)
}

@Suite struct SystemSoundPeriodTests {
    @Test func 录音中开关两次记成两段() {
        var m = meeting()
        m.beginSystemSoundPeriod(at: at(0))
        m.endSystemSoundPeriod(at: at(60))
        m.beginSystemSoundPeriod(at: at(120))
        m.endSystemSoundPeriod(at: at(180))
        #expect(m.systemSoundPeriodList == [WallClockPeriod(start: at(0), end: at(60)),
                                            WallClockPeriod(start: at(120), end: at(180))])
    }

    /// 开着系统声音开始录音后又点了一次“打开”（例如界面重复触发）：不另开一段
    @Test func 已经开着时再打开不另开一段() {
        var m = meeting()
        m.beginSystemSoundPeriod(at: at(0))
        m.beginSystemSoundPeriod(at: at(30))
        #expect(m.systemSoundPeriodList == [WallClockPeriod(start: at(0))])
    }

    @Test func 停止录音时结束所有仍在进行的时段() {
        var m = meeting()
        m.lidGaps.append(Gap(start: at(100), reason: .lidClosed))
        m.beginSystemSoundPeriod(at: at(0))
        m.systemSoundUnavailablePeriodList = [WallClockPeriod(start: at(10), end: at(20)),
                                              WallClockPeriod(start: at(150))]
        m.endOpenPeriods(at: at(300))
        #expect(m.lidGaps == [Gap(start: at(100), end: at(300), reason: .lidClosed)])
        #expect(m.systemSoundPeriodList == [WallClockPeriod(start: at(0), end: at(300))])
        #expect(m.systemSoundUnavailablePeriodList == [WallClockPeriod(start: at(10), end: at(20)),
                                                       WallClockPeriod(start: at(150), end: at(300))])
    }

    /// 中断恢复时结束时间按最后一个麦克风分片的修改时间估，可能早于之后才开的时段：
    /// 结束在起点，不留下倒着走的时段
    @Test func 恢复时估出的结束早于时段起点时结束在起点() {
        var m = meeting()
        m.beginSystemSoundPeriod(at: at(200))
        m.systemSoundUnavailablePeriodList = [WallClockPeriod(start: at(250))]
        m.endOpenPeriods(at: at(120))
        #expect(m.systemSoundPeriodList == [WallClockPeriod(start: at(200), end: at(200))])
        #expect(m.systemSoundUnavailablePeriodList == [WallClockPeriod(start: at(250), end: at(250))])
    }

    /// 没开过系统声音的会议：不多出空的字段，meeting.json 与以前相同
    @Test func 没开过系统声音时不写系统声音字段() {
        var m = meeting()
        m.endOpenPeriods(at: at(300))
        #expect(m.systemSoundPeriods == nil)
        #expect(m.systemSoundUnavailablePeriods == nil)
        #expect(m.gaps == nil)
    }

    /// 分片打开时由回调记一次，停止录音时再把写盘模块报过的分片补记一遍（防止回调晚于停止）：
    /// 同一个分片只记一次
    @Test func 同一个系统声音分片只记一次() {
        var m = meeting()
        let first = SystemSoundSegment(file: "0001.caf", startedAt: at(0), sampleRate: 48000, channels: 2)
        let second = SystemSoundSegment(file: "0002.caf", startedAt: at(60), sampleRate: 48000, channels: 2)
        let added = [m.addSystemSoundSegment(first), m.addSystemSoundSegment(first), m.addSystemSoundSegment(second)]
        #expect(added == [true, false, true])
        #expect(m.systemSoundSegmentList == [first, second])
    }

    /// 系统声音不可用时开一段，恢复后结束；仍不可用时再报一次（重试又失败）不另开一段
    @Test func 不可用时开一段恢复后结束() {
        var m = meeting()
        m.beginSystemSoundPeriod(at: at(0))
        m.beginSystemSoundUnavailablePeriod(at: at(0))
        m.beginSystemSoundUnavailablePeriod(at: at(10))
        m.endSystemSoundUnavailablePeriod(at: at(40))
        m.endSystemSoundUnavailablePeriod(at: at(50))
        #expect(m.systemSoundUnavailablePeriodList == [WallClockPeriod(start: at(0), end: at(40))])
    }

    /// “不可用”只在开关时段内才算：关掉开关时，仍在进行的不可用时段和开关时段同时结束
    @Test func 关掉开关时不可用时段一起结束() {
        var m = meeting()
        m.beginSystemSoundPeriod(at: at(0))
        m.beginSystemSoundUnavailablePeriod(at: at(0))
        m.endSystemSoundPeriod(at: at(90))
        #expect(m.systemSoundPeriodList == [WallClockPeriod(start: at(0), end: at(90))])
        #expect(m.systemSoundUnavailablePeriodList == [WallClockPeriod(start: at(0), end: at(90))])
    }
}
