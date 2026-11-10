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
    /// 更新会议的区分说话人状态并保存
    func setDiarization(_ state: DiarizationState?, for id: String)
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
    /// 区分说话人，0...1。完整转写在转写之后进入这一步；只区分说话人的任务只有这一步
    case diarizing(Double)
}

/// 转写队列：一次转写一场，其余按入队先后排队。
/// 转写稿只在成功时整体写入，失败或取消都保留原来的转写稿。
///
/// 队列里的任务分两种：完整转写（转写 → 区分说话人 → 合成并保存），和只区分说话人
/// （旧会议补说话人、重新区分说话人）。两种共用一条队列、一样的暂停、取消、作废规则，
/// 一次只跑一个重任务。只区分说话人的任务只写说话人状态，不碰转写状态
@MainActor @Observable
public final class TranscriptionPipeline {
    /// 排队中的会议（两种任务都在里面），不含正在进行的
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
    /// “区分说话人”开关（App 存 UserDefaults，默认开）。关闭时完整转写跳过这一步，不调用区分引擎，
    /// 新稿没有说话人，说话人状态退回 nil（旧稿的名字、合并随之丢掉，见 `transcriptionDiarizes`）。
    /// 每场转写开始时取一次快照
    public var diarizes = true

    /// 现在开始的完整转写会不会区分说话人（开关开着且有区分引擎）。不会时重新转写丢掉全部说话人信息，
    /// 确认提示据此把说话人名字也算进修改数（见 `Transcript.retranscribeEditCount(diarizes:)`）
    public var transcriptionDiarizes: Bool { diarizes && diarizer != nil }
    /// 声纹识别的阈值（余弦相似度，超过才认）。引擎给出推荐值后由 App 设置
    public var voiceprintThreshold = VoiceprintLibrary.defaultMatchThreshold
    /// 暂停时不开始新的转写；暂停的瞬间正在进行的转写被取消并放回队首，恢复后从头再转。
    /// 录音和整理期间暂停：录音可靠性优先于转写速度
    public var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            if isSuspended, let id = activeID {
                // 先放回队首再取消，中间不出现“空闲”的瞬间
                queue.insert(id, at: 0)
                setQueued(id)
                cancelActive()
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
    @ObservationIgnored private let diarizer: (any SpeakerDiarizer)?
    @ObservationIgnored private let voiceprints: VoiceprintStore?
    @ObservationIgnored private weak var host: TranscriptionHost?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 被取消、可能还没退出的任务。在它退出前不算空闲（纪要不开始用引擎），
    /// 下一场转写也等它退出再调用引擎，一次只跑一个重任务
    @ObservationIgnored private var cancelled: Task<Void, Never>? {
        didSet { reportIdle() }
    }
    @ObservationIgnored private var cancelCount = 0
    /// 预定了转写、还没入队的会议，见 `reserve(_:)`
    @ObservationIgnored private var reserved: Set<String> = [] {
        didSet { reportIdle() }
    }
    /// 每开始或取消一次转写加一。取消后引擎可能不理会、照常返回，靠它丢弃过期的结果和进度
    @ObservationIgnored private var generation = 0

    private enum Job: Equatable {
        case transcription
        /// speakerCount 为 nil 时由引擎判断人数
        case diarization(speakerCount: Int?)
    }

    /// 排队中和正在进行的会议各是哪种任务
    @ObservationIgnored private var jobs: [String: Job] = [:]

    /// - Parameters:
    ///   - engine: 写进转写稿的引擎名，如 "apple/speechanalyzer"
    ///   - diarizer: 区分说话人引擎；nil 表示没有可用的引擎，完整转写跳过这一步（不算失败）
    ///   - voiceprints: 声纹库。区分说话人之后用它认出登记过的人；nil 时不识别
    public init(store: MeetingStore, transcriber: any Transcriber, engine: String,
                diarizer: (any SpeakerDiarizer)? = nil, voiceprints: VoiceprintStore? = nil,
                host: TranscriptionHost) {
        self.store = store
        self.transcriber = transcriber
        self.engine = engine
        self.diarizer = diarizer
        self.voiceprints = voiceprints
        self.host = host
    }

    /// 有没有区分说话人引擎。没有时 `enqueueDiarization` 总是返回 false，界面据此隐藏“区分说话人”等入口
    public var canDiarize: Bool { diarizer != nil }

    /// 当前区分引擎的声纹模型标识；没有引擎时为 nil。声纹管理窗口据此标出“需要重新登记”的人
    public var voiceprintModel: String? { diarizer?.voiceprintModel }

    /// 没有排队、正在转写、预定了转写的会议，被取消的转写也已退出
    public var isIdle: Bool { activeID == nil && queue.isEmpty && cancelled == nil && reserved.isEmpty }

    /// 某场会议正在进行的步骤；不在转写中时为 nil
    public func activity(for id: String) -> TranscriptionActivity? {
        activeID == id ? activity : nil
    }

    /// 预定转写：会议正在整理，整理好就要排队转写。到 `enqueue`、`unreserve`、`remove` 这场会议之前
    /// 转写不算空闲，纪要不开始：整理完成时录音、整理的暂停先解除，转写稍后才入队，
    /// 这中间排队的纪要不能抢先开始，否则新会议的转写稿要等一整场纪要生成完
    public func reserve(_ id: String) {
        reserved.insert(id)
    }

    /// 取消预定（整理失败等）。没预定过时什么都不做
    public func unreserve(_ id: String) {
        reserved.remove(id)
    }

    /// 排队转写（自动转写、旧会议的“转写”、“重试”、“重新转写”都走这里）。
    /// 只接受已整理好的会议；已在排队转写或正在进行（两种任务都算）时忽略。返回是否入队。预定随之作废。
    /// 已在排队只区分说话人的，改成完整转写（完整转写里也会区分说话人），位置不变；
    /// 排队中的说话人状态不会再有任务来完成，当场按现有转写稿落定（启动恢复时两种状态都在排队也一样）
    @discardableResult
    public func enqueue(_ id: String) -> Bool {
        // 入队后才取消预定，中间不出现“空闲”的瞬间
        defer { reserved.remove(id) }
        guard let m = host?.meeting(id), m.status == .done, m.recording != nil,
              id != activeID, jobs[id] != .transcription else { return false }
        if !queue.contains(id) { queue.append(id) }
        jobs[id] = .transcription
        host?.setTranscription(TranscriptionState(status: .queued), for: id)
        if let status = m.diarization?.status, status == .queued || status == .running {
            settleDiarization(id)
        }
        startNext()
        return true
    }

    /// 排队只区分说话人（旧会议的“区分说话人”、“重新区分说话人”、区分失败后的“重试”）。
    /// 需要已整理好、已有转写稿文件、有区分引擎。正在进行或已在排队转写时忽略；
    /// 已在排队只区分说话人的，换成这次的人数。返回是否入队（或更新了人数）。
    /// 只看文件在不在，读不了的转写稿开始时才发现，记为区分失败。
    /// 开始时记下转写稿的生成时间做区分，结束时重读当前转写稿、按句子只写说话人，期间转写稿被重新转写就丢弃结果
    /// - Parameter speakerCount: 指定人数；nil 由引擎判断
    @discardableResult
    public func enqueueDiarization(_ id: String, speakerCount: Int? = nil) -> Bool {
        guard diarizer != nil, let m = host?.meeting(id), m.status == .done, m.recording != nil,
              id != activeID, jobs[id] != .transcription, store.hasTranscript(id) else { return false }
        if !queue.contains(id) { queue.append(id) }
        jobs[id] = .diarization(speakerCount: speakerCount)
        host?.setDiarization(DiarizationState(status: .queued), for: id)
        startNext()
        return true
    }

    /// 说话人状态按磁盘上的转写稿如实落定：有说话人为完成，否则为 nil（从未区分）。
    /// 用在排队、进行中的说话人状态不会再有任务来完成它的时候，免得一直停在“区分中”
    private func settleDiarization(_ id: String) {
        let diarized = ((try? store.loadTranscriptSummary(id)) ?? nil)?.hasSpeakers == true
        host?.setDiarization(diarized ? DiarizationState(status: .done) : nil, for: id)
    }

    /// App 启动时调用：上次退出时排队中或转写中的会议重新排队，转写中的从头转。
    /// 队列顺序不落盘，上次正在转写的排最前，其余按结束时间近似整理完成的先后。
    /// 从未转写（含 v0.1 旧会议）、已完成、失败的不动
    /// 只区分说话人的任务同理（转写不在排队或进行中、说话人状态是排队或进行中的），人数不落盘，恢复后由引擎判断。
    /// 恢复不了的（没有区分引擎、转写稿不在或读不了）说话人状态按转写稿落定，不留在排队、进行中。
    /// 删除会议失败、会议还在时也用它把被取消的任务放回队列
    public func restore(_ meetings: [Meeting]) {
        func pending(_ s: JobState?) -> Bool { s?.status == .queued || s?.status == .running }
        func job(_ m: Meeting) -> Job? {
            pending(m.transcription) ? .transcription : pending(m.diarization) ? .diarization(speakerCount: nil) : nil
        }
        func rank(_ m: Meeting) -> Int {
            (job(m) == .transcription ? m.transcription : m.diarization)?.status == .running ? 0 : 1
        }
        meetings
            .filter { job($0) != nil }
            .sorted { (rank($0), $0.endedAt ?? $0.startedAt) < (rank($1), $1.endedAt ?? $1.startedAt) }
            .forEach { m in
                if job(m) == .transcription {
                    enqueue(m.id)
                } else if !enqueueDiarization(m.id) {
                    settleDiarization(m.id)
                }
            }
    }

    /// 会议即将被删除：移出队列，正在转写的立即取消。不写任何文件，也不再更新这场会议的状态
    public func remove(_ id: String) {
        reserved.remove(id)
        queue.removeAll { $0 == id }
        jobs[id] = nil
        if activeID == id {
            cancelActive()
            startNext()
        }
    }

    private func startNext() {
        guard !isSuspended, !isHeld, activeID == nil, let id = queue.first else { return }
        guard let m = host?.meeting(id), let audio = store.recordingURL(m) else {
            queue.removeFirst()
            jobs[id] = nil
            return startNext()
        }

        generation += 1
        let token = generation
        let previous = cancelled
        // 先设 activeID 再移出队列，中间不出现“空闲”的瞬间
        activeID = id
        queue.removeFirst()

        // 进度回调来自引擎的线程，回到主线程再更新
        let report: @Sendable (TranscriptionActivity) -> Void = { [weak self] a in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.activity = a
            }
        }
        if case let .diarization(speakerCount) = jobs[id] {
            return startDiarization(id, audio: audio, speakerCount: speakerCount, token: token,
                                    previous: previous, report: report)
        }

        let hotwords = hotwords
        let transcriber = transcriber
        activity = .preparing(0)
        host?.setTranscription(TranscriptionState(status: .running), for: id)
        let diarizer = diarizes ? diarizer : nil
        task = Task(priority: .utility) { [weak self] in
            await previous?.value
            let result: Result<[TranscribedSentence], Error>
            do {
                try Task.checkCancellation()
                try await transcriber.prepare { report(.preparing($0)) }
                report(.transcribing(0))
                result = .success(try await transcriber.transcribe(
                    audio: audio, hotwords: hotwords, progress: { report(.transcribing($0)) }))
            } catch {
                result = .failure(error)
            }
            var diarization: Result<DiarizationResult, Error>?
            if case .success = result, let diarizer {
                diarization = await Self.diarize(diarizer, audio: audio, speakerCount: nil, report: report)
            }
            self?.finish(id, token: token, hotwords: hotwords, result: result, diarization: diarization)
        }
    }

