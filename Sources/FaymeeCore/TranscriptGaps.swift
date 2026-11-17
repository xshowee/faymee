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
    /// - 合盖的部分按会议详情的合盖说明拆（`lidGapPieces`：在系统声音状态变化的时刻拆开，短于
    ///   `audioSourceEdgeTolerance` 的零碎段并进邻段），说明换成空白原因后，相邻且原因相同的几段再合成一段
    ///   （系统声音关着和开着但不可用，说明不同，空白都是 `lidClosed`）
    /// - 没有结束时间的时段（录音中断时仍在进行）延续到录音结束，推出的空白也没有结束时间
    func derivedGaps() -> [Gap] {
        var gaps: [Gap] = []
        for lid in lidGaps {
            var merged: [Gap] = []
            for piece in lidGapPieces(lid) {
                let reason = piece.kind.gapReason
                if let last = merged.last, last.reason == reason {
                    merged[merged.count - 1].end = piece.gap.end
                } else {
                    merged.append(Gap(start: piece.gap.start, end: piece.gap.end, reason: reason))
                }
            }
            gaps += merged
        }

        // 不可用 ∩ 开着，去掉合盖的部分（那里归合盖空白），首尾相接的合成一段。
        // 被合盖截剩的零碎一截不要（合着盖停止录音时，不可用时段可能比合盖晚几毫秒结束）
        let on = systemSoundPeriodList.map(Interval.init)
        let unavailable = systemSoundUnavailablePeriodList.map(Interval.init)
        let lids = lidGaps.map { Interval(start: $0.start, end: $0.end ?? .distantFuture) }
        var missing: [Interval] = []
        let pieces = unavailable
            .flatMap { u in on.compactMap { u.intersection($0) } }
            .flatMap { whole in
                let rest = whole.subtracting(lids)
                return rest == [whole] ? rest : rest.filter { !$0.isSliver }
            }
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
private struct Interval: Equatable {
    var start: Date
    var end: Date

    init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    init(_ period: WallClockPeriod) {
        self.init(start: period.start, end: period.end ?? .distantFuture)
    }

    /// 拆出来的零碎一段：短于会议数据里各个起止允许的误差
    var isSliver: Bool { end.timeIntervalSince(start) < Meeting.audioSourceEdgeTolerance }

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
