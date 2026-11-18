import Foundation
import Observation

/// 纪要管线对外的唯一依赖：会议元数据由宿主（App 里是 AppModel）统一读写，同 `TranscriptionHost`
@MainActor
public protocol MinutesHost: AnyObject {
    /// 会议的最新状态；已删除时返回 nil
    func meeting(_ id: String) -> Meeting?
    /// 更新会议的纪要状态并保存
    func setMinutes(_ state: MinutesState, for id: String)
    /// 更新会议的转写纠错状态并保存；nil 表示清掉（重新转写出的新稿没有纠错、排队的纠错恢复不了时）
    func setCorrection(_ state: CorrectionState?, for id: String)
}

/// 一次生成的结果。被取消（开始录音、删除会议）的生成没有结果
public enum MinutesOutcome: Hashable, Sendable {
    case done(Minutes)
    case failed(String)
}

/// 正在生成纪要（或纠错）的会议进行到哪一步，只在内存里，不写盘
public enum MinutesActivity: Hashable, Sendable {
    /// 把模型加载进内存，0...1
    case loading(Double)
    /// 0...1，见 `generateMinutes`（纠错时是 `correctTranscript`）的进度
    case generating(Double)
}

/// 排队中的纪要在等什么，供界面显示。都是派生的，不写盘
public enum MinutesWaitReason: Hashable, Sendable {
    /// 等待下载模型
    case model
    /// 等待配置在线模型
    case onlineConfig
    /// 等待接通电源（自动生成的任务用电池时不开始）
    case power
    /// 等待转写完成（转写队列不空时不开始新的纪要）
    case transcription
}

/// 纪要队列：一次生成一场，其余按入队先后排队。
/// 纪要只在成功时整体写入，失败或取消都保留原来的纪要。
///
/// 队列里的任务分种类（`Job.Kind`），共用一条队列、一个引擎，一次只跑一个，同转写管线的
/// “完整转写 / 只区分说话人”：
/// - 生成纪要
/// - 转写纠错（spec「转写纠错」）：用纪要的引擎改正转写稿里听错的字词。同一场会议的纪要排在它的纠错后面，
///   否则纪要刚生成，纠错一写转写稿，纪要就显示“转写稿有修改”。纠错完不释放模型，直接接着生成纪要
///
/// 模型按需加载、用完释放：有任务能开始时才加载，连续排队时保持加载，
/// 一个任务结束后下一个开始不了（队列空、都在等电源或转写等）就释放
@MainActor @Observable
public final class MinutesPipeline {
    /// 排队生成纪要的会议，不含正在生成的
    public var queue: [String] { jobs.filter(\.isMinutes).map(\.id) }
    /// 正在跑任务的会议（任何种类）
    public var activeID: String? { activeJob?.id }
    public private(set) var activity: MinutesActivity?
    /// 引擎是否在用：正在生成，或被取消的任务还没退出（加载模型时可能约 6 秒不理会取消）。
    /// 在用时不能删模型文件；`coordinate(with:)` 也据此让转写等着
    public private(set) var isEngineInUse = false