    /// 只区分说话人：读转写稿快照，区分整段录音，结束时在重读的转写稿上只写说话人
    private func startDiarization(_ id: String, audio: URL, speakerCount: Int?, token: Int,
                                  previous: Task<Void, Never>?,
                                  report: @escaping @Sendable (TranscriptionActivity) -> Void) {
        activity = .diarizing(0)
        host?.setDiarization(DiarizationState(status: .running), for: id)
        // 开始时只需记下转写稿的生成时间，结束时据此判断期间有没有被重新转写
        let snapshot: TranscriptSummary?
        do {
            snapshot = try store.loadTranscriptSummary(id)
        } catch {
            return finishDiarization(id, token: token, createdAt: nil, result: .failure(error))
        }
        guard let snapshot, let diarizer else {
            return finishDiarization(id, token: token, createdAt: nil,
                                     result: .failure(DiarizationStepError.noTranscript))
        }
        task = Task(priority: .utility) { [weak self] in
            await previous?.value
            let result = await Self.diarize(diarizer, audio: audio, speakerCount: speakerCount, report: report)
            self?.finishDiarization(id, token: token, createdAt: snapshot.createdAt, result: result)
        }
    }

    private func finishDiarization(_ id: String, token: Int, createdAt: Date?,
                                   result: Result<DiarizationResult, Error>) {
        // 已被取消：结果作废，什么都不写
        guard token == generation, activeID == id else { return }
        activity = nil
        task = nil
        defer {
            activeID = nil
            jobs[id] = nil
            startNext()
        }
        // 区分期间会议被删除
        guard let host, host.meeting(id) != nil, let diarizer else { return }
        do {
            let r = try result.get()
            // 期间转写稿被重新转写（createdAt 变了）：句子已经换了一批，结果作废
            guard let current = try store.loadTranscript(id), current.createdAt == createdAt else {
                throw DiarizationStepError.retranscribed
            }
            let updated = current.withSpeakers(r, engine: diarizer.engine, voiceprintModel: diarizer.voiceprintModel,
                                               createdAt: wholeSecondNow())
                .carryingSpeakerNames(from: current)
            try store.saveTranscript(recognizingSpeakers(updated), for: id)
            host.setDiarization(DiarizationState(status: .done), for: id)
        } catch {
            host.setDiarization(DiarizationState(status: .failed, error: error.localizedDescription), for: id)
        }
    }

