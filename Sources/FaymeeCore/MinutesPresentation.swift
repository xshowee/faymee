import Foundation

/// 详情页显示纪要用到的纯逻辑，界面只负责摆放

extension CalendarDate {
    /// 星期，如“周三”。按公历直接从年月日算，不受系统语言、时区影响
    public var weekdayText: String {
        // Sakamoto 算法，0 为周日
        let t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        let y = month < 3 ? year - 1 : year
        let w = (y + y / 4 - y / 100 + y / 400 + t[month - 1] + day) % 7
        return ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][w]
    }

    /// 如“11 月 18 日（周三）”；和会议不在同一年时带年份，如“2027 年 1 月 4 日（周一）”
    public func displayText(meetingStartedAt: Date, timeZone: TimeZone = .current) -> String {
        "\(dayText(meetingStartedAt: meetingStartedAt, timeZone: timeZone))（\(weekdayText)）"
    }

    /// 不带星期的日期，年份规则同 `displayText`
    func dayText(meetingStartedAt: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let md = "\(month) 月 \(day) 日"
        return calendar.component(.year, from: meetingStartedAt) == year ? md : "\(year) 年 \(md)"
    }
}

extension MinutesItem {
    /// 待办的截止时间：保留会上的原话，同时显示按会议日期换算的日期，
    /// 如“下周三（11 月 18 日，周三）”。换算不出来时只显示原话，都没有时为 nil
    public func dueText(meetingStartedAt: Date, timeZone: TimeZone = .current) -> String? {
        let phrase = due?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let dueDate else { return phrase }
        guard let phrase else { return dueDate.displayText(meetingStartedAt: meetingStartedAt, timeZone: timeZone) }
        return "\(phrase)（\(dueDate.dayText(meetingStartedAt: meetingStartedAt, timeZone: timeZone))，\(dueDate.weekdayText)）"
    }

    /// 「会中标注」笔记条目要附上的笔记原话（一行），界面显示和导出 Markdown 共用。
    /// 未扩写的条目文字就是原话，不重复；改过文字后照样附上。不是笔记条目时为 nil
    public var displayedNote: String? {
        guard let note = note?.singleLine, note != text.singleLine else { return nil }
        return note
    }
}

extension MinutesSection {
    /// 要显示的条目：已删除的不显示（撤销由 07 提供）。为空时界面显示“无”
    public var visibleItems: [MinutesItem] { items.filter { !$0.deleted } }
}

extension MinutesSync {
    /// 纪要顶部的提示条文字，同步时为 nil。重新转写的那条要醒目，修改句子的那条不显眼
    public var notice: String? {
        switch self {
        case .inSync: nil
        case .retranscribed: "转写稿已重新生成，纪要的出处可能不准确"
        case .edited: "转写稿有修改"
        case .annotationsChanged: "会中标注有改动，可以重新生成纪要"
        }
    }
}

/// 条目后面的出处时间：显示 `label`，悬停显示 `hint`，点击跳到 `target`
public struct MinutesRefChip: Hashable, Sendable {
    /// 如 "03:15"、"1:02:03"
    public var label: String
    /// 被引用的原句；拿不到原句时是原因
    public var hint: String
    public var target: MinutesRefTarget
}

extension MinutesRef {
    /// 在当前转写稿里解析出处（规则见 `Transcript.locate`）。
    /// 转写稿不存在或读不出来时只认生成时记下的 `start`，不定位句子。
    /// 要解析一份纪要的所有出处时用 `MinutesRefResolver`
    public func chip(in transcript: Transcript?, sync: MinutesSync) -> MinutesRefChip {
        chip(locator: transcript.map(TranscriptRefLocator.init), sync: sync)
    }

    func chip(locator: TranscriptRefLocator?, sync: MinutesSync) -> MinutesRefChip {
        guard let locator else {
            return MinutesRefChip(label: formatDuration(start), hint: "转写稿不可用，原句无法显示",
                                  target: MinutesRefTarget(time: start, sentenceID: nil, quote: nil))
        }
        let target = locator.locate(self, sync: sync)
        return MinutesRefChip(label: formatDuration(target.time), hint: target.quote ?? "转写稿已更新，原句不可用",
                              target: target)
    }
}

/// 一份纪要对当前转写稿、会议的同步状态和出处解析，详情页每次渲染都要用。
/// 同步状态要对整份转写稿算一次 SHA-256（`textHash`），句子索引也要遍历整份转写稿，
/// 所以只在纪要的 `source`、转写稿或会议的会中标注变了时重建（见 `updated`），不随每次渲染重算
public struct MinutesRefResolver: Sendable {
    /// 没有纪要或转写稿时为 `.inSync`
    public let sync: MinutesSync
    private let source: MinutesSource?
    private var transcript: Transcript?
    /// 建它时会议的 `annotationsHash`；会议为 nil 时不比对
    private let annotationsHash: String??
    private let locator: TranscriptRefLocator?

