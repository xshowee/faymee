import Foundation

/// 转写稿与回放联动、复制用到的纯逻辑，界面只负责展示
extension Transcript {
    /// 播放到 time 秒时应高亮的条目（items 的下标）：
    /// - time 所在的那条；同时落在几条里（句子伸进空白）取开始最晚的
    /// - 落在两条之间（停顿）或最后一条之后：保持刚结束的那条，免得高亮在停顿处一闪一闪。
    ///   按结束时间而不是下标取，因为句子中间可能插着长度为 0 的空白
    /// - 第一条之前为 nil
    ///
    /// 播放时每 0.25 秒调用一次，不分配内存：items 按开始时间排序（assemble 排好，编辑不改时间），
    /// 二分找出已开始的那些，再从后往前找
    public func itemIndex(at time: TimeInterval) -> Int? {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].start <= time { lo = mid + 1 } else { hi = mid }
        }
        // 已开始的是 0..<lo。从后往前，第一条包含 time 的就是开始最晚的；
        // 都不包含时取结束最晚的，结束时间相同取下标大的
        var latestEnd: Int?
        for i in stride(from: lo - 1, through: 0, by: -1) {
            if time < items[i].end { return i }
            if latestEnd.map({ items[i].end > items[$0].end }) ?? true { latestEnd = i }
        }
        return latestEnd
    }

    /// 复制用的纯文本：一条一行，行首是方括号里的开始时间（`mm:ss` 或 `h:mm:ss`），
    /// 方括号免得和以数字开头的句子粘在一起。显示说话人（`showsSpeakers`）时句子带上说话人；
    /// 会议的笔记按时间插成 `[12:03] 笔记：……` 一行，标记不写。见 `copyLines(notes:_:)`
    ///
    /// - Parameter meeting: 转写稿所属的会议，用来取笔记。nil 时不带笔记
    public func plainText(meeting: Meeting?) -> String {
        copyLines(notes: meeting?.transcriptNotes ?? []) { $0 }.joined(separator: "\n")
    }

    /// 转写稿里一行行的先后：条目按原顺序，笔记按录音里的时间插在条目之间。
    /// 笔记排在开始时间不早于它的第一条之前（同一时刻的笔记排在句子、空白前面，同 `assemble` 里空白排在句子前面），
    /// 晚于所有条目的排在最后。`notes` 按 `Meeting.transcriptNotes` 的顺序（按时间排好）
    public func rows(notes: [TranscriptNote]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(items.count + notes.count)
        var n = notes.startIndex
        for (i, item) in items.enumerated() {
            while n < notes.endIndex, notes[n].offset <= item.start {
                rows.append(.note(notes[n]))
                n += 1
            }
            rows.append(.item(i))
        }
        rows += notes[n...].map(TranscriptRow.note)
        return rows
    }

    /// 复制全文和导出转写稿共用的行：`[03:15] 张三：文本`。只有显示说话人时句子才带前缀，
    /// 没有说话人的句子写“未知：”（与界面一致，免得被当成上一个人说的）；合盖空白和笔记永远不带。
    /// 笔记一行是 `[12:03] 笔记：文字`。`clean` 处理句子、说话人名字和笔记（导出时把换行换成空格）
    func copyLines(notes: [TranscriptNote] = [], _ clean: (String) -> String) -> [String] {
        let showsSpeakers = showsSpeakers
        return rows(notes: notes).map { row in
            switch row {
            case let .note(note):
                return "[\(formatDuration(note.offset))] 笔记：\(clean(note.text))"
            case let .item(i):
                let item = items[i]
                let text = switch item {
                case let .sentence(s) where showsSpeakers: "\(clean(speakerName(for: s)))：\(clean(s.text))"
                case let .sentence(s): clean(s.text)
                case let .gap(g): g.label
                }
                return "[\(formatDuration(item.start))] \(text)"
            }
        }
    }
}

