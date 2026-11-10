import Foundation
import Observation

/// 纪要管线对外的唯一依赖：会议元数据由宿主（App 里是 AppModel）统一读写，同 `TranscriptionHost`
@MainActor
public protocol MinutesHost: AnyObject {
    /// 会议的最新状态；已删除时返回 nil
    func meeting(_ id: String) -> Meeting?
    /// 更新会议的纪要状态并保存
    func setMinutes(_ state: MinutesState, for id: String)
}

/// 一次生成的结果。被取消（开始录音、删除会议）的生成没有结果
public enum MinutesOutcome: Hashable, Sendable {
    case done(Minutes)
    case failed(String)
}

/// 正在生成的会议进行到哪一步，只在内存里，不写盘
public enum MinutesActivity: Hashable, Sendable {
    /// 把模型加载进内存，0...1
    case loading(Double)
    /// 0...1，见 `generateMinutes` 的进度
    case generating(Double)
}

/// 排队中的纪要在等什么，供界面显示。都是派生的，不写盘
public enum MinutesWaitReason: Hashable, Sendable {
    /// 等待下载模型
    case model
    /// 等待接通电源（自动生成的任务用电池时不开始）
    case power
    /// 等待转写完成（转写队列不空时不开始新的纪要）
    case transcription
}

/// 纪要队列：一次生成一场，其余按入队先后排队。
/// 纪要只在成功时整体写入，失败或取消都保留原来的纪要。
///
/// 模型按需加载、用完释放：有任务能开始时才加载，连续排队时保持加载，
/// 一个任务结束后下一个开始不了（队列空、都在等电源或转写等）就释放
@MainActor @Observable
public final class MinutesPipeline {
    /// 排队中的会议，不含正在生成的
    public var queue: [String] { jobs.map(\.id) }
    /// 正在生成的会议
    public private(set) var activeID: String? {
        didSet { reportEngineUse() }
    }
    public private(set) var activity: MinutesActivity?