    /// 暂停时不开始新的生成；暂停的瞬间正在进行的生成被取消并放回队首，恢复后从头再生成。
    /// 录音、整理、启动恢复完成前暂停：录音可靠性优先
    public var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            if isSuspended, let job = activeJob {
                jobs.insert(job, at: 0)
                cancelActive()
                setState(.queued, for: job)
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
    /// 模型文件是否已下载（在线引擎时表示在线配置是否就绪）。`TextGenerator.isDownloaded` 不可观察，在 `modelAvailabilityChanged()` 时刷新
    public private(set) var isModelDownloaded: Bool
    /// 当前引擎是否要求接通电源才自动开始（本机模型为 true，在线模型为 false）
    public private(set) var requiresPower: Bool
    /// 当前是否使用在线纪要引擎（决定未就绪时提示“等待配置在线模型”还是“等待下载模型”）
    public private(set) var isOnlineEngine: Bool
    /// “转写完成后自动生成纪要”开关，见 `transcriptionFinished(_:)`
    public var autoGenerate = true
    /// “纠错转写稿”开关：开着时转写完成先自动纠错，见 `transcriptionFinished(_:)`。手动纠错不看它
    public var correctsTranscripts = false
    /// 当前的热词表，纠错的参考词之一。由 App 在热词变化时设置
    @ObservationIgnored public var hotwords: [String] = []

    /// 当前纪要引擎对应的纠错方式：本机换字词、在线整句改写
    public var correctionMethod: CorrectionMethod { CorrectionMethod.forMinutesEngine(isOnline: isOnlineEngine) }

    /// 转写稿有效文字（见 `Transcript.effectiveTextCount`）少于这么多字时不自动生成
    public static let minimumTextCount = 50

    /// 生成完成或失败时调用（不含取消）
    @ObservationIgnored public var onFinish: ((String, MinutesOutcome) -> Void)?

    private struct Job {
        enum Kind {
            /// 生成纪要
            case minutes(template: MinutesTemplate)
            /// 转写纠错。`autoMinutes`：结束后（成功或失败）按自动纪要的规则决定要不要排纪要。
            /// 转写完成自动排的、启动时恢复的为 true，手动的为 false
            case correction(autoMinutes: Bool)
        }

        var id: String
        var kind: Kind
        /// 用户点的“现在生成”：不等接通电源
        var now: Bool

        var isMinutes: Bool {
            if case .minutes = kind { true } else { false }
        }

        var isCorrection: Bool { !isMinutes }
    }

    private var jobs: [Job] = []
    /// 正在生成的任务
    private var activeJob: Job? {
        didSet { reportEngineUse() }
    }

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private var generator: any TextGenerator
    @ObservationIgnored private var model: String
    @ObservationIgnored private weak var host: MinutesHost?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 被取消、可能还没退出的任务。下一个任务等它退出再用引擎，不并发调用引擎；
    /// 它退出时如果没有别的任务在跑，才释放模型（不在它可能还在用模型时 unload）
    @ObservationIgnored private var cancelled: Task<Void, Never>? {
        didSet { reportEngineUse() }
    }
    @ObservationIgnored private var cancelCount = 0
    /// 每开始或取消一次生成加一。取消后引擎可能不理会、照常返回，靠它丢弃过期的结果和进度
    @ObservationIgnored private var generation = 0
    /// 当前调过 load、还没 unload 的引擎实例。只在真加载过时释放
    @ObservationIgnored private var loadedGenerator: (any TextGenerator)?
    /// 正在生成的任务使用的引擎（运行期热切换后，可能与当前 `generator` 不同）
    @ObservationIgnored private var activeGenerator: (any TextGenerator)?
    /// `isEngineInUse` 变化时调用，见 `coordinate(with:)`
    @ObservationIgnored private var onEngineUseChange: ((Bool) -> Void)?

    /// - Parameter model: 写进纪要的引擎标识，如 "llama/qwen3-4b-q4km"
    public init(store: MeetingStore, generator: any TextGenerator, model: String,
                requiresPower: Bool = true, isOnlineEngine: Bool = false, host: MinutesHost) {
        self.store = store
        self.generator = generator
        self.model = model
        self.requiresPower = requiresPower
        self.isOnlineEngine = isOnlineEngine
        self.host = host
        isModelDownloaded = generator.isDownloaded
    }

    public var isIdle: Bool { activeID == nil && jobs.isEmpty }

    /// 某场会议生成纪要正在进行的步骤；不在生成中时为 nil
    public func activity(for id: String) -> MinutesActivity? {
        activeJob?.id == id && activeJob?.isMinutes == true ? activity : nil
    }

    /// 某场会议纠错正在进行的步骤；不在纠错中时为 nil。会议列表把它显示成纪要前面的一步
    public func correctionActivity(for id: String) -> MinutesActivity? {
        activeJob?.id == id && activeJob?.isCorrection == true ? activity : nil
    }

    /// 某场排队中的会议在等什么；不在排队、或只是排在别的会议后面（含录音中暂停、排在同一场的纠错后面）时为 nil。
    /// 几项同时成立时按需要用户处理的先后：模型/在线配置、电源、转写
    public func waitReason(for id: String) -> MinutesWaitReason? {
        jobs.first { $0.id == id && $0.isMinutes }.flatMap(waitReason)
    }

    /// 某场排队纠错的会议在等什么，规则同 `waitReason(for:)`
    public func correctionWaitReason(for id: String) -> MinutesWaitReason? {
        jobs.first { $0.id == id && $0.isCorrection }.flatMap(waitReason)
    }

    private func waitReason(_ job: Job) -> MinutesWaitReason? {
        if !isModelDownloaded { return isOnlineEngine ? .onlineConfig : .model }
        if requiresPower && !isOnPower && !job.now { return .power }
        if isTranscriptionBusy { return .transcription }
        return nil
    }

    /// 这场会议的纪要接下来会怎样，用来决定转写通知（`MeetingNotice.transcription`）。
    /// 在转写的 `onFinish` 里、`transcriptionFinished(_:)` 之后调用：此刻转写管线还没空闲，
    /// 能马上开始的任务也还在排队，等的是 `.transcription`。
    /// 看的是是否在队列里，不只是这次有没有自动排队：用户之前手动排过的也会生成并通知
    /// 自动排的纠错还没结束、结束后会自动排纪要（`wouldAutoGenerate`）时，也算已排队，等的是纠错在等的
    public func followUp(for id: String) -> MinutesFollowUp {
        if activeJob?.id == id && activeJob?.isMinutes == true { return .queued(waitingFor: nil) }
        if jobs.contains(where: { $0.id == id && $0.isMinutes }) { return .queued(waitingFor: waitReason(for: id)) }
        if let correction = pendingCorrection(id), case .correction(autoMinutes: true) = correction.kind,
           wouldAutoGenerate(id) {
            return .queued(waitingFor: activeJob?.id == id ? nil : correctionWaitReason(for: id))
        }
        return .notQueued
    }

    /// 这场会议排着或正在跑的纠错
    private func pendingCorrection(_ id: String) -> Job? {
        if let active = activeJob, active.id == id, active.isCorrection { return active }
        return jobs.first { $0.id == id && $0.isCorrection }
    }

    /// 和转写管线互相让行，两者一次只跑一个：转写不空闲时不开始新的纪要；
    /// 纪要生成中（含被取消、还没退出）时转写不开始，等这场生成完。都不取消对方正在进行的任务（录音的暂停另算）
    public func coordinate(with transcription: TranscriptionPipeline) {
        transcription.onIdleChange = { [weak self] idle in self?.isTranscriptionBusy = !idle }
        onEngineUseChange = { [weak transcription] inUse in transcription?.isHeld = inUse }
        transcription.isHeld = isEngineInUse
        isTranscriptionBusy = !transcription.isIdle
    }

    /// 模型下载完成或被删除时调用：刷新 `isModelDownloaded`，下载好了就开始排队的任务
    public func modelAvailabilityChanged() {
        isModelDownloaded = generator.isDownloaded
        startNext()
    }

    /// 运行期热切换纪要引擎：进行中的任务继续用启动时的旧引擎与旧标识跑完落盘；
    /// 从本机引擎切走且旧引擎未被占用时立即调用 `unload()` 释放内存，若正在占用则等任务退出后再释放
    public func setEngine(generator: any TextGenerator, model: String,
                          requiresPower: Bool, isOnlineEngine: Bool) {
        let oldGenerator = self.generator
        let oldIsOnline = self.isOnlineEngine
        self.generator = generator
        self.model = model
        self.requiresPower = requiresPower
        self.isOnlineEngine = isOnlineEngine
        isModelDownloaded = generator.isDownloaded

        if !oldIsOnline, !isSameGenerator(oldGenerator, generator),
           activeID == nil, cancelled == nil,
           let loaded = loadedGenerator, isSameGenerator(loaded, oldGenerator) {
            releaseModel()
        }
        startNext()
    }

    /// 排队生成（自动生成、“生成纪要”、“重试”、“重新生成”、“现在生成”都走这里）。
    /// 只接受转写过的会议；正在生成时忽略。已在排队时不重复排，给了模板就换成新的模板，`now` 只升不降。
    /// - Parameters:
    ///   - template: nil 时沿用排队时选的模板；不在排队时沿用已有纪要的模板，没有纪要用“通用”。
    ///     如“按周会重新生成”后排队等转写，转写完成自动排队（不带模板）时仍按周会生成
    ///   - now: “现在生成”，不等接通电源
    /// 同一场会议的纠错还在排队时，纪要排在它后面；`now` 时那个纠错也跟着不等接通电源，免得纪要一直等它
    /// - Returns: 是否在队列中
    @discardableResult
    public func enqueue(_ id: String, template: MinutesTemplate? = nil, now: Bool = false) -> Bool {
        guard let m = host?.meeting(id), m.transcription != nil,
              !(activeJob?.id == id && activeJob?.isMinutes == true) else { return false }
        if now, let i = jobs.firstIndex(where: { $0.id == id && $0.isCorrection }) { jobs[i].now = true }
        if let i = jobs.firstIndex(where: { $0.id == id && $0.isMinutes }) {
            if let template { jobs[i].kind = .minutes(template: template) }
            jobs[i].now = jobs[i].now || now
        } else {
            let job = Job(id: id, kind: .minutes(template: template ?? existingTemplate(id)), now: now)
            jobs.append(job)
            setState(.queued, for: job)
        }
        startNext()
        return true
    }

    /// 排队纠错（转写完成自动纠错、“纠错”、“重试”都走这里）。只接受转写过、有转写稿的会议；
    /// 这场正在纠错时不排。已在排队时不重复排，
    /// `now`、`autoMinutes` 只升不降。同一场会议的纪要不越过它（见 `nextJob`）
    /// - Parameters:
    ///   - now: 手动纠错，不等接通电源
    ///   - autoMinutes: 结束后按自动纪要的规则决定要不要排纪要（转写完成的自动路径）
    /// - Returns: 是否在队列中
    @discardableResult
    public func enqueueCorrection(_ id: String, now: Bool = false, autoMinutes: Bool = false) -> Bool {
        guard let m = host?.meeting(id), m.transcription != nil,
              (try? store.loadTranscript(id)) != nil,
              !(activeJob?.id == id && activeJob?.isCorrection == true) else { return false }
        if let i = jobs.firstIndex(where: { $0.id == id && $0.isCorrection }) {
            jobs[i].now = jobs[i].now || now
            if autoMinutes, case .correction(autoMinutes: false) = jobs[i].kind {
                jobs[i].kind = .correction(autoMinutes: true)
                setState(.queued, for: jobs[i])
            }
        } else {
            let job = Job(id: id, kind: .correction(autoMinutes: autoMinutes), now: now)
            jobs.append(job)
            setState(.queued, for: job)
        }
        startNext()
        return true
    }

    /// 转写成功后调用：
    /// 1. “纠错转写稿”开着就先排纠错（不看自动纪要开关、文字多少、纪要改没改过），纠错结束（成功或失败）后再走第 2 步
    /// 2. 按自动纪要的规则（`wouldAutoGenerate`）决定要不要排纪要
    ///
    /// 新稿没有纠错（spec「重新转写：新稿没有纠错」）：没排上纠错时清掉上次的纠错状态，
    /// 免得「纠错失败 · 重试」留在新稿上面。这场已经排着的纠错（手动排的，在等转写完）不动，照常在新稿上跑
    ///
    /// 返回纪要是否排了队，或者纠错结束后会按规则排队
    @discardableResult
    public func transcriptionFinished(_ id: String) -> Bool {
        if correctsTranscripts, enqueueCorrection(id, autoMinutes: true) {
            return wouldAutoGenerate(id)
        }
        if pendingCorrection(id) == nil, host?.meeting(id)?.correction != nil {
            host?.setCorrection(nil, for: id)
        }
        return autoGenerateMinutes(id)
    }

    /// 自动纪要的规则：
    /// - 自动生成开着，转写稿有效文字不少于 `minimumTextCount`
    /// - 还没有纪要（含从未生成、上次失败），或者有纪要但修改数为 0（重新转写后出处已不准，重新生成，
    ///   沿用原来的模板）。有人工改动的不动，由界面提示“转写稿已重新生成”
    /// - 纪要文件读不了时不动，免得覆盖
    private func wouldAutoGenerate(_ id: String) -> Bool {
        guard autoGenerate, let transcript = try? store.loadTranscript(id),
              transcript.effectiveTextCount >= Self.minimumTextCount else { return false }
        guard case let .success(existing) = Result(catching: { try store.loadMinutes(id) }),
              (existing?.editCount ?? 0) == 0 else { return false }
        return true
    }

    /// 按自动纪要的规则排纪要，返回是否排了队
    @discardableResult
    private func autoGenerateMinutes(_ id: String) -> Bool {
        wouldAutoGenerate(id) && enqueue(id)
    }

    /// App 启动时调用：上次退出时排队中或生成中的会议重新排队，生成中的从头生成。
    /// 队列顺序、“现在生成”、所选模板都不落盘：上次正在生成的排最前，其余按结束时间；
    /// 模板沿用已有纪要的，没有就用“通用”。
    ///
    /// 纠错同理，先于纪要排。是不是自动路径记在纠错状态里（`CorrectionState.automatic`）：自动的结束后按自动纪要的
    /// 规则决定要不要排纪要（自动路径中途退出时纪要还没排，不这样就再也不会自动生成）；手动的仍是手动，不等接通电源。
    /// 没记的（旧文件）按自动的恢复。恢复不了的（转写稿没了）清掉纠错状态，自动的直接按规则排纪要
    /// 删除会议失败、会议还在时也用它把被取消的任务放回队列
    public func restore(_ meetings: [Meeting]) {
        func order(_ status: (Meeting) -> JobState.Status?) -> [Meeting] {
            func rank(_ m: Meeting) -> Int { status(m) == .running ? 0 : 1 }
            return meetings.filter { status($0) == .queued || status($0) == .running }
                .sorted { (rank($0), $0.endedAt ?? $0.startedAt) < (rank($1), $1.endedAt ?? $1.startedAt) }
        }
        for m in order(\.correction?.status) {
            let automatic = m.correction?.automatic ?? true
            if !enqueueCorrection(m.id, now: !automatic, autoMinutes: automatic) {
                host?.setCorrection(nil, for: m.id)
                if automatic { autoGenerateMinutes(m.id) }
            }
        }
        order(\.minutes?.status).forEach { enqueue($0.id) }
    }

    /// 会议即将被删除：移出队列，正在生成的立即取消。不写任何文件，也不再更新这场会议的状态
    public func remove(_ id: String) {
        jobs.removeAll { $0.id == id }
        if activeID == id {
            cancelActive()
            startNext()
        }
    }

    /// 任务的状态写进对应的字段
    private func setState(_ status: JobState.Status, error: String? = nil, for job: Job) {
        switch job.kind {
        case .minutes: host?.setMinutes(MinutesState(status: status, error: error), for: job.id)
        case let .correction(autoMinutes):
            // 是不是自动的只在排队、进行中有用（恢复队列），完成、失败不记
            let automatic = status == .queued || status == .running ? autoMinutes : nil
            host?.setCorrection(CorrectionState(status: status, error: error, automatic: automatic), for: job.id)
        }
    }

    private func existingTemplate(_ id: String) -> MinutesTemplate {
        (try? store.loadMinutes(id))?.flatMap { MinutesTemplate(key: $0.template) } ?? .general
    }

    /// 下一个能开始的任务在 jobs 里的位置。纪要不越过同一场会议还在排队的纠错
    private var nextJob: Int? {
        guard !isSuspended, !isTranscriptionBusy, isModelDownloaded else { return nil }
        return jobs.firstIndex { job in
            (!requiresPower || isOnPower || job.now)
                && !(job.isMinutes && jobs.contains { $0.id == job.id && $0.isCorrection })
        }
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
        switch job.kind {
        case let .minutes(template): startMinutes(job, template: template, meeting: m)
        case let .correction(autoMinutes):
            startCorrection(job, method: correctionMethod, autoMinutes: autoMinutes, meeting: m)
        }
    }

    /// 引擎交给新任务：作废之前的结果，换引擎时先释放旧的。返回这次的 token
    private func begin(_ job: Job) -> Int {
        generation += 1
        if cancelled == nil {
            if let loaded = loadedGenerator, !isSameGenerator(loaded, generator) {
                releaseModel()
            }
            loadedGenerator = generator
        }
        activeJob = job
        activeGenerator = generator
        activity = .loading(0)
        setState(.running, for: job)
        return generation
    }

    private func startMinutes(_ job: Job, template: MinutesTemplate, meeting m: Meeting) {
        let previous = cancelled
        let token = begin(job)
        let generator = generator
        let model = model
        // 以开始时的转写稿为准。从磁盘读：与之后读回比较的值一致，不受小数秒影响。
        // 会中标注以开始时宿主里的会议为准（`m`），和转写稿快照一起算出区间
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
                try Task.checkCancellation()
                self?.markLoaded(generator, token: token)
                guard let transcript = try snapshot.get() else { throw MinutesPipelineError.noTranscript }
                try await generator.load { report(.loading($0)) }
                report(.generating(0))
                // createdAt 取整秒：写盘会丢掉小数秒，免得回调里的纪要和读回的不相等
                let createdAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
                result = .success(try await generateMinutes(
                    transcript: transcript, title: m.title, startedAt: m.startedAt, template: template,
                    annotations: m.minutesAnnotations(in: transcript), generator: generator, model: model, createdAt: createdAt,
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
        task = nil

        var outcome: MinutesOutcome?
        // 生成期间会议被删除时什么都不写
        if let host, host.meeting(id) != nil {
            do {
                var minutes = try result.get()
                // 按写盘前磁盘上的旧纪要继承：生成期间才点的“忽略”也算。旧纪要读不出来就不继承
                minutes.inheritIgnoredNameSuggestions(from: (try? store.loadMinutes(id)) ?? nil)
                try store.saveMinutes(minutes, for: id)
                host.setMinutes(MinutesState(status: .done), for: id)
                outcome = .done(minutes)
            } catch {
                host.setMinutes(MinutesState(status: .failed, error: error.localizedDescription), for: id)
                outcome = .failed(error.localizedDescription)
            }
        }
        let switchedEngine = activeGenerator.map { !isSameGenerator($0, generator) } ?? false
        // 下一场开始不了（或已切换引擎）就先释放旧模型，再让给转写（清掉 activeJob 会放开转写）
        if nextJob == nil || switchedEngine { releaseModel() }
        activity = nil
        activeGenerator = nil
        activeJob = nil
        startNext()
        if let outcome { onFinish?(id, outcome) }
    }

    private func startCorrection(_ job: Job, method: CorrectionMethod, autoMinutes: Bool, meeting m: Meeting) {
        let previous = cancelled
        let token = begin(job)
        let generator = generator
        let model = model
        let hotwords = hotwords
        // 以开始时的转写稿为准，写盘前再与最新的比对（`Transcript.applyCorrection`）
        let snapshot = Result { try store.loadTranscript(job.id) }
        let report: @Sendable (MinutesActivity) -> Void = { [weak self] a in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.activity = a
            }
        }
        task = Task(priority: .utility) { [weak self] in
            await previous?.value
            let result: Result<CorrectionResult, Error>
            do {
                try Task.checkCancellation()
                self?.markLoaded(generator, token: token)
                guard let transcript = try snapshot.get() else { throw CorrectionError.noTranscript }
                try await generator.load { report(.loading($0)) }
                report(.generating(0))
                let review = try await correctTranscript(transcript, title: m.title, hotwords: hotwords, method: method,
                                                         generator: generator, progress: { report(.generating($0)) })
                let createdAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
                result = .success(CorrectionResult(snapshot: transcript, review: review, engine: model,
                                                   createdAt: createdAt, hotwords: hotwords))
            } catch {
                result = .failure(error)
            }
            self?.finishCorrection(job, token: token, autoMinutes: autoMinutes, result: result)
        }
    }

    /// 纠错结束：写盘前重读最新的转写稿再应用；失败只记失败状态。之后按需走自动纪要的规则，
    /// 在决定释不释放模型之前排上纪要：纠错和纪要之间模型只加载一次
    private func finishCorrection(_ job: Job, token: Int, autoMinutes: Bool, result: Result<CorrectionResult, Error>) {
        guard token == generation, activeJob?.id == job.id, activeJob?.isCorrection == true else { return }
        task = nil
        let id = job.id
        // 纠错期间会议被删除时什么都不写
        if let host, host.meeting(id) != nil {
            do {
                let correction = try result.get()
                guard var latest = try store.loadTranscript(id) else { throw CorrectionError.noTranscript }
                try latest.applyCorrection(correction)
                try store.saveTranscript(latest, for: id)
                setState(.done, for: job)
            } catch {
                setState(.failed, error: error.localizedDescription, for: job)
            }
            // 此刻 activeJob 还是这个纠错：纪要照常入队，startNext 等下面清掉 activeJob 后才开始
            if autoMinutes { autoGenerateMinutes(id) }
        }
        let switchedEngine = activeGenerator.map { !isSameGenerator($0, generator) } ?? false
        // 下一个开始不了（或已切换引擎）就先释放旧模型，再让给转写
        if nextJob == nil || switchedEngine { releaseModel() }
        activity = nil
        activeGenerator = nil
        activeJob = nil
        startNext()
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
        activeGenerator = nil
        activeJob = nil
        activity = nil
    }

    /// 被取消的任务退出了，不再用模型：没有别的任务在跑（或当前引擎已换）、也开始不了时释放模型
    private func cancelledTaskExited(_ mine: Int) {
        // 之后又取消过别的任务，等那个退出（它会先等这个退出）
        guard mine == cancelCount else { return }
        let canKeepLoaded = if let loaded = loadedGenerator {
            if let active = activeGenerator {
                isSameGenerator(loaded, active)
            } else {
                nextJob != nil && isSameGenerator(loaded, generator)
            }
        } else {
            false
        }
        // 先释放模型，再放开转写
        if !canKeepLoaded { releaseModel() }
        cancelled = nil
        startNext()
    }

    private func reportEngineUse() {
        let inUse = activeID != nil || cancelled != nil
        guard inUse != isEngineInUse else { return }
        isEngineInUse = inUse
        onEngineUseChange?(inUse)
    }

    private func markLoaded(_ generator: any TextGenerator, token: Int) {
        guard token == generation else { return }
        loadedGenerator = generator
    }

    private func releaseModel() {
        guard let loaded = loadedGenerator else { return }
        loadedGenerator = nil
        loaded.unload()
    }

    private func isSameGenerator(_ a: any TextGenerator, _ b: any TextGenerator) -> Bool {
        type(of: a) is AnyObject.Type && type(of: b) is AnyObject.Type
            && (a as AnyObject) === (b as AnyObject)
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
