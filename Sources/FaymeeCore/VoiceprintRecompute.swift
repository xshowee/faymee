import Foundation

/// 用某个声纹模型给录音里指定的句子算声纹。重算声纹库用；`SherpaOnnxDiarizer` 实现它
public protocol VoiceprintExtractor {
    /// 算出的声纹属于哪个模型（目录项 id）
    var voiceprintModel: String { get }
    /// 一段录音里若干组句子各自的声纹：每组是同一个人的句子（相对录音文件开头的秒数），
    /// 声纹是组内各句声纹按时长加权平均，与区分说话人时每人的声纹算法相同。
    /// 组里没有一句能算出声纹（都太短）时为 nil。整段录音只解码一次。需要支持取消
    func voiceprints(audio: URL, groups: [[ClosedRange<TimeInterval>]]) async throws -> [Voiceprint?]
}

extension Transcript {
    /// 什么都对不上、只靠声纹找人时的相似度下限。同一场会议里没动过的说话人与登记时的声纹完全相同，
    /// 合并、重新区分（同一模型）后也几乎一样；跨会议认人的阈值（ERes2Net 0.7）在这里太松
    public static let voiceprintSourceSimilarity: Float = 0.9

    /// 声纹库样本在这场（来源会议）里对应的说话人，重算声纹库时取他的句子。按可靠程度依次找：
    /// 1. 样本记了来源说话人，且这场的区分时间与登记时相同（之后没重新区分过）：就是那个编号，改过名也一样
    /// 2. 声纹与样本完全相同的说话人（登记后没合并过；这场与样本是同一个声纹模型时）
    /// 3. 声纹库认出是此人的说话人（`personID`）
    /// 4. 名字（去首尾空白）与此人相同的说话人
    /// 3、4 找到不止一个时，用这场的声纹挑与样本最像的（这场与样本是同一个声纹模型才可比，否则算找不到）；
    /// 都找不到时，同一模型下声纹与样本几乎一样（≥ `voiceprintSourceSimilarity`）的说话人也算
    public func voiceprintSourceSpeaker(of sample: VoiceprintSample, person: VoiceprintPerson) -> Speaker? {
        guard let diarization else { return nil }
        let speakers = diarization.speakers
        if let source = sample.source, source.speakersCreatedAt == diarization.speakersCreatedAt,
           let s = speakers.first(where: { $0.id == source.speakerID }) {
            return s
        }
        // 声纹只在同一模型之间可比（相等也一样）
        let comparable = diarization.voiceprintModel == person.voiceprintModel
        if comparable,
           let s = speakers.first(where: { !$0.voiceprint.vector.isEmpty && $0.voiceprint == sample.voiceprint }) {
            return s
        }
        func mostSimilar(_ candidates: [Speaker]) -> (speaker: Speaker, similarity: Float)? {
            guard comparable else { return nil }
            return candidates.map { ($0, $0.voiceprint.similarity(to: sample.voiceprint)) }.max { $0.1 < $1.1 }
        }
        for candidates in [
            speakers.filter { $0.personID == person.id },
            speakers.filter { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) == person.name },
        ] where !candidates.isEmpty {
            return candidates.count == 1 ? candidates[0] : mostSimilar(candidates)?.speaker
        }
        guard let best = mostSimilar(speakers), best.similarity >= Self.voiceprintSourceSimilarity else { return nil }
        return best.speaker
    }
}

/// 一次重算声纹库的结果
public struct VoiceprintRecomputeReport: Hashable, Sendable {
    /// 换到新模型的人数
    public var recomputed: Int
    /// 有样本无法重算的人，按声纹库顺序。取消时没轮到的人不算
    public var affected: [Affected]
    /// 中途取消了：已重算的人保留，没算完的人不动
    public var isCancelled: Bool

    public init(recomputed: Int, affected: [Affected], isCancelled: Bool) {
        self.recomputed = recomputed
        self.affected = affected
        self.isCancelled = isCancelled
    }

    public struct Affected: Hashable, Sendable {
        public var personID: String
        public var name: String
        /// 每个无法重算的样本的原因，按样本顺序
        public var unrecomputable: [VoiceprintRecomputeFailure]
        /// 一个样本都没能重算：这个人留在旧模型上，不参与识别，需要重新登记。
        /// 否则已换到新模型，只是少了这些样本
        public var keptOldModel: Bool

        public init(personID: String, name: String, unrecomputable: [VoiceprintRecomputeFailure], keptOldModel: Bool) {
            self.personID = personID
            self.name = name
            self.unrecomputable = unrecomputable
            self.keptOldModel = keptOldModel
        }
    }
}

