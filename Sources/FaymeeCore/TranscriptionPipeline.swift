import Foundation
import Observation

/// 管线对外的唯一依赖：会议元数据由宿主（App 里是 AppModel）统一读写。
/// meeting.json 只有一个写入者，管线不直接存会议，免得和改标题等操作互相覆盖
@MainActor
public protocol TranscriptionHost: AnyObject {
    /// 会议的最新状态；已删除时返回 nil
    func meeting(_ id: String) -> Meeting?
    /// 更新会议的转写状态并保存
    func setTranscription(_ state: TranscriptionState, for id: String)
}

/// 一次转写的结果。被取消（开始录音、删除会议）的转写没有结果
public enum TranscriptionOutcome: Hashable, Sendable {
    case done(Transcript)
    case failed(String)
}

/// 正在转写的会议进行到哪一步，只在内存里，不写盘
public enum TranscriptionActivity: Hashable, Sendable {
    /// 准备引擎资源（首次使用时下载模型等），0...1
    case preparing(Double)
    /// 0...1
    case transcribing(Double)
}

/// 转写队列：一次转写一场，其余按入队先后排队。
/// 转写稿只在成功时整体写入，失败或取消都保留原来的转写稿
@MainActor @Observable
public final class TranscriptionPipeline {
    /// 排队中的会议，不含正在转写的
    public private(set) var queue: [String] = [] {
        didSet { reportIdle() }
    }
    /// 正在转写的会议
    public private(set) var activeID: String? {
        didSet { reportIdle() }
    }
    public private(set) var activity: TranscriptionActivity?
    /// 转写时传给引擎的热词。每场转写开始时取一次快照，写进转写稿
    public var hotwords: [String] = []
    /// 暂停时不开始新的转写；暂停的瞬间正在进行的转写被取消并放回队首，恢复后从头再转。
    /// 录音和整理期间暂停：录音可靠性优先于转写速度
    public var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            if isSuspended, let id = activeID {
                // 先放回队首再取消，中间不出现“空闲”的瞬间
                queue.insert(id, at: 0)
                cancelActive()
                host?.setTranscription(TranscriptionState(status: .queued), for: id)
            } else if !isSuspended {
                startNext()
            }
        }
    }

    /// 为 true 时不开始新的转写，但不取消正在进行的。纪要生成中由纪要管线置位：
    /// 两者都是重任务，一次只跑一个，已经在生成的纪要跑完再让给转写（见 `MinutesPipeline.coordinate`）
    public var isHeld = false {
        didSet { if !isHeld && oldValue { startNext() } }
    }

    /// `isIdle` 变化时调用。纪要管线据此决定能否开始：转写不空闲时不开始新的纪要
    @ObservationIgnored public var onIdleChange: ((Bool) -> Void)?
    @ObservationIgnored private var reportedIdle = true

    /// 转写完成或失败时调用（不含取消）。调用时 activeID 还是这场会议，管线还不算空闲
    @ObservationIgnored public var onFinish: ((String, TranscriptionOutcome) -> Void)?

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private let transcriber: any Transcriber
    @ObservationIgnored private let engine: String
    @ObservationIgnored private weak var host: TranscriptionHost?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 每开始或取消一次转写加一。取消后引擎可能不理会、照常返回，靠它丢弃过期的结果和进度
    @ObservationIgnored private var generation = 0

    /// - Parameter engine: 写进转写稿的引擎名，如 "apple/speechanalyzer"
    public init(store: MeetingStore, transcriber: any Transcriber, engine: String, host: TranscriptionHost) {
        self.store = store
        self.transcriber = transcriber
        self.engine = engine
        self.host = host
    }

    public var isIdle: Bool { activeID == nil && queue.isEmpty }

    /// 某场会议正在进行的步骤；不在转写中时为 nil
    public func activity(for id: String) -> TranscriptionActivity? {
        activeID == id ? activity : nil
    }

    /// 排队转写（自动转写、旧会议的“转写”、“重试”、“重新转写”都走这里）。
    /// 只接受已整理好的会议；已在队列中或正在转写时忽略。返回是否入队
    @discardableResult
    public func enqueue(_ id: String) -> Bool {
        guard let m = host?.meeting(id), m.status == .done, m.recording != nil,
              id != activeID, !queue.contains(id) else { return false }
        queue.append(id)
        host?.setTranscription(TranscriptionState(status: .queued), for: id)
        startNext()
        return true
    }

    /// App 启动时调用：上次退出时排队中或转写中的会议重新排队，转写中的从头转。
    /// 队列顺序不落盘，上次正在转写的排最前，其余按结束时间近似整理完成的先后。
    /// 从未转写（含 v0.1 旧会议）、已完成、失败的不动
    public func restore(_ meetings: [Meeting]) {
        func rank(_ m: Meeting) -> Int { m.transcription?.status == .running ? 0 : 1 }
        meetings
            .filter { $0.transcription?.status == .queued || $0.transcription?.status == .running }
            .sorted { (rank($0), $0.endedAt ?? $0.startedAt) < (rank($1), $1.endedAt ?? $1.startedAt) }
            .forEach { enqueue($0.id) }
    }

    /// 会议即将被删除：移出队列，正在转写的立即取消。不写任何文件，也不再更新这场会议的状态
    public func remove(_ id: String) {
        queue.removeAll { $0 == id }
        if activeID == id {
            cancelActive()
            startNext()
        }
    }

    private func startNext() {
        guard !isSuspended, !isHeld, activeID == nil, let id = queue.first else { return }
        guard let m = host?.meeting(id), let audio = store.recordingURL(m) else {
            queue.removeFirst()
            return startNext()
        }

        generation += 1
        let token = generation
        let hotwords = hotwords
        let transcriber = transcriber
        // 先设 activeID 再移出队列，中间不出现“空闲”的瞬间
        activeID = id
        queue.removeFirst()
        activity = .preparing(0)
        host?.setTranscription(TranscriptionState(status: .running), for: id)

        // 进度回调来自引擎的线程，回到主线程再更新
        let report: @Sendable (TranscriptionActivity) -> Void = { [weak self] a in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.activity = a
            }
        }
        task = Task(priority: .utility) { [weak self] in
            let result: Result<[TranscribedSentence], Error>
            do {
                try await transcriber.prepare { report(.preparing($0)) }
                report(.transcribing(0))
                result = .success(try await transcriber.transcribe(
                    audio: audio, hotwords: hotwords, progress: { report(.transcribing($0)) }))
            } catch {
                result = .failure(error)
            }
            self?.finish(id, token: token, hotwords: hotwords, result: result)
        }
    }

    private func finish(_ id: String, token: Int, hotwords: [String], result: Result<[TranscribedSentence], Error>) {
        // 已被取消：结果作废，什么都不写
        guard token == generation, activeID == id else { return }
        activity = nil
        task = nil
        // 写好转写稿、更新状态、回调之后才清 activeID：清掉就算空闲，等着的纪要会马上读转写稿快照
        defer {
            activeID = nil
            startNext()
        }
        // 转写期间会议被删除
        guard let host, let m = host.meeting(id) else { return }

        let outcome: TranscriptionOutcome
        do {
            let transcript = Transcript.assemble(try result.get(), meeting: m, engine: engine,
                                                 hotwords: hotwords, createdAt: Date())
            try store.saveTranscript(transcript, for: id)
            outcome = .done(transcript)
            host.setTranscription(TranscriptionState(status: .done), for: id)
        } catch {
            outcome = .failed(error.localizedDescription)
            host.setTranscription(TranscriptionState(status: .failed, error: error.localizedDescription), for: id)
        }
        onFinish?(id, outcome)
    }

    private func reportIdle() {
        guard isIdle != reportedIdle else { return }
        reportedIdle = isIdle
        onIdleChange?(isIdle)
    }

    private func cancelActive() {
        task?.cancel()
        task = nil
        generation += 1
        activeID = nil
        activity = nil
    }
}

