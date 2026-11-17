import Foundation
import Testing
@testable import FaymeeCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func sample(_ v: [Float], meeting: String = "m1", source: VoiceprintSampleSource? = nil) -> VoiceprintSample {
    VoiceprintSample(voiceprint: Voiceprint(v), meetingID: meeting, speechDuration: 30, addedAt: t0, source: source)
}

private func person(_ id: String, _ name: String, model: String = "old/vp",
                    _ samples: [VoiceprintSample]) -> VoiceprintPerson {
    VoiceprintPerson(id: id, name: name, voiceprintModel: model, samples: samples)
}

/// 张三（p1），登记在旧模型上
private func person(_ samples: [VoiceprintSample]) -> VoiceprintPerson { person("p1", "张三", samples) }

/// 来源会议的转写稿：spk1 说 0–5、11–15 秒，spk2 说 6–10 秒
private func transcript(model: String = "old/vp", createdAt: Date = t0, _ speakers: [Speaker]) -> Transcript {
    Transcript(engine: "test", createdAt: t0, hotwords: [], items: [
        .sentence(.init(id: "s1", start: 0, end: 5, text: "一", speaker: "spk1")),
        .sentence(.init(id: "s2", start: 6, end: 10, text: "二", speaker: "spk2")),
        .sentence(.init(id: "s3", start: 11, end: 15, text: "三", speaker: "spk1")),
    ], diarization: Diarization(engine: "fake", voiceprintModel: model, speakersCreatedAt: createdAt,
                                speakers: speakers))
}

private func spk(_ n: Int, _ v: [Float], name: String? = nil, personID: String? = nil) -> Speaker {
    Speaker(id: "spk\(n)", name: name, nameSource: name == nil ? nil : .user, personID: personID,
            voiceprint: Voiceprint(v), speechDuration: 20)
}

/// 从来源会议里找回样本对应的说话人（重算声纹库时取他的句子）
@Suite struct 样本的来源说话人 {
    let enrolled = sample([1, 0], source: VoiceprintSampleSource(speakerID: "spk2", speakersCreatedAt: t0))

    @Test func 记了来源且区分时间对得上_用记下的说话人_名字改过也一样() {
        let t = transcript([spk(1, [0, 1], name: "张三"), spk(2, [0.6, 0.8], name: "李四")])
        #expect(t.voiceprintSourceSpeaker(of: enrolled, person: person([enrolled]))?.id == "spk2")
    }

    @Test func 重新区分过_记下的编号不算数_按名字找() {
        let t = transcript(createdAt: t0 + 60, [spk(1, [0, 1], name: "张三"), spk(2, [0.6, 0.8], name: "李四")])
        #expect(t.voiceprintSourceSpeaker(of: enrolled, person: person([enrolled]))?.id == "spk1")
    }

    @Test func 没记来源时_声纹完全相同的说话人() {
        let old = sample([0.6, 0.8])
        let t = transcript([spk(1, [1, 0], name: "张三"), spk(2, [0.6, 0.8])])
        #expect(t.voiceprintSourceSpeaker(of: old, person: person([old]))?.id == "spk2")
    }

    @Test func 声纹库认出的说话人_按人员id() {
        let old = sample([0.6, 0.8])
        let t = transcript([spk(1, [1, 0]), spk(2, [0, 1], name: "张三丰", personID: "p1")])
        #expect(t.voiceprintSourceSpeaker(of: old, person: person([old]))?.id == "spk2")
    }

    @Test func 按名字找_去首尾空白() {
        let old = sample([0.6, 0.8])
        let t = transcript([spk(1, [1, 0], name: " 张三 "), spk(2, [0, 1])])
        #expect(t.voiceprintSourceSpeaker(of: old, person: person([old]))?.id == "spk1")
    }

    @Test func 同名的有两个_用旧模型的声纹挑最像的() {
        let old = sample([0.6, 0.8])
        let t = transcript([spk(1, [1, 0], name: "张三"), spk(2, [0.5, 0.86], name: "张三")])
        #expect(t.voiceprintSourceSpeaker(of: old, person: person([old]))?.id == "spk2")
    }

    @Test func 同名的有两个但这场用的是别的声纹模型_不可比_找不到() {
        let old = sample([0.6, 0.8])
        let t = transcript(model: "other/vp", [spk(1, [1, 0], name: "张三"), spk(2, [0.6, 0.8], name: "张三")])
        #expect(t.voiceprintSourceSpeaker(of: old, person: person([old])) == nil)
    }