extension VoiceprintRecomputeReport {
    /// 结束后在设置里显示的说明，一行一条：先总数，再逐个列出受影响的人
    public var summary: [String] {
        let head = isCancelled ? "已取消，已重算的 \(recomputed) 人保留。再点“重算声纹库”接着算剩下的"
            : "已用新模型重算 \(recomputed) 人"
        return [head] + affected.map { a in
            var seen = Set<String>()
            let reasons = a.unrecomputable.map(\.text).filter { seen.insert($0).inserted }.joined(separator: "、")
            return a.keptOldModel ? "\(a.name)：样本都无法重算（\(reasons)），需要在会议里重新登记"
                : "\(a.name)：\(a.unrecomputable.count) 个样本无法重算，已去掉（\(reasons)）"
        }
    }
}

/// 样本无法重算的原因
public enum VoiceprintRecomputeFailure: Error, Hashable, Sendable {
    /// 来源会议已删除
    case meetingDeleted
    /// 来源会议的录音不在了
    case noRecording
    /// 来源会议没有转写稿或读不了
    case noTranscript
    /// 在来源会议里找不到这个人（重新区分过、改过名等）
    case speakerNotFound
    /// 找到了这个人，但他的句子太短，算不出声纹
    case noSpeech
    /// 读不了录音等
    case failed(String)

    public var text: String {
        switch self {
        case .meetingDeleted: "来源会议已删除"
        case .noRecording: "来源会议的录音不在了"
        case .noTranscript: "来源会议没有转写稿"
        case .speakerNotFound: "在来源会议里找不到这个人"
        case .noSpeech: "这个人在来源会议里的发言太短"
        case let .failed(reason): reason
        }
    }
}

/// 换声纹模型后重算声纹库：对每个声纹模型与新模型不同的人的每个样本，从来源会议的录音里取这个人的句子
/// （按来源转写稿的说话人归属，见 `Transcript.voiceprintSourceSpeaker`），用新模型重算声纹。
///
/// - 一人一个声纹模型：一个人的样本全部算完才写回，写回时换成新模型，无法重算的样本丢掉；
///   一个都算不出的人不动（留在旧模型、不参与识别），列在结果里
/// - 逐人写回：读出当前的库，只改这个人（开始时读到的库不整份写回，期间的改名、登记不被覆盖）；
///   期间这个人被删除、样本或模型变了时跳过他，下次再算
/// - 取消（任务取消）时已写回的人保留，正在算的人不动，返回 `isCancelled`；再跑一次接着算剩下的
/// - 同一场会议的录音只解码一次（这场里所有待算的人一起算）
/// - 进度按样本计：(已处理的样本数, 待算的样本总数)
public enum VoiceprintRecompute {
    public static func run(voiceprints: VoiceprintStore, meetings: MeetingStore, extractor: any VoiceprintExtractor,
                           progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws
        -> VoiceprintRecomputeReport {
        let model = extractor.voiceprintModel
        let people = try voiceprints.load().people.filter { $0.voiceprintModel != model }
        let total = people.reduce(0) { $0 + $1.samples.count }
        let meetingsByID = Dictionary(meetings.loadAll().map { ($0.id, $0) }) { a, _ in a }
        var report = VoiceprintRecomputeReport(recomputed: 0, affected: [], isCancelled: false)
        var done = 0
        progress(0, total)

        /// (人员下标, 样本下标) → 结果
        var results: [Key: Result<VoiceprintSample, VoiceprintRecomputeFailure>] = [:]

        /// 算一场会议里所有待算的样本，一次解码
        func compute(meeting id: String) async throws {
            var pending: [(key: Key, sample: VoiceprintSample, person: VoiceprintPerson)] = []
            for (pi, p) in people.enumerated() {
                for (si, s) in p.samples.enumerated() where s.meetingID == id && results[Key(pi, si)] == nil {
                    pending.append((Key(pi, si), s, p))
                }
            }
            func fail(_ failure: VoiceprintRecomputeFailure) {
                for item in pending { results[item.key] = .failure(failure) }
            }
            guard let m = meetingsByID[id] else { return fail(.meetingDeleted) }
            guard let audio = meetings.recordingURL(m), FileManager.default.fileExists(atPath: audio.path) else {
                return fail(.noRecording)
            }
            guard let transcript = (try? meetings.loadTranscript(id)) ?? nil else { return fail(.noTranscript) }
            var groups: [(key: Key, speaker: Speaker, spans: [ClosedRange<TimeInterval>])] = []
            for item in pending {
                guard let speaker = transcript.voiceprintSourceSpeaker(of: item.sample, person: item.person) else {
                    results[item.key] = .failure(.speakerNotFound)
                    continue
                }
                let spans = transcript.sentences.filter { $0.speaker == speaker.id }.map { $0.start...max($0.start, $0.end) }
                groups.append((item.key, speaker, spans))
            }
            guard !groups.isEmpty else { return }
            let vectors: [Voiceprint?]
            do {
                vectors = try await extractor.voiceprints(audio: audio, groups: groups.map(\.spans))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                for g in groups { results[g.key] = .failure(.failed(error.localizedDescription)) }
                return
            }
            for (g, v) in zip(groups, vectors) {
                let old = people[g.key.person].samples[g.key.sample]
                results[g.key] = v.map {
                    .success(VoiceprintSample(
                        voiceprint: $0, meetingID: old.meetingID, speechDuration: g.speaker.speechDuration,
                        addedAt: old.addedAt,
                        source: transcript.diarization.map {
                            VoiceprintSampleSource(speakerID: g.speaker.id, speakersCreatedAt: $0.speakersCreatedAt)
                        }))
                } ?? .failure(.noSpeech)
            }
        }

        do {
            for (pi, p) in people.enumerated() {
                for (si, s) in p.samples.enumerated() where results[Key(pi, si)] == nil {
                    try Task.checkCancellation()
                    let before = results.count
                    try await compute(meeting: s.meetingID)
                    done += results.count - before
                    progress(done, total)
                }
                let outcomes = p.samples.indices.map { results[Key(pi, $0)]! }
                let recomputed = outcomes.compactMap { try? $0.get() }
                let failures = outcomes.compactMap { r -> VoiceprintRecomputeFailure? in
                    if case let .failure(f) = r { f } else { nil }
                }
                if !recomputed.isEmpty {
                    let written = try voiceprints.update { library -> Bool in
                        // 期间被删除、改过样本或模型（又登记了一次等）：不动，下次再算
                        guard let i = library.people.firstIndex(where: { $0.id == p.id }),
                              library.people[i].voiceprintModel == p.voiceprintModel,
                              library.people[i].samples == p.samples else { return false }
                        library.people[i].voiceprintModel = model
                        library.people[i].samples = recomputed
                        return true
                    }
                    if written { report.recomputed += 1 }
                }
                if !failures.isEmpty {
                    report.affected.append(.init(personID: p.id, name: p.name, unrecomputable: failures,
                                                 keptOldModel: recomputed.isEmpty))
                }
            }
        } catch is CancellationError {
            report.isCancelled = true
        }
        return report
    }

    private struct Key: Hashable {
        var person: Int
        var sample: Int
        init(_ person: Int, _ sample: Int) { self.person = person; self.sample = sample }
    }
}

/// 设置里「重算声纹库」的状态：开始、进度、取消、结果。同一时刻只跑一次
@MainActor @Observable
public final class VoiceprintRecomputation {
    public enum State: Hashable, Sendable {
        case idle
        /// 已处理的样本数 / 待算的样本总数
        case running(done: Int, total: Int)
        case finished(VoiceprintRecomputeReport)
        /// 声纹库读不出来等，没能开始
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// 声纹库可能被改了（每处理完一批样本、结束时）：界面据此重读
    @ObservationIgnored public var onLibraryChange: (() -> Void)?

