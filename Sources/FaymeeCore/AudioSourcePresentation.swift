import Foundation

/// 会议详情里跟音源有关的文字，都由会议数据里记的原始时段推出，不写盘
extension Meeting {
    /// 系统声音时段的起止和会议的开始、结束允许差这么多仍算对齐：时段由 App 在开始、停止采集时
    /// 另取当前时间，和 `startedAt`、`endedAt` 不是同一个时刻
    static let audioSourceEdgeTolerance: TimeInterval = 5

    /// 详情页标题下的音源标记：全程开着系统声音为“麦克风 + 系统声音”，部分时段开着为“部分时段含系统声音”，
    /// 没开过为 nil，不显示。只看开关的时段，不看系统声音是否可用。
    ///
    /// “全程”指合并后只有一段，且起止与录音的起止相差都在容差内；录音中途关过再开（中间断开）算部分时段。
    /// 没有结束时间的时段（还在录、或录音中断时没关）算开到录音结束；还在录（没有 `endedAt`）时，
    /// 已经关掉的时段之后录音仍在继续，算部分时段
    public var audioSourceText: String? {
        let recordingEnd = endedAt ?? .distantFuture
        let covered = Self.merged(systemSoundPeriodList.map { (start: $0.start, end: $0.end ?? .distantFuture) })
            .map { (start: max($0.start, startedAt), end: min($0.end, recordingEnd)) }
            .filter { $0.start < $0.end }
        guard let first = covered.first else { return nil }
        let isWhole = covered.count == 1
            && first.start.timeIntervalSince(startedAt) <= Self.audioSourceEdgeTolerance
            && recordingEnd.timeIntervalSince(first.end) <= Self.audioSourceEdgeTolerance
        return isWhole ? "麦克风 + 系统声音" : "部分时段含系统声音"
    }

    /// 详情页列出的合盖时段，按系统声音的状态分组说明，组按最早的一段排先后；没有合盖时为空。
    /// 一段合盖跨过系统声音的开关切换或不可用的起止时，在这些时间点拆开，各段各归各组。
    /// 分组与转写稿里空白的标法一致（spec「会议数据」的组合表）：
    /// - 系统声音关着：内置麦克风没有录到声音（与以前的文字相同）
    /// - 开着且可用：只录到系统声音
    /// - 开着但不可用：两路都没录到
    ///
    /// 拆出来短于容差的一段并进前一段（是第一段时并进后一段）：合盖空白和系统声音时段的起止由 App
    /// 各取各的当前时间，同一时刻发生的事（比如合着盖停止录音）会差几毫秒，不该因此多出一组说明
    public var lidGapNotices: [LidGapNotice] {
        var notices: [LidGapNotice] = []
        for piece in lidGaps.flatMap(lidGapPieces) {
            if let n = notices.firstIndex(where: { $0.title == piece.kind.title }) {
                notices[n].gaps.append(piece.gap)
            } else {
                notices.append(LidGapNotice(title: piece.kind.title, gaps: [piece.gap]))
            }
        }
        return notices
    }

    /// 一段合盖在系统声音的开关切换、不可用的起止处拆开，并掉零碎的段，相邻同一说明的段接回一段。
    /// 详情页的说明和录音中开盖的提醒、面板里的合盖摘要都按它分
    func lidGapPieces(_ gap: Gap) -> [(kind: LidGapNotice.Kind, gap: Gap)] {
        let on = systemSoundPeriodList
        let unavailable = systemSoundUnavailablePeriodList
        let cuts = (on + unavailable).flatMap { [$0.start, $0.end].compactMap { $0 } }
            .filter { $0 > gap.start && $0 < (gap.end ?? .distantFuture) }
        let points = [gap.start] + Set(cuts).sorted()
        var pieces: [(kind: LidGapNotice.Kind, gap: Gap)] = points.enumerated().map { i, start in
            let kind = LidGapNotice.Kind(systemSoundOn: on.contains { $0.contains(start) },
                                         unavailable: unavailable.contains { $0.contains(start) })
            let end = i + 1 < points.count ? points[i + 1] : gap.end
            return (kind, Gap(start: start, end: end, reason: gap.reason))
        }
        func isSliver(_ g: Gap) -> Bool {
            g.end.map { $0.timeIntervalSince(g.start) < Self.audioSourceEdgeTolerance } ?? false
        }
        // 零碎的段把时间让给邻段：在前面的并进后一段，否则并进前一段
        var i = 0
        while pieces.count > 1, i < pieces.count {
            guard isSliver(pieces[i].gap) else { i += 1; continue }
            if i == 0 {
                pieces[1].gap.start = pieces[0].gap.start
            } else {
                pieces[i - 1].gap.end = pieces[i].gap.end
            }
            pieces.remove(at: i)
        }
        // 相邻同一说明的接回一段（切换点对说明没有影响，或中间零碎的段被并掉了）
        var result: [(kind: LidGapNotice.Kind, gap: Gap)] = []
        for p in pieces {
            if let last = result.last, last.kind == p.kind {
                result[result.count - 1].gap.end = p.gap.end
            } else {
                result.append(p)
            }
        }
        return result
    }

    /// 按起点排序，重叠或首尾相接的合成一段
    private static func merged(_ ranges: [(start: Date, end: Date)]) -> [(start: Date, end: Date)] {
        var result: [(start: Date, end: Date)] = []
        for r in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, r.start <= last.end {
                result[result.count - 1].end = max(last.end, r.end)
            } else {
                result.append(r)
            }
        }
        return result
    }
}

/// 详情页里一组合盖时段：一行说明，下面列出各段的时间
public struct LidGapNotice: Hashable, Sendable {
    public var title: String
    /// 按时间先后；没有结束时间的一段表示仍在合盖
    public var gaps: [Gap]

    public init(title: String, gaps: [Gap]) {
        self.title = title
        self.gaps = gaps
    }

    /// 合盖时系统声音的状态，分组和文字按它定
    enum Kind: Hashable, Sendable {
        /// 系统声音关着：内置麦克风没有录到声音
        case systemSoundOff
        /// 开着且可用：只录到系统声音
        case systemSoundOnly
        /// 开着但不可用：两路都没录到
        case nothing

        init(systemSoundOn: Bool, unavailable: Bool) {
            switch (systemSoundOn, unavailable) {
            case (false, _): self = .systemSoundOff
            case (true, false): self = .systemSoundOnly
            case (true, true): self = .nothing
            }
        }

        var title: String {
            switch self {
            case .systemSoundOff: "以下时段因合盖，内置麦克风没有录到声音"
            case .systemSoundOnly: "以下时段因合盖，只录到系统声音"
            case .nothing: "以下时段因合盖且系统声音不可用，没有录到声音"
            }
        }
    }
}

private extension WallClockPeriod {
    /// 起点算在内，终点不算；没有结束时间的一直延续
    func contains(_ t: Date) -> Bool { start <= t && t < (end ?? .distantFuture) }
}
