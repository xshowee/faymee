import Foundation

/// 会中面板里的一行：实时字幕的句子、分隔行，或者插在对应时间处的标记（旗子）、笔记。
/// 没定稿的临时文字不在这里，面板把它接在最后
public struct LivePanelRow: Hashable, Sendable, Identifiable {
    public enum Content: Hashable, Sendable {
        case caption(LiveCaption)
        case gap(LiveCaptionGap)
        case mark(Annotation)
        case note(Annotation)
    }

    public var content: Content
    /// 录音里的秒数（以录音开始的墙钟时间为零点，与字幕同一个零点）
    public var time: TimeInterval

    /// 字幕行为 `c<编号>`，标注为它的 id（`a1`……），互不重复，可直接做 `ForEach` 和滚动锚点
    public var id: String {
        switch content {
        case .caption(let c): "c\(c.id)"
        case .gap(let g): "c\(g.id)"
        case .mark(let a), .note(let a): a.id
        }
    }

    /// 字幕行和标注按录音里的时间合在一起。同一时刻字幕在前：标在一句话中间时，那句话先开始。
    ///
    /// 标注的时间直接用墙钟时间减录音开始时间（字幕也是这么算的），不经 `RecordingTimeline`：
    /// 后者扣掉了合盖空白，和字幕的时间对不上。标注全部显示，不随字幕只留最近 200 句而丢掉
    public static func rows(lines: [LiveCaptionLine], annotations: [Annotation],
                            recordingStartedAt: Date) -> [LivePanelRow] {
        let captions = lines.map { line in
            switch line {
            case .sentence(let s): LivePanelRow(content: .caption(s), time: s.start)
            case .gap(let g): LivePanelRow(content: .gap(g), time: g.start)
            }
        }
        let marks = annotations
            .map { a in
                LivePanelRow(content: a.kind == .mark ? .mark(a) : .note(a),
                             time: a.at.timeIntervalSince(recordingStartedAt))
            }
            .sorted { $0.time < $1.time }

        // 字幕本身按出现先后，不重排；标注逐条插到第一个比它晚开始的字幕前面
        var rows: [LivePanelRow] = []
        rows.reserveCapacity(captions.count + marks.count)
        var next = marks.startIndex
        for caption in captions {
            while next < marks.endIndex, marks[next].time < caption.time {
                rows.append(marks[next])
                next += 1
            }
            rows.append(caption)
        }
        rows.append(contentsOf: marks[next...])
        return rows
    }
}