    /// 区分说话人之后用声纹库认出登记过的人。声纹库读不出来（文件坏了）时不识别，不让区分失败
    private func recognizingSpeakers(_ transcript: Transcript) -> Transcript {
        guard let voiceprints, let library = try? voiceprints.load() else { return transcript }
        return transcript.recognizingSpeakers(with: library, threshold: voiceprintThreshold)
    }

    /// 放回队首时把状态改回排队中：完整转写改转写状态，只区分说话人改说话人状态
    private func setQueued(_ id: String) {
        if case .diarization = jobs[id] {
            host?.setDiarization(DiarizationState(status: .queued), for: id)
        } else {
            host?.setTranscription(TranscriptionState(status: .queued), for: id)
        }
    }

    private nonisolated static func diarize(_ diarizer: any SpeakerDiarizer, audio: URL, speakerCount: Int?,
                                            report: @escaping @Sendable (TranscriptionActivity) -> Void) async
        -> Result<DiarizationResult, Error> {
        do {
            try Task.checkCancellation()
            report(.diarizing(0))
            try await diarizer.prepare { _ in }
            return .success(try await diarizer.diarize(audio: audio, speakerCount: speakerCount,
                                                       progress: { report(.diarizing($0)) }))
        } catch {
            return .failure(error)
        }
    }

