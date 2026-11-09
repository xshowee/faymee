import Foundation

/// 把墙钟时间映射为 recording.m4a 中的偏移。
/// `Gap`、`Segment.startedAt` 记的是墙钟时间，而合并后的录音跳过了打不开的分片、
/// 也不含分片之间没录到的几秒，所以不能直接拿 t − startedAt 当偏移
public struct RecordingTimeline: Sendable {
    private struct Span: Sendable {
        var startedAt: Date
        var offset: TimeInterval
        var duration: TimeInterval
    }

    private let spans: [Span]

    /// 没有分片时返回 nil
    public init?(_ meeting: Meeting) {
        let segments = meeting.segments.sorted { $0.startedAt < $1.startedAt }
        guard !segments.isEmpty else { return nil }
        if segments.allSatisfy({ $0.offset != nil && $0.duration != nil }) {
            spans = segments.map { Span(startedAt: $0.startedAt, offset: $0.offset!, duration: $0.duration!) }
        } else {
            spans = Self.approximate(segments, meeting: meeting)
        }
    }

    /// v0.1 整理的旧会议没有记录分片位置：分片时长取下一分片 startedAt 之差，
    /// 最后一个分片取剩余的录音时长。跳过的分片和分片间没录到的几秒会让墙钟跨度偏长，
    /// 所以偏移一律钳在录音时长之内，误差在几秒内，对标注合盖空白足够。
    /// 没有录音时长（未整理成功）时退而用 endedAt 估计总长
    private static func approximate(_ segments: [Segment], meeting: Meeting) -> [Span] {
        let end = meeting.endedAt ?? segments.last!.startedAt
        let total = meeting.duration ?? max(0, end.timeIntervalSince(segments[0].startedAt))
        var cursor: TimeInterval = 0
        return segments.indices.map { i in
            let next = i + 1 < segments.count ? segments[i + 1].startedAt : nil
            let wall = next.map { $0.timeIntervalSince(segments[i].startedAt) } ?? total
            let offset = min(cursor, total)
            let duration = min(max(wall, 0), total - offset)
            cursor = offset + duration
            return Span(startedAt: segments[i].startedAt, offset: offset, duration: duration)
        }
    }

    /// 找到 startedAt ≤ t 的最后一个分片，偏移 = offset + clamp(t − startedAt, 0, duration)
    public func offset(at t: Date) -> TimeInterval {
        let span = spans.last { $0.startedAt <= t } ?? spans[0]
        return span.offset + min(max(t.timeIntervalSince(span.startedAt), 0), span.duration)
    }

    /// 空白在录音中对应的区间。没有结束时间的空白（录音中断时仍在合盖）延续到录音结束。
    /// 空白恰好落在没录到的时段时，区间可能长度为 0
    public func range(of gap: Gap) -> ClosedRange<TimeInterval> {
        let start = offset(at: gap.start)
        let end = gap.end.map(offset(at:)) ?? spans.map { $0.offset + $0.duration }.max()!
        return start...max(start, end)
    }
}