extension Transcript {
    /// 会后转写稿里每个标记的旗子挂在哪一条旁：键是 `items` 的下标，值是挂在这条旁的标记（按 `marks` 的顺序）。
    /// 挂在离标记最近的句子旁：标记落在句子里就是这句；落在两句之间取离得近的一句，一样近取前一句
    /// （标记的意思是“刚才这段很重要”）。合盖空白不挂旗子；没有句子时为空。
    /// `marks` 按 `Meeting.transcriptMarks` 的顺序（按时间排好）。
    ///
    /// 一次归并，O(条目 + 标记)：句子按开始时间排好（同 `itemIndex`），标记也按时间排好，两个指针都只往后走。
    /// 对一个标记，句子分成已开始的（start ≤ 标记）和没开始的：
    /// - 没开始的里第一句最近，距离 start − 标记
    /// - 已开始的里，结束不早于标记的距离为 0，取下标最小的；都结束了就取结束最晚的（同样取下标最小的）。
    ///   句子可能互相包含，结束时间不一定递增，所以按“到这句为止最晚的结束”找，它是递增的
    /// 两边一样近取已开始的那句（下标更小）
    public func markedItems(_ marks: [TranscriptMark]) -> [Int: [TranscriptMark]] {
        var sentences: [(item: Int, start: TimeInterval, end: TimeInterval)] = []
        for (i, item) in items.enumerated() {
            if case let .sentence(s) = item { sentences.append((i, s.start, s.end)) }
        }
        guard !sentences.isEmpty else { return [:] }
        // reach[k]：sentences[0...k] 里最晚的结束，和最早达到它的那句
        var reach: [(end: TimeInterval, at: Int)] = []
        reach.reserveCapacity(sentences.count)
        for (k, s) in sentences.enumerated() {
            if let last = reach.last, last.end >= s.end { reach.append(last) } else { reach.append((s.end, k)) }
        }

        var placed: [Int: [TranscriptMark]] = [:]
        var started = 0  // sentences[0..<started] 已开始
        var reached = 0  // 第一个 reach[k].end ≥ 标记的 k
        for mark in marks {
            let t = mark.offset
            while started < sentences.count, sentences[started].start <= t { started += 1 }
            while reached < sentences.count, reach[reached].end < t { reached += 1 }
            var best: (k: Int, distance: TimeInterval)?
            if started > 0 {
                best = reached < started ? (reached, 0) : (reach[started - 1].at, t - reach[started - 1].end)
            }
            if started < sentences.count {
                let distance = sentences[started].start - t
                if best.map({ distance < $0.distance }) ?? true { best = (started, distance) }
            }
            if let best { placed[sentences[best.k].item, default: []].append(mark) }
        }
        return placed
    }
}

/// 会后转写稿里和会中标注有关的排版：笔记行插在哪、旗子挂在哪。
///
/// 转写稿界面每次重绘（编辑句子时每按一键、播放时每换一句）都要用，整份算一次要换算时间线、排序标注、
/// 排行、挂旗子，所以界面留着上一次的结果，`updated` 只在用到的输入变了时重算：
/// 转写稿的条目，会议的标注和录音时间线（分片、结束时间、录音时长）。改标题、热词等不重算
public struct TranscriptAnnotationLayout: Sendable {
    /// 同 `Meeting.transcriptNotes`
    public let notes: [TranscriptNote]
    /// 同 `Transcript.rows(notes:)`
    public let rows: [TranscriptRow]
    /// 同 `Transcript.markedItems(_:)`
    public let marks: [Int: [TranscriptMark]]

    private var items: [TranscriptItem]
    private var inputs: Inputs

    /// 会议里决定标注位置的部分
    private struct Inputs: Equatable, Sendable {
        var annotations: [Annotation]
        var segments: [Segment]
        var endedAt: Date?
        var duration: TimeInterval?

        init(_ meeting: Meeting) {
            annotations = meeting.annotationList
            segments = meeting.segments
            endedAt = meeting.endedAt
            duration = meeting.duration
        }
    }

    public init(transcript: Transcript, meeting: Meeting) {
        items = transcript.items
        inputs = Inputs(meeting)
        // 时间线只建一次，笔记、标记都从同一次排序里取
        guard let timeline = RecordingTimeline(meeting) else {
            notes = []
            rows = transcript.rows(notes: [])
            marks = [:]
            return
        }
        let ordered = meeting.annotationsInRecordingOrder(on: timeline)
        notes = Meeting.notes(in: ordered)
        rows = transcript.rows(notes: notes)
        marks = transcript.markedItems(Meeting.marks(in: ordered))
    }