    @ObservationIgnored private let voiceprints: VoiceprintStore
    @ObservationIgnored private let meetings: MeetingStore
    @ObservationIgnored private var task: Task<VoiceprintRecomputeReport, Error>?

    public init(voiceprints: VoiceprintStore, meetings: MeetingStore) {
        self.voiceprints = voiceprints
        self.meetings = meetings
    }

    public var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    /// 用 `extractor` 的模型重算声纹模型与它不同的人。正在算时什么都不做
    public func start(with extractor: any VoiceprintExtractor) {
        guard !isRunning else { return }
        state = .running(done: 0, total: 0)
        let (voiceprints, meetings) = (voiceprints, meetings)
        // 解码录音、读写文件都不在主线程
        let work = Task.detached(priority: .utility) {
            try await VoiceprintRecompute.run(voiceprints: voiceprints, meetings: meetings, extractor: extractor) {
                done, total in
                Task { @MainActor [weak self] in self?.progressed(done, total) }
            }
        }
        task = work
        Task { [weak self] in
            let result = await work.result
            self?.finish(result)
        }
    }

    /// 取消：已重算的人保留，正在算的人不动。结果里标为已取消
    public func cancel() {
        task?.cancel()
    }

    private func progressed(_ done: Int, _ total: Int) {
        guard isRunning else { return }
        state = .running(done: done, total: total)
        onLibraryChange?()
    }

    private func finish(_ result: Result<VoiceprintRecomputeReport, Error>) {
        task = nil
        switch result {
        case let .success(report): state = .finished(report)
        case let .failure(error): state = .failed("重算声纹库失败：\(error.localizedDescription)")
        }
        onLibraryChange?()
    }
}