    /// 合并过、改过名：名字和编号都对不上，声纹几乎一样（≥ 0.9）的才认
    @Test func 什么都对不上时_同模型声纹几乎一样的才认() {
        let old = sample([1, 0])
        let close = transcript([spk(1, [0.95, 0.31], name: "王五"), spk(2, [0, 1])])
        let far = transcript([spk(1, [0.8, 0.6], name: "王五"), spk(2, [0, 1])])
        #expect(close.voiceprintSourceSpeaker(of: old, person: person([old]))?.id == "spk1")
        #expect(far.voiceprintSourceSpeaker(of: old, person: person([old])) == nil)
    }

    @Test func 没区分过说话人_找不到() {
        let old = sample([1, 0])
        let t = Transcript(engine: "test", createdAt: t0, hotwords: [], items: [])
        #expect(t.voiceprintSourceSpeaker(of: old, person: person([old])) == nil)
    }
}

/// 假声纹提取：每组句子的声纹 = [组内句子总时长, 第几次调用]，记下每次收到的录音和句子
private final class FakeExtractor: VoiceprintExtractor, @unchecked Sendable {
    let voiceprintModel = "new/vp"
    private let lock = NSLock()
    private var _calls: [(audio: URL, groups: [[ClosedRange<TimeInterval>]])] = []
    /// 第几次调用（从 1 起）开始挂起，直到被取消或改回 nil
    var blockFrom: Int? {
        get { lock.withLock { _blockFrom } }
        set { lock.withLock { _blockFrom = newValue } }
    }
    private var _blockFrom: Int?
    let started: AsyncStream<Int>
    private let startedContinuation: AsyncStream<Int>.Continuation

    init() { (started, startedContinuation) = AsyncStream.makeStream() }

    var calls: [(audio: URL, groups: [[ClosedRange<TimeInterval>]])] { lock.withLock { _calls } }

    func voiceprints(audio: URL, groups: [[ClosedRange<TimeInterval>]]) async throws -> [Voiceprint?] {
        let n = lock.withLock { _calls.append((audio, groups)); return _calls.count }
        startedContinuation.yield(n)
        while let b = blockFrom, n >= b { try await Task.sleep(for: .milliseconds(5)) }
        return groups.map { g in
            g.isEmpty ? nil : Voiceprint([Float(g.reduce(0) { $0 + $1.upperBound - $1.lowerBound }), Float(n)])
        }
    }
}

/// 临时目录里的会议存储和声纹库
private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FaymeeRecompute-\(UUID().uuidString)",
                                                                            isDirectory: true)
    let meetings: MeetingStore
    let voiceprints: VoiceprintStore
    let extractor = FakeExtractor()

    init(_ people: [VoiceprintPerson]) throws {
        meetings = MeetingStore(root: root.appendingPathComponent("Meetings", isDirectory: true))
        voiceprints = VoiceprintStore(url: root.appendingPathComponent("voiceprints.json"))
        try voiceprints.save(VoiceprintLibrary(people: people))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// 一场有录音、有转写稿的会议
    func addMeeting(_ id: String, _ t: Transcript, recording: Bool = true) throws {
        let m = Meeting(id: id, title: "会议", startedAt: t0, endedAt: t0 + 600, status: .done,
                        recording: "recording.m4a", duration: 600)
        try FileManager.default.createDirectory(at: meetings.directory(id), withIntermediateDirectories: true)
        try meetings.save(m)
        try meetings.saveTranscript(t, for: id)
        if recording { try Data("audio".utf8).write(to: meetings.recordingURL(m)!) }
    }

    func recording(_ id: String) -> URL { meetings.directory(id).appendingPathComponent("recording.m4a") }

    func run(progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> VoiceprintRecomputeReport {
        try await VoiceprintRecompute.run(voiceprints: voiceprints, meetings: meetings, extractor: extractor,
                                          progress: progress)
    }
}

private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[Int]] = []
    func append(_ done: Int, _ total: Int) { lock.withLock { values.append([done, total]) } }
    var all: [[Int]] { lock.withLock { values } }
}