    /// 暂停时不开始新的生成；暂停的瞬间正在进行的生成被取消并放回队首，恢复后从头再生成。
    /// 录音、整理、启动恢复完成前暂停：录音可靠性优先
    public var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            if isSuspended, let job = activeJob {
                jobs.insert(job, at: 0)
                cancelActive()
                host?.setMinutes(MinutesState(status: .queued), for: job.id)
            } else if !isSuspended {
                startNext()
            }
        }
    }
    /// 是否接通电源。用电池时自动生成的任务不开始；拔掉电源不取消正在进行的
    public var isOnPower = true {
        didSet { if isOnPower && !oldValue { startNext() } }
    }
    /// 转写不空闲（排队或正在转写）时不开始新的纪要，不取消正在进行的。由 `coordinate(with:)` 维护
    public private(set) var isTranscriptionBusy = false {
        didSet { if !isTranscriptionBusy && oldValue { startNext() } }
    }
    /// 模型文件是否已下载。`TextGenerator.isDownloaded` 不可观察，在 `modelAvailabilityChanged()` 时刷新
    public private(set) var isModelDownloaded: Bool
    /// “转写完成后自动生成纪要”开关，见 `transcriptionFinished(_:)`
    public var autoGenerate = true

    /// 转写稿有效文字（见 `Transcript.effectiveTextCount`）少于这么多字时不自动生成
    public static let minimumTextCount = 50

    /// 生成完成或失败时调用（不含取消）
    @ObservationIgnored public var onFinish: ((String, MinutesOutcome) -> Void)?

    private struct Job {
        var id: String
        var template: MinutesTemplate
        /// 用户点的“现在生成”：不等接通电源
        var now: Bool
    }

    private var jobs: [Job] = []

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private let generator: any TextGenerator
    @ObservationIgnored private let model: String
    @ObservationIgnored private weak var host: MinutesHost?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activeJob: Job?
    /// 被取消、可能还没退出的任务。下一个任务等它退出再用引擎，不并发调用引擎；
    /// 它退出时如果没有别的任务在跑，才释放模型（不在它可能还在用模型时 unload）
    @ObservationIgnored private var cancelled: Task<Void, Never>? {
        didSet { reportEngineUse() }
    }
    @ObservationIgnored private var cancelCount = 0
    /// 每开始或取消一次生成加一。取消后引擎可能不理会、照常返回，靠它丢弃过期的结果和进度
    @ObservationIgnored private var generation = 0
    /// 调过 load、还没 unload。只在真加载过时释放
    @ObservationIgnored private var isLoaded = false
    /// 引擎是否在用（正在生成，或被取消的任务还没退出），变化时调用。`coordinate(with:)` 用它让转写等着
    @ObservationIgnored private var onEngineUseChange: ((Bool) -> Void)?
    @ObservationIgnored private var reportedEngineUse = false

    /// - Parameter model: 写进纪要的引擎标识，如 "llama/qwen3-4b-q4km"
    public init(store: MeetingStore, generator: any TextGenerator, model: String, host: MinutesHost) {
        self.store = store
        self.generator = generator
        self.model = model
        self.host = host
        isModelDownloaded = generator.isDownloaded
    }

    public var isIdle: Bool { activeID == nil && jobs.isEmpty }

    /// 某场会议正在进行的步骤；不在生成中时为 nil
    public func activity(for id: String) -> MinutesActivity? {
        activeID == id ? activity : nil
    }

    /// 某场排队中的会议在等什么；不在排队、或只是排在别的会议后面（含录音中暂停）时为 nil。
    /// 几项同时成立时按需要用户处理的先后：模型、电源、转写
    public func waitReason(for id: String) -> MinutesWaitReason? {
        guard let job = jobs.first(where: { $0.id == id }) else { return nil }
        if !isModelDownloaded { return .model }
        if !isOnPower && !job.now { return .power }
        if isTranscriptionBusy { return .transcription }
        return nil
    }

    /// 和转写管线互相让行，两者一次只跑一个：转写不空闲时不开始新的纪要；
    /// 纪要生成中（含被取消、还没退出）时转写不开始，等这场生成完。都不取消对方正在进行的任务（录音的暂停另算）
    public func coordinate(with transcription: TranscriptionPipeline) {
        transcription.onIdleChange = { [weak self] idle in self?.isTranscriptionBusy = !idle }
        onEngineUseChange = { [weak transcription] inUse in transcription?.isHeld = inUse }
        transcription.isHeld = reportedEngineUse
        isTranscriptionBusy = !transcription.isIdle
    }

    /// 模型下载完成或被删除时调用：刷新 `isModelDownloaded`，下载好了就开始排队的任务
    public func modelAvailabilityChanged() {
        isModelDownloaded = generator.isDownloaded
        startNext()
    }

    /// 排队生成（自动生成、“生成纪要”、“重试”、“重新生成”、“现在生成”都走这里）。
    /// 只接受转写过的会议；正在生成时忽略。已在排队时不重复排，但会换成新的模板，`now` 只升不降。
    /// - Parameters:
    ///   - template: nil 时沿用已有纪要的模板，没有纪要用“通用”
    ///   - now: “现在生成”，不等接通电源
    /// - Returns: 是否在队列中
    @discardableResult
    public func enqueue(_ id: String, template: MinutesTemplate? = nil, now: Bool = false) -> Bool {
        guard let m = host?.meeting(id), m.transcription != nil, id != activeID else { return false }
        let template = template ?? existingTemplate(id)
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].template = template
            jobs[i].now = jobs[i].now || now
        } else {
            jobs.append(Job(id: id, template: template, now: now))
            host?.setMinutes(MinutesState(status: .queued), for: id)
        }
        startNext()
        return true
    }

    /// 转写成功后调用，按规则决定要不要自动排队，返回是否排了队：
    /// - 自动生成开着，转写稿有效文字不少于 `minimumTextCount`
    /// - 还没有纪要（含从未生成、上次失败），或者有纪要但没有人工改动（重新转写后出处已不准，重新生成，
    ///   沿用原来的模板）。有人工改动的不动，由界面提示“转写稿已重新生成”
    /// - 纪要文件读不了时不动，免得覆盖
    @discardableResult
    public func transcriptionFinished(_ id: String) -> Bool {
        guard autoGenerate, let transcript = try? store.loadTranscript(id),
              transcript.effectiveTextCount >= Self.minimumTextCount else { return false }
        guard case let .success(existing) = Result(catching: { try store.loadMinutes(id) }),
              !(existing?.hasManualEdits ?? false) else { return false }
        return enqueue(id)
    }

    /// App 启动时调用：上次退出时排队中或生成中的会议重新排队，生成中的从头生成。
    /// 队列顺序、“现在生成”、所选模板都不落盘：上次正在生成的排最前，其余按结束时间；
    /// 模板沿用已有纪要的，没有就用“通用”
    public func restore(_ meetings: [Meeting]) {
        func rank(_ m: Meeting) -> Int { m.minutes?.status == .running ? 0 : 1 }
        meetings
            .filter { $0.minutes?.status == .queued || $0.minutes?.status == .running }
            .sorted { (rank($0), $0.endedAt ?? $0.startedAt) < (rank($1), $1.endedAt ?? $1.startedAt) }
            .forEach { enqueue($0.id) }
    }

    /// 会议即将被删除：移出队列，正在生成的立即取消。不写任何文件，也不再更新这场会议的状态
    public func remove(_ id: String) {
        jobs.removeAll { $0.id == id }
        if activeID == id {
            cancelActive()
            startNext()
        }
    }

    private func existingTemplate(_ id: String) -> MinutesTemplate {
        (try? store.loadMinutes(id))?.flatMap { MinutesTemplate(key: $0.template) } ?? .general
    }

    /// 下一个能开始的任务在 jobs 里的位置
    private var nextJob: Int? {
        guard !isSuspended, !isTranscriptionBusy, isModelDownloaded else { return nil }
        return jobs.firstIndex { isOnPower || $0.now }
    }

    /// 开始下一个能开始的任务。一个都开始不了、也没有被取消的任务还在用模型时，释放模型
    private func startNext() {
        guard activeID == nil else { return }
        guard let i = nextJob else {
            if cancelled == nil { releaseModel() }
            return
        }
        let job = jobs.remove(at: i)
        guard let m = host?.meeting(job.id) else { return startNext() }

        generation += 1
        let token = generation
        let generator = generator
        let model = model
        let previous = cancelled
        activeID = job.id
        activeJob = job
        activity = .loading(0)
        isLoaded = true
        host?.setMinutes(MinutesState(status: .running), for: job.id)
        // 以开始时的转写稿为准。从磁盘读：与之后读回比较的值一致，不受小数秒影响
        let snapshot = Result { try store.loadTranscript(job.id) }

        // 进度回调来自后台线程，回到主线程再更新
        let report: @Sendable (MinutesActivity) -> Void = { [weak self] a in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.activity = a
            }
        }
        task = Task(priority: .utility) { [weak self] in
            await previous?.value
            let result: Result<Minutes, Error>
            do {
                guard let transcript = try snapshot.get() else { throw MinutesPipelineError.noTranscript }
                try Task.checkCancellation()
                try await generator.load { report(.loading($0)) }
                report(.generating(0))
                // createdAt 取整秒：写盘会丢掉小数秒，免得回调里的纪要和读回的不相等
                let createdAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
                result = .success(try await generateMinutes(
                    transcript: transcript, title: m.title, startedAt: m.startedAt, template: job.template,
                    generator: generator, model: model, createdAt: createdAt,
                    progress: { report(.generating($0)) }))
            } catch {
                result = .failure(error)
            }
            self?.finish(job.id, token: token, result: result)
        }
    }

    private func finish(_ id: String, token: Int, result: Result<Minutes, Error>) {
        // 已被取消：结果作废，什么都不写
        guard token == generation, activeID == id else { return }
        activeJob = nil
        task = nil

        var outcome: MinutesOutcome?
        // 生成期间会议被删除时什么都不写
        if let host, host.meeting(id) != nil {
            do {
                let minutes = try result.get()
                try store.saveMinutes(minutes, for: id)
                host.setMinutes(MinutesState(status: .done), for: id)
                outcome = .done(minutes)
            } catch {
                host.setMinutes(MinutesState(status: .failed, error: error.localizedDescription), for: id)
                outcome = .failed(error.localizedDescription)
            }
        }
        // 下一场开始不了就先释放模型，再让给转写（清掉 activeID 会放开转写）
        if nextJob == nil { releaseModel() }
        activity = nil
        activeID = nil
        startNext()
        if let outcome { onFinish?(id, outcome) }
    }

    private func cancelActive() {
        guard let task else { return }
        task.cancel()
        cancelCount += 1
        let mine = cancelCount
        cancelled = Task { [weak self] in
            await task.value
            self?.cancelledTaskExited(mine)
        }
        self.task = nil
        generation += 1
        activeID = nil
        activeJob = nil
        activity = nil
    }

    /// 被取消的任务退出了，不再用模型：没有别的任务在跑、也开始不了时释放模型
    private func cancelledTaskExited(_ mine: Int) {
        // 之后又取消过别的任务，等那个退出（它会先等这个退出）
        guard mine == cancelCount else { return }
        // 先释放模型，再放开转写
        if activeID == nil && nextJob == nil { releaseModel() }
        cancelled = nil
        startNext()
    }

    private func reportEngineUse() {
        let inUse = activeID != nil || cancelled != nil
        guard inUse != reportedEngineUse else { return }
        reportedEngineUse = inUse
        onEngineUseChange?(inUse)
    }

    private func releaseModel() {
        guard isLoaded else { return }
        isLoaded = false
        generator.unload()
    }
}

public enum MinutesPipelineError: LocalizedError, Equatable {
    case noTranscript

    public var errorDescription: String? {
        switch self {
        case .noTranscript: "没有转写稿，无法生成纪要"
        }
    }
}

extension Transcript {
    /// 有效文字数：所有句子里除空白、标点、符号之外的字符数（按 Unicode 标量计），
    /// 判断“内容太少，未生成纪要”用
    public var effectiveTextCount: Int {
        sentences.reduce(0) { n, s in
            n + s.text.unicodeScalars.count {
                !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
                    && !CharacterSet.symbols.contains($0)
            }
        }
    }
}

extension Minutes {
    /// 有人工改动（修改、删除、新增）。07 会提供正式的修改数，这里先用同样的规则
    var hasManualEdits: Bool {
        sections.contains { $0.items.contains { $0.original != nil || $0.deleted || $0.origin == .manual } }
    }
}
