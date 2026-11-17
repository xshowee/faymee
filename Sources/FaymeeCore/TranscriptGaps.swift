import Foundation

/// 转写稿里的空白在转写时由三份原始数据推出：合盖空白、系统声音时段、系统声音不可用时段。
/// 会议数据只记原始状态，不记推出来的标签（spec「实现决定 › 会议数据」）
extension Meeting {
    /// 转写稿里的空白，经 `timeline` 换算到录音里的区间，按起点排序。
    /// 没有系统声音数据的会议，结果与合盖空白逐条对应（与以前相同）
    public func transcriptGaps(on timeline: RecordingTimeline) -> [TranscriptGap] {
        derivedGaps().map { gap in
            let r = timeline.range(of: gap)
            return TranscriptGap(start: r.lowerBound, end: r.upperBound, reason: gap.reason)
        }
    }

    /// 墙钟上的空白，原因按“麦克风是否因合盖断开”和“系统声音关 / 正常 / 不可用”组合：
    ///
    /// | 麦克风 | 系统声音 | 空白 |
    /// |---|---|---|
    /// | 正常 | 关或正常 | 无 |
    /// | 正常 | 不可用 | `systemSoundMissing` |
    /// | 合盖断开 | 关或不可用 | `lidClosed` |
    /// | 合盖断开 | 正常 | `lidClosedSystemSoundOnly` |
    ///
    /// - 系统声音不可用只在开关打开的时段内算，开关关着时就是“关”
    /// - 一段合盖在系统声音状态变化的时刻拆开，相邻且原因相同的几段合成一段
    /// - 没有结束时间的时段（录音中断时仍在进行）延续到录音结束，推出的空白也没有结束时间
    func derivedGaps() -> [Gap] {
        let on = systemSoundPeriodList.map(Interval.init)
        let unavailable = systemSoundUnavailablePeriodList.map(Interval.init)
        func reason(lidClosed: Bool, at t: Date) -> GapReason? {
            let isOn = on.contains { $0.contains(t) }
            let isUnavailable = isOn && unavailable.contains { $0.contains(t) }
            if lidClosed { return isOn && !isUnavailable ? .lidClosedSystemSoundOnly : .lidClosed }
            return isUnavailable ? .systemSoundMissing : nil
        }

        var gaps: [Gap] = []
        let changes = Set((on + unavailable).flatMap { [$0.start, $0.end] })
        for lid in lidGaps {
            let whole = Interval(start: lid.start, end: lid.end ?? .distantFuture)
            // 长度为 0 的合盖空白照样留下
            guard whole.start < whole.end else {
                gaps.append(Gap(start: lid.start, end: lid.end, reason: reason(lidClosed: true, at: lid.start)!))
                continue
            }
            let cuts = [whole.start] + changes.filter { whole.start < $0 && $0 < whole.end }.sorted() + [whole.end]
            var pieces: [(Interval, GapReason)] = []
            for (a, b) in zip(cuts, cuts.dropFirst()) {
                let r = reason(lidClosed: true, at: a)!
                if let last = pieces.last, last.1 == r {
                    pieces[pieces.count - 1].0.end = b
                } else {
                    pieces.append((Interval(start: a, end: b), r))
                }
            }
            gaps += pieces.map { $0.0.gap($0.1) }
        }

        // 不可用 ∩ 开着，去掉合盖的部分（那里归合盖空白），首尾相接的合成一段
        let lids = lidGaps.map { Interval(start: $0.start, end: $0.end ?? .distantFuture) }
        var missing: [Interval] = []
        let pieces = unavailable
            .flatMap { u in on.compactMap { u.intersection($0) } }
            .flatMap { $0.subtracting(lids) }
            .sorted { $0.start < $1.start }
        for piece in pieces {
            if let last = missing.last, piece.start <= last.end {
                missing[missing.count - 1].end = max(last.end, piece.end)
            } else {
                missing.append(piece)
            }
        }
        gaps += missing.map { $0.gap(.systemSoundMissing) }
        return gaps.sorted { $0.start < $1.start }
    }
}

/// 墙钟上的半开区间 [start, end)，没有结束时间的用 `Date.distantFuture`
private struct Interval {
    var start: Date
    var end: Date

    init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    init(_ period: WallClockPeriod) {
        self.init(start: period.start, end: period.end ?? .distantFuture)
    }

    func contains(_ t: Date) -> Bool { start <= t && t < end }

    func intersection(_ other: Interval) -> Interval? {
        let r = Interval(start: max(start, other.start), end: min(end, other.end))
        return r.start < r.end ? r : nil
    }

    /// 去掉 `others` 覆盖的部分后剩下的各段
    func subtracting(_ others: [Interval]) -> [Interval] {
        others.reduce([self]) { rest, cut in
            rest.flatMap { r -> [Interval] in
                guard r.intersection(cut) != nil else { return [r] }
                return [Interval(start: r.start, end: cut.start), Interval(start: cut.end, end: r.end)]
                    .filter { $0.start < $0.end }
            }
        }
    }

    func gap(_ reason: GapReason) -> Gap {
        Gap(start: start, end: end == .distantFuture ? nil : end, reason: reason)
    }
}