/// 换声纹模型后重算声纹库：从来源会议录音里取这个人的句子，用新模型重算
@Suite struct VoiceprintRecomputeTests {
    @Test func 来源会议在_用新模型重算_更新声纹模型和样本() async throws {
        let enrolled = sample([1, 0], meeting: "m1", source: VoiceprintSampleSource(speakerID: "spk1", speakersCreatedAt: t0))
        let f = try Fixture([person([enrolled])])
        try f.addMeeting("m1", transcript([spk(1, [1, 0], name: "张三"), spk(2, [0, 1])]))

        let report = try await f.run()

        #expect(report == VoiceprintRecomputeReport(recomputed: 1, affected: [], isCancelled: false))
        let p = try f.voiceprints.load().people[0]
        #expect(p.voiceprintModel == "new/vp")
        // spk1 的两句：0–5、11–15 秒，共 9 秒
        #expect(p.samples == [
            VoiceprintSample(voiceprint: Voiceprint([9, 1]), meetingID: "m1", speechDuration: 20, addedAt: t0,
                             source: VoiceprintSampleSource(speakerID: "spk1", speakersCreatedAt: t0)),
        ])
        #expect(f.extractor.calls.map(\.audio) == [f.recording("m1")])
        #expect(f.extractor.calls.map(\.groups) == [[[0...5, 11...15]]])
    }

    @Test func 来源会议已删除的样本无法重算_全部无法重算的人留在旧模型_部分无法重算的丢掉那些样本() async throws {
        let f = try Fixture([
            person("p1", "张三", [sample([1, 0], meeting: "gone")]),
            person("p2", "李四", [sample([0, 1], meeting: "m1"), sample([0, 1], meeting: "gone")]),
        ])
        try f.addMeeting("m1", transcript([spk(1, [1, 0]), spk(2, [0, 1], name: "李四")]))

        let report = try await f.run()

        #expect(report == VoiceprintRecomputeReport(recomputed: 1, affected: [
            .init(personID: "p1", name: "张三", unrecomputable: [.meetingDeleted], keptOldModel: true),
            .init(personID: "p2", name: "李四", unrecomputable: [.meetingDeleted], keptOldModel: false),
        ], isCancelled: false))
        let people = try f.voiceprints.load().people
        #expect(people[0] == person("p1", "张三", [sample([1, 0], meeting: "gone")]))
        #expect(people[1].voiceprintModel == "new/vp")
        #expect(people[1].samples.map(\.meetingID) == ["m1"])
        #expect(people[1].samples.map(\.voiceprint) == [Voiceprint([4, 1])])
    }

    @Test func 录音没了_转写稿没了_找不到这个人_都算无法重算() async throws {
        let f = try Fixture([person([
            sample([1, 0], meeting: "no-recording"), sample([1, 0], meeting: "no-transcript"),
            sample([1, 0], meeting: "stranger"),
        ])])
        try f.addMeeting("no-recording", transcript([spk(1, [1, 0], name: "张三")]), recording: false)
        try f.addMeeting("no-transcript", transcript([spk(1, [1, 0], name: "张三")]))
        try FileManager.default.removeItem(at: f.meetings.directory("no-transcript").appendingPathComponent("transcript.json"))
        try f.addMeeting("stranger", transcript([spk(1, [0, 1], name: "王五")]))

        let report = try await f.run()

        #expect(report.affected == [.init(personID: "p1", name: "张三",
                                          unrecomputable: [.noRecording, .noTranscript, .speakerNotFound],
                                          keptOldModel: true)])
        #expect(try f.voiceprints.load().people[0].voiceprintModel == "old/vp")
        #expect(f.extractor.calls.isEmpty)
    }

    @Test func 已经是当前模型的人不动_同一场会议只解码一次_进度按样本计() async throws {
        let f = try Fixture([
            person("p1", "张三", [sample([1, 0], meeting: "m1"), sample([1, 0], meeting: "m2")]),
            person("p2", "李四", [sample([0, 1], meeting: "m1")]),
            person("p3", "王五", model: "new/vp", [sample([5, 5], meeting: "m1")]),
        ])
        try f.addMeeting("m1", transcript([spk(1, [1, 0], name: "张三"), spk(2, [0, 1], name: "李四")]))
        try f.addMeeting("m2", transcript([spk(1, [0, 1]), spk(2, [1, 0], name: "张三")]))
        let progress = Progress()

        let report = try await f.run { progress.append($0, $1) }

        #expect(report.recomputed == 2)
        #expect(f.extractor.calls.map(\.audio) == [f.recording("m1"), f.recording("m2")])
        #expect(f.extractor.calls[0].groups == [[0...5, 11...15], [6...10]])
        let people = try f.voiceprints.load().people
        #expect(people.map(\.voiceprintModel) == ["new/vp", "new/vp", "new/vp"])
        #expect(people[2] == person("p3", "王五", model: "new/vp", [sample([5, 5], meeting: "m1")]))
        #expect(progress.all.first == [0, 3])
        #expect(progress.all.last == [3, 3])
        #expect(progress.all.map { $0[0] } == progress.all.map { $0[0] }.sorted())
    }

    /// 取消：已经重算完的人保留新模型，没算完的人一个样本都不动，库里每人的样本都是同一个模型；再跑一次接着算剩下的
    @Test func 取消后已重算的人保留_没算完的人不动_再跑一次接着算() async throws {
        let f = try Fixture([
            person("p1", "张三", [sample([1, 0], meeting: "m1")]),
            person("p2", "李四", [sample([0, 1], meeting: "m1"), sample([0, 1], meeting: "m2")]),
        ])
        try f.addMeeting("m1", transcript([spk(1, [1, 0], name: "张三"), spk(2, [0, 1], name: "李四")]))
        try f.addMeeting("m2", transcript([spk(1, [0, 1], name: "李四")]))
        f.extractor.blockFrom = 2

        let task = Task { try await f.run() }
        for await n in f.extractor.started where n == 2 { break }
        task.cancel()
        let report = try await task.value

        #expect(report.isCancelled)
        #expect(report.recomputed == 1)
        let people = try f.voiceprints.load().people
        #expect(people[0].voiceprintModel == "new/vp")
        #expect(people[0].samples.map(\.voiceprint) == [Voiceprint([9, 1])])
        #expect(people[1] == person("p2", "李四", [sample([0, 1], meeting: "m1"), sample([0, 1], meeting: "m2")]))

        f.extractor.blockFrom = nil
        let rest = try await f.run()
        #expect(rest == VoiceprintRecomputeReport(recomputed: 1, affected: [], isCancelled: false))
        #expect(try f.voiceprints.load().people.map(\.voiceprintModel) == ["new/vp", "new/vp"])
    }

    /// 重算期间声纹库在别处改了（改名、新登记的人）：只改重算的那个人，不拿开始时读到的整份库覆盖
    @Test func 重算期间声纹库的其他改动不被覆盖() async throws {
        let f = try Fixture([person("p1", "张三", [sample([1, 0], meeting: "m1")])])
        try f.addMeeting("m1", transcript([spk(1, [1, 0], name: "张三")]))
        f.extractor.blockFrom = 1
        let task = Task { try await f.run() }
        for await _ in f.extractor.started { break }

        try f.voiceprints.update {
            try $0.rename("p1", to: "张三丰")
            $0.people.append(person("p9", "新人", model: "new/vp", [sample([3, 4], meeting: "m9")]))
        }
        f.extractor.blockFrom = nil
        #expect(try await task.value.recomputed == 1)

        let people = try f.voiceprints.load().people
        #expect(people.map(\.name) == ["张三丰", "新人"])
        #expect(people.map(\.voiceprintModel) == ["new/vp", "new/vp"])
    }
}

