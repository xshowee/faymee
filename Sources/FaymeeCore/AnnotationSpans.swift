import Foundation

/// 一个会中标注在录音里对应的一段：纪要生成时给区间里的句子加 `★`，并对每个区间单独展开一条。
/// 时间是相对 recording.m4a 开头的秒数
public struct AnnotationSpan: Hashable, Sendable {
    public var kind: AnnotationKind
    /// 所含的标注 id，按时间先后。合并的标记有多个，笔记只有一个
    public var annotationIDs: [String]
    /// 标注的时刻在录音里的位置，合并的标记取最早的一个。区间列表按它排序
    public var at: TimeInterval
    public var start: TimeInterval
    public var end: TimeInterval
    /// 笔记的文字，标记为 nil
    public var noteText: String?
    /// 与区间有时间重叠的句子，按转写稿顺序
    public var sentenceIDs: [String]

    public init(kind: AnnotationKind, annotationIDs: [String], at: TimeInterval, start: TimeInterval,
                end: TimeInterval, noteText: String?, sentenceIDs: [String]) {
        self.kind = kind
        self.annotationIDs = annotationIDs
        self.at = at
        self.start = start
        self.end = end
        self.noteText = noteText
        self.sentenceIDs = sentenceIDs
    }

    /// 标注时刻之前、之后各取多少秒（墙钟）。暂定值，用真实会议校准后改这里
    public static func window(_ kind: AnnotationKind) -> (before: TimeInterval, after: TimeInterval) {
        switch kind {
        case .mark: (60, 15)
        case .note: (120, 30)
        }
    }
}

extension Meeting {
    /// 会中标注换算成录音里的区间，按标注时刻排序（同一时刻按创建先后）。
    /// - 区间两端的墙钟时间分别经 `RecordingTimeline` 换算，所以自然截在录音范围之内，
    ///   整理时跳过的分片、分片之间没录到的几秒也不占区间
    /// - 区间重叠或首尾相接的标记合并成一段（链式），笔记各自独立，也不把两边的标记隔开
    /// - 没有句子的区间照样返回；没有分片（换算不了）时返回空列表
    public func annotationSpans(in transcript: Transcript) -> [AnnotationSpan] {
        guard let timeline = RecordingTimeline(self) else { return [] }
        let sorted = annotationList.enumerated()
            .map { (at: timeline.offset(at: $0.element.at), index: $0.offset, annotation: $0.element) }
            .sorted { ($0.at, $0.index) < ($1.at, $1.index) }

        // 换算是单调的，按时刻排好之后区间的起点、终点也是有序的，只需和上一段标记比
        var spans: [AnnotationSpan] = []
        var lastMark: Int?
        for (offset, _, a) in sorted {
            let w = AnnotationSpan.window(a.kind)
            let start = timeline.offset(at: a.at.addingTimeInterval(-w.before))
            let end = timeline.offset(at: a.at.addingTimeInterval(w.after))
            if a.kind == .mark, let i = lastMark, start <= spans[i].end {
                spans[i].end = max(spans[i].end, end)
                spans[i].annotationIDs.append(a.id)
                continue
            }
            spans.append(AnnotationSpan(kind: a.kind, annotationIDs: [a.id], at: offset, start: start, end: end,
                                        noteText: a.text, sentenceIDs: []))
            if a.kind == .mark { lastMark = spans.count - 1 }
        }

        let gaps = lidGaps.map(timeline.range(of:)).sorted { $0.lowerBound < $1.lowerBound }
        let sentences = transcript.sentences
        for i in spans.indices {
            let (start, end) = (spans[i].start, spans[i].end)
            spans[i].sentenceIDs = sentences.filter { s in
                let overlap = (max(s.start, start), min(s.end, end))
                return overlap.0 < overlap.1 && !Self.covered(overlap, by: gaps)
            }.map(\.id)
        }
        return spans
    }

    /// 区间 (a, b) 是否整个落在合盖空白（按起点排好序）里。跨过空白边界的句子转写稿会保留，
    /// 它与区间的重叠若全在空白里，说明区间里其实没录到声音，不算区间里的句子
    private static func covered(_ range: (TimeInterval, TimeInterval), by gaps: [ClosedRange<TimeInterval>]) -> Bool {
        var cursor = range.0
        for g in gaps where g.upperBound > cursor {
            guard g.lowerBound <= cursor else { return false }
            cursor = g.upperBound
            if cursor >= range.1 { return true }
        }
        return false
    }
}