    /// 仍对应这份转写稿和会议时为 true。条目数组没换存储时比较走快速路径，不逐条比
    public func isCurrent(transcript: Transcript, meeting: Meeting) -> Bool {
        transcript.items == items && Inputs(meeting) == inputs
    }

    /// 仍对应时沿用自己，否则重建。沿用时记下新传进来的条目：内容相同、存储不同（如从磁盘重读）的
    /// 只逐条比这一次，之后比较走数组共用存储的快速路径
    public func updated(transcript: Transcript, meeting: Meeting) -> TranscriptAnnotationLayout {
        guard isCurrent(transcript: transcript, meeting: meeting) else {
            return TranscriptAnnotationLayout(transcript: transcript, meeting: meeting)
        }
        var layout = self
        layout.items = transcript.items
        layout.inputs = Inputs(meeting)
        return layout
    }
}

/// 一个标记在转写稿里的位置：会后转写稿在离它最近的句子旁显示旗子，点旗子从这里播放
public struct TranscriptMark: Hashable, Sendable {
    /// 标注 id，会后删除用
    public var id: String
    /// 标记时刻在录音里的位置（秒），经 `RecordingTimeline` 换算
    public var offset: TimeInterval

    public init(id: String, offset: TimeInterval) {
        self.id = id
        self.offset = offset
    }
}

/// 一条笔记在转写稿里的位置：转写稿界面插一行、复制全文和导出转写稿写一行都按它
public struct TranscriptNote: Hashable, Sendable {
    /// 标注 id，会后修改、删除用
    public var id: String
    /// 笔记时刻在录音里的位置（秒），经 `RecordingTimeline` 换算
    public var offset: TimeInterval
    public var text: String

    public init(id: String, offset: TimeInterval, text: String) {
        self.id = id
        self.offset = offset
        self.text = text
    }
}

/// 转写稿里的一行：转写稿的一条（`items` 的下标），或插在条目之间的一条笔记
public enum TranscriptRow: Hashable, Sendable {
    case item(Int)
    case note(TranscriptNote)
}

extension Meeting {
    /// 会议的笔记在录音里的位置，按 `annotationsInRecordingOrder` 的顺序。标记不在里面。
    /// 每条笔记单独换算（不用 `AnnotationSpan.at`）；没有分片、换算不了时为空
    public var transcriptNotes: [TranscriptNote] {
        guard let timeline = RecordingTimeline(self) else { return [] }
        return Self.notes(in: annotationsInRecordingOrder(on: timeline))
    }

    /// 会议的标记在录音里的位置，按 `annotationsInRecordingOrder` 的顺序。笔记不在里面。
    /// 每个标记单独换算（不用 `AnnotationSpan.at`，合并的标记只留了最早一个的时刻）；没有分片时为空
    public var transcriptMarks: [TranscriptMark] {
        guard let timeline = RecordingTimeline(self) else { return [] }
        return Self.marks(in: annotationsInRecordingOrder(on: timeline))
    }

    /// 排好的标注里的笔记、标记。转写稿排版换算一次、排序一次，两者都从这里取
    static func notes(in ordered: [(annotation: Annotation, offset: TimeInterval)]) -> [TranscriptNote] {
        ordered.compactMap { a, offset in
            guard a.kind == .note, let text = a.text else { return nil }
            return TranscriptNote(id: a.id, offset: offset, text: text)
        }
    }

    static func marks(in ordered: [(annotation: Annotation, offset: TimeInterval)]) -> [TranscriptMark] {
        ordered.compactMap { a, offset in a.kind == .mark ? TranscriptMark(id: a.id, offset: offset) : nil }
    }
}

extension TranscriptGap {
    /// 转写稿里空白那一行的文字，如“合盖，未录到声音（10:00–13:00，03:00）”
    public var label: String {
        let range = "\(formatDuration(start))–\(formatDuration(end))，\(formatDuration(end - start))"
        return switch reason {
        case .lidClosed: "合盖，未录到声音（\(range)）"
        }
    }
}