extension Transcript {
    /// 把引擎输出的句子和会议的合盖空白合成转写稿。
    /// 空白按分片位置换算到录音中的区间；中点落在空白里的句子丢弃（合盖时录音是静音，识别出的只能是噪声），
    /// 跨过空白边界的句子中点在外，保留。空白在录音里长度为 0（落在没录到的时段）时照样显示标记
    static func assemble(_ sentences: [TranscribedSentence], meeting: Meeting, engine: String,
                         hotwords: [String], createdAt: Date) -> Transcript {
        let gaps: [TranscriptGap] = RecordingTimeline(meeting).map { timeline in
            meeting.lidGaps.map { gap in
                let r = timeline.range(of: gap)
                return TranscriptGap(start: r.lowerBound, end: r.upperBound, reason: gap.reason)
            }
        } ?? []

        let kept = sentences.enumerated()
            .filter { _, s in
                let mid = (s.start + s.end) / 2
                return !gaps.contains { $0.start <= mid && mid < $0.end }
            }
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)

        // 同一时刻的空白排在句子前面
        let items = kept.enumerated()
            .map { i, s in TranscriptItem.sentence(TranscriptSentence(id: "s\(i + 1)", start: s.start, end: s.end, text: s.text)) }
            .enumerated()
            .map { (key: ($1.start, 1, $0), item: $1) }
            + gaps.enumerated().map { (key: ($1.start, 0, $0), item: TranscriptItem.gap($1)) }

        return Transcript(engine: engine, createdAt: createdAt, hotwords: hotwords,
                          items: items.sorted { $0.key < $1.key }.map(\.item))
    }
}