/// 设置里「重算声纹库」按钮背后的状态
@MainActor @Suite struct VoiceprintRecomputationTests {
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test func 开始后进行中_结束后给出结果并通知声纹库变了() async throws {
        let f = try Fixture([person([sample([1, 0], meeting: "gone")])])
        let recomputation = VoiceprintRecomputation(voiceprints: f.voiceprints, meetings: f.meetings)
        var changes = 0
        recomputation.onLibraryChange = { changes += 1 }

        recomputation.start(with: f.extractor)
        #expect(recomputation.isRunning)
        try await until { !recomputation.isRunning }

        #expect(recomputation.state == .finished(VoiceprintRecomputeReport(recomputed: 0, affected: [
            .init(personID: "p1", name: "张三", unrecomputable: [.meetingDeleted], keptOldModel: true),
        ], isCancelled: false)))
        #expect(changes > 0)
    }

    @Test func 取消后结果标为已取消_正在算的人不动() async throws {
        let f = try Fixture([person([sample([1, 0], meeting: "m1")])])
        try f.addMeeting("m1", transcript([spk(1, [1, 0], name: "张三")]))
        f.extractor.blockFrom = 1
        let recomputation = VoiceprintRecomputation(voiceprints: f.voiceprints, meetings: f.meetings)

        recomputation.start(with: f.extractor)
        for await _ in f.extractor.started { break }
        recomputation.cancel()
        try await until { !recomputation.isRunning }

        guard case let .finished(report) = recomputation.state else { Issue.record("没有结束"); return }
        #expect(report.isCancelled)
        #expect(try f.voiceprints.load().people[0].voiceprintModel == "old/vp")
    }
}