    /// - Parameter meeting: 纪要所属的会议，用来判断“会中标注有改动”；nil 时不判断
    public init(minutes: Minutes?, transcript: Transcript?, meeting: Meeting?) {
        sync = minutes.flatMap { m in transcript.map { m.sync(with: $0, meeting: meeting) } } ?? .inSync
        source = minutes?.source
        self.transcript = transcript
        annotationsHash = meeting.map(\.annotationsHash)
        locator = transcript.map(TranscriptRefLocator.init)
    }

    /// 是否仍对应这份纪要、转写稿和会议的标注：同步状态只取决于纪要的 `source`，改条目、改会议的其他字段不用重建
    public func isCurrent(minutes: Minutes?, transcript: Transcript?, meeting: Meeting?) -> Bool {
        minutes?.source == source && meeting.map(\.annotationsHash) == annotationsHash
            && transcript == self.transcript
    }

    /// 仍对应这份纪要、转写稿和会议的标注时沿用自己，否则重建。沿用时记下新传进来的转写稿：
    /// 内容相同、存储不同（如从磁盘重读）的转写稿只逐句比这一次，之后比较走数组共用存储的快速路径
    public func updated(minutes: Minutes?, transcript: Transcript?, meeting: Meeting?) -> MinutesRefResolver {
        guard isCurrent(minutes: minutes, transcript: transcript, meeting: meeting) else {
            return MinutesRefResolver(minutes: minutes, transcript: transcript, meeting: meeting)
        }
        var resolver = self
        resolver.transcript = transcript
        return resolver
    }

    /// 同 `MinutesRef.chip(in:sync:)`
    public func chip(_ ref: MinutesRef) -> MinutesRefChip {
        ref.chip(locator: locator, sync: sync)
    }
}

/// 详情页纪要标题旁的状态。由会议上的持久状态和管线的内存状态派生，不写盘
public enum MinutesStatus: Hashable, Sendable {
    /// 还没有可用的转写稿（没转写过、转写中、读不出来），不能生成
    case awaitingTranscript
    /// 从未生成：v0.2 的旧会议、自动生成关着，或内容太少没有自动生成
    case notGenerated(tooLittleText: Bool)
    /// 排队中，附上在等什么；只是排在别的会议后面时为 nil
    case queued(MinutesWaitReason?)
    case loadingModel(Double)
    /// 生成中；刚开始、还没有进度时为 nil
    case generating(Double?)
    case failed(String)
    case done

    /// - Parameters:
    ///   - state: `meeting.minutes`
    ///   - activity: `MinutesPipeline.activity(for:)`，有值时以它为准（磁盘上的状态可能还没跟上）
    ///   - waitReason: `MinutesPipeline.waitReason(for:)`
    ///   - transcript: 当前转写稿，没有或读不出来时为 nil。只在从未生成时用来判断能不能生成、内容是否太少
    public init(state: MinutesState?, activity: MinutesActivity?, waitReason: MinutesWaitReason?,
                transcript: Transcript?) {
        switch (activity, state?.status) {
        case let (.loading(p)?, _): self = .loadingModel(p)
        case let (.generating(p)?, _): self = .generating(p)
        case (nil, nil):
            guard let transcript else { self = .awaitingTranscript; return }
            self = .notGenerated(tooLittleText: transcript.effectiveTextCount < MinutesPipeline.minimumTextCount)
        case (nil, .queued): self = .queued(waitReason)
        case (nil, .running): self = .generating(nil)
        case (nil, .failed): self = .failed(state?.error ?? "生成纪要失败")
        case (nil, .done): self = .done
        }
    }

    public var text: String? {
        switch self {
        case .awaitingTranscript: "转写完成后才能生成纪要"
        case let .notGenerated(tooLittleText): tooLittleText ? "内容太少，未生成纪要" : nil
        case .queued(nil): "排队中"
        case .queued(.model): "等待下载模型"
        case .queued(.power): "等待接通电源"
        case .queued(.transcription): "等待转写完成"
        case let .loadingModel(p): "正在加载模型（\(formatPercent(p))）"
        case let .generating(p?): "生成中 \(formatPercent(p))"
        case .generating(nil): "生成中…"
        case let .failed(error): error
        case .done: nil
        }
    }

    /// 状态旁的按钮。都是用户手动触发，入队时不等接通电源（`enqueue(_:now: true)`）
    public var actionTitle: String? {
        switch self {
        case .notGenerated: "生成纪要"
        case .queued(.power): "现在生成"
        case .failed: "重试"
        default: nil
        }
    }

    public var progress: Double? {
        switch self {
        case let .loadingModel(p): p
        case let .generating(p): p
        default: nil
        }
    }

    /// 排队或生成中：成功后会整份替换现有纪要，这时不提供“重新生成”
    public var isBusy: Bool {
        switch self {
        case .queued, .loadingModel, .generating: true
        default: false
        }
    }
}

/// 进度百分比，四舍五入到整数，如“42%”。超出 0...1 的按边界算
public func formatPercent(_ p: Double) -> String {
    "\(Int((min(max(p, 0), 1) * 100).rounded()))%"
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