    private func finish(_ id: String, token: Int, hotwords: [String], result: Result<[TranscribedSentence], Error>,
                        diarization: Result<DiarizationResult, Error>?) {
        // 已被取消：结果作废，什么都不写
        guard token == generation, activeID == id else { return }
        activity = nil
        task = nil
        // 写好转写稿、更新状态、回调之后才清 activeID：清掉就算空闲，等着的纪要会马上读转写稿快照
        defer {
            activeID = nil
            jobs[id] = nil
            startNext()
        }
        // 转写期间会议被删除
        guard let host, let m = host.meeting(id) else { return }

        let outcome: TranscriptionOutcome
        do {
            var transcript = Transcript.assemble(try result.get(), meeting: m, engine: engine,
                                                 hotwords: hotwords, createdAt: Date())
            // 没走区分这一步（开关关着、没有引擎）时新稿没有说话人：状态如实退回“从未区分”
            var diarizationState: DiarizationState?
            if let diarization, let diarizer {
                switch diarization {
                case let .success(r):
                    transcript = transcript.withSpeakers(r, engine: diarizer.engine,
                                                         voiceprintModel: diarizer.voiceprintModel,
                                                         createdAt: wholeSecondNow())
                    // 重新转写：沿用旧稿里的名字。旧稿读不了就当没有
                    if let old = (try? store.loadTranscript(id)) ?? nil {
                        transcript = transcript.carryingSpeakerNames(from: old)
                    }
                    transcript = recognizingSpeakers(transcript)
                    diarizationState = DiarizationState(status: .done)
                case let .failure(error):
                    diarizationState = DiarizationState(status: .failed, error: error.localizedDescription)
                }
            }
            try store.saveTranscript(transcript, for: id)
            outcome = .done(transcript)
            host.setTranscription(TranscriptionState(status: .done), for: id)
            host.setDiarization(diarizationState, for: id)
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

    /// 先记下被取消的任务再清 activeID，中间不出现“空闲”的瞬间
    private func cancelActive() {
        if let task {
            task.cancel()
            cancelCount += 1
            let mine = cancelCount
            cancelled = Task { [weak self] in
                await task.value
                self?.cancelledTaskExited(mine)
            }
        }
        task = nil
        generation += 1
        activeID = nil
        activity = nil
    }

    /// 被取消的任务退出了，不再用引擎
    private func cancelledTaskExited(_ mine: Int) {
        // 之后又取消过别的任务，等那个退出（它会先等这个退出）
        guard mine == cancelCount else { return }
        cancelled = nil
        startNext()
    }
}

enum DiarizationStepError: LocalizedError {
    case noTranscript
    case retranscribed

    var errorDescription: String? {
        switch self {
        case .noTranscript: "没有转写稿，无法区分说话人"
        case .retranscribed: "区分期间转写稿被重新转写，结果已作废，请重新区分说话人"
        }
    }
}

/// 当前时间去掉小数秒：转写稿写盘会丢小数秒，取整后回调里的值和磁盘读回的相等
private func wholeSecondNow() -> Date {
    Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
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
