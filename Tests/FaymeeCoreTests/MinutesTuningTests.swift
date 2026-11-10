import Darwin
import Foundation
import Testing
@testable import FaymeeCore

/// 纪要提示词与采样参数的测量，不是回归测试：只打印指标，不做断言。默认跳过，
/// 设环境变量 `FAYMEE_TUNING=1` 才跑（每轮约 30 秒，要本机已下载模型）。
///
/// - `FAYMEE_TUNING_SEEDS`：每组跑几个 seed，默认 3
/// - `FAYMEE_TUNING_PRESENCE`：逗号分隔的 presence penalty，默认 "0"
/// - `FAYMEE_TUNING_OUT`：设了就把每次模型原始输出写到这个目录
/// - `FAYMEE_TUNING_CONTEXT`：引擎的上下文长度（n_ctx），默认 8192
/// - `FAYMEE_TUNING_NO_GRAMMAR=1`：不用文法约束输出，和带文法的对比
///
///     FAYMEE_TUNING=1 FAYMEE_TUNING_PRESENCE=1.5,0 swift test --filter MinutesTuning
private let env = ProcessInfo.processInfo.environment
private let contextLength = Int(env["FAYMEE_TUNING_CONTEXT"] ?? "") ?? LlamaTextGenerator.defaultContextLength
private let tuningEnabled = env["FAYMEE_TUNING"] == "1" && LocalModel.qwen3_4B.isDownloaded()

@Suite(.serialized, .enabled(if: tuningEnabled, "设 FAYMEE_TUNING=1 才跑"))
struct MinutesTuningTests {
    let seeds = (0..<(Int(env["FAYMEE_TUNING_SEEDS"] ?? "") ?? 3)).map { UInt32(1000 + $0 * 7) }
    let presences = (env["FAYMEE_TUNING_PRESENCE"] ?? "0").split(separator: ",").compactMap { Float($0) }

    /// 会议日期刻意避开提示词示例里的 2026-11-10/2026-11-18，免得模型照抄示例也“答对”
    static let meetingDays: [(label: String, start: String, today: String, friday: String, nextWednesday: String)] = [
        ("2026-12-03 周四", "2026-12-03T02:00:00Z", "2026-12-03", "2026-12-04", "2026-12-09"),
        ("2027-01-04 周一", "2027-01-04T02:00:00Z", "2027-01-04", "2027-01-08", "2027-01-13"),
    ]

    @Test func 周会转写稿_各seed的格式与截止日期() async throws {
        let transcript = try weeklyMeetingTranscript()
        print("| presence | 会议日期 | seed | 调用 | 输出 token | EOG | 秒 | 概要/决议/待办/未决 | 待办缺键 | 重复条目 | 下载器下周三 | 张伟周五 | 今天下午 |")
        for presence in presences {
            for day in Self.meetingDays {
                for seed in seeds {
                    let run = try await measure(transcript, startedAt: day.start, presence: presence, seed: seed)
                    let actions = run.minutes.sections.first { $0.kind == .actions }?.items ?? []
                    func due(_ ids: Set<String>, _ expected: String) -> String {
                        guard let item = actions.first(where: { !ids.isDisjoint(with: $0.refs.map(\.id)) }) else { return "缺" }
                        let got = item.dueDate?.description ?? "nil"
                        return got == expected ? "✓" : "✗\(got)"
                    }
                    print("| \(presence) | \(day.label) | \(seed) | \(run.calls) | \(run.outputTokens) | \(run.allEOG) | \(Int(run.seconds)) | \(run.counts) | \(run.missingKeys) | \(run.duplicates) | \(due(["s15", "s16", "s17", "s18"], day.nextWednesday)) | \(due(["s23", "s24"], day.friday)) | \(due(["s5"], day.today)) |")
                }
            }
        }
    }

    /// 一段接近装满的待办密集转写稿，看提取输出会不会超过 maxTokens 被截断
    @Test func 接近装满一段的待办密集转写稿() async throws {
        let transcript = denseTranscript()
        let engine = LlamaTextGenerator(seed: 7)
        defer { engine.unload() }
        let lines = transcript.items.map(inputLine).joined(separator: "\n")
        print("密集转写稿：\(transcript.sentences.count) 句，\(engine.countTokens(lines)) token；contextTokens \(engine.contextTokens)")
        for presence in presences {
            let run = try await measure(transcript, startedAt: "2026-12-03T02:00:00Z", presence: presence, seed: 7)
            print("presence \(presence)：调用 \(run.calls) 次，各次输出 \(run.outputTokensEach) token，各次 maxTokens \(run.maxTokens)，EOG \(run.allEOG)，\(Int(run.seconds)) 秒，各节 \(run.counts)，待办缺键 \(run.missingKeys)，重复 \(run.duplicates)")
        }
    }

    /// 两轮议题、约 450 句（按每句 8 秒约 1 小时）的密集转写稿：多段提取 + 多轮合并能不能走完
    @Test func 一小时的待办密集转写稿() async throws {
        let transcript = denseTranscript(rounds: 2)
        for presence in presences {
            do {
                let run = try await measure(transcript, startedAt: "2026-12-03T02:00:00Z", presence: presence, seed: 7)
                print("一小时密集稿 presence \(presence)，n_ctx \(contextLength)：调用 \(run.calls) 次，各次输出 \(run.outputTokensEach) token，各次 maxTokens \(run.maxTokens)，EOG \(run.allEOG)，\(Int(run.seconds)) 秒，各节 \(run.counts)，重复 \(run.duplicates)")
                print("召回（按出处对上构造的句子）：\(denseRecall(run.minutes, rounds: 2))；原始输出里单条 refs 最多 \(run.maxRawRefs) 个")
            } catch {
                print("一小时密集稿 presence \(presence)，n_ctx \(contextLength)：失败 \(error)；已完成的调用输出 \(lastRecorder?.stats.map(\.outputTokens) ?? [])，maxTokens \(lastRecorder?.maxTokens ?? [])")
            }
        }
    }

    /// 周会转写稿生成一次的耗时，以及加载、生成、释放前后的进程内存（phys_footprint，活动监视器的“内存”列；
    /// 模型权重是 mmap 的，不算在内）
    @Test func 加载生成释放的耗时与内存() async throws {
        let transcript = try weeklyMeetingTranscript()
        print("内存（MB），n_ctx \(contextLength)：开始 \(footprintMB())")
        for round in 1...2 {
            let engine = LlamaTextGenerator(contextLength: contextLength, seed: 1)
            let loadStart = Date()
            try await engine.load { _ in }
            let loaded = footprintMB()
            let started = Date()
            let recorder = Recorder(engine)
            _ = try await generateMinutes(
                transcript: transcript, title: "迭代周会", startedAt: try Date("2026-12-03T02:00:00Z", strategy: .iso8601),
                template: .general, generator: recorder, model: LocalModel.qwen3_4B.id)
            let seconds = Date().timeIntervalSince(started)
            let generated = footprintMB()
            let stats = engine.lastStats!
            engine.unload()
            if let dir = env["FAYMEE_TUNING_OUT"] {
                for (n, output) in recorder.outputs.enumerated() {
                    try? output.write(toFile: "\(dir)/timing-r\(round)-\(n).json", atomically: true, encoding: .utf8)
                }
            }
            // 解析失败重试时有不止一次调用，各次的输出 token 和秒数都列出来
            let each = recorder.stats.map { String(format: "%d token %.1f 秒", $0.outputTokens, $0.totalSeconds) }
            print(String(format: "第 %d 轮：加载 %.1f 秒；生成 %.1f 秒（prompt %d token %.1f 秒）；调用 %d 次：%@；内存 加载后 %d、生成后 %d、释放后 %d",
                         round, started.timeIntervalSince(loadStart), seconds, stats.promptTokens, stats.promptSeconds,
                         recorder.stats.count, each.joined(separator: "，"), loaded, generated, footprintMB()))
        }
    }

    /// 带说话人的短会（三人都没命名，会上有人被叫名字）：看姓名建议和负责人关联。
    /// 期望：说话人 2 是王总，说话人 3 是小李；报价单的负责人是说话人 2，测试报告的是说话人 3
    @Test func 带说话人的短会_姓名建议与负责人() async throws {
        let transcript = speakerMeetingTranscript()
        print("| seed | 秒 | 姓名建议 | 待办（负责人 → 关联） |")
        for seed in seeds {
            let run = try await measure(transcript, startedAt: "2026-12-03T02:00:00Z", presence: presences[0], seed: seed)
            let suggestions = run.minutes.nameSuggestions
                .map { "\($0.speaker)=\($0.name)(\($0.refs.map(\.id).joined(separator: ",")))" }
            let actions = (run.minutes.sections.first { $0.kind == .actions }?.items ?? [])
                .map { "\($0.text)：\($0.owner ?? "nil") → \($0.ownerSpeaker ?? "nil")" }
            print("| \(seed) | \(Int(run.seconds)) | \(suggestions.joined(separator: "；")) | \(actions.joined(separator: "；")) |")
        }
    }

    struct Run {
        var minutes: Minutes
        var calls: Int
        var outputTokensEach: [Int]
        var maxTokens: [Int]
        var allEOG: Bool
        var seconds: TimeInterval
        var missingKeys: Int
        var duplicates: Int
        /// 模型原始输出里单个条目最多列了几个出处（截断之前）
        var maxRawRefs: Int
        var outputTokens: Int { outputTokensEach.reduce(0, +) }
        var counts: String { minutes.sections.prefix(4).map { "\($0.items.count)" }.joined(separator: "/") }
    }

    private func measure(_ transcript: Transcript, startedAt: String, presence: Float, seed: UInt32) async throws -> Run {
        let engine = LlamaTextGenerator(contextLength: contextLength, seed: seed)
        engine.sampling.presencePenalty = presence
        defer { engine.unload() }
        try await engine.load { _ in }
        let recorder = Recorder(engine)
        lastRecorder = recorder
        let started = Date()
        // 失败时也把已有的原始输出写下来，方便看是截断还是陷入重复
        defer {
            if let dir = env["FAYMEE_TUNING_OUT"] {
                for (n, output) in recorder.outputs.enumerated() {
                    try? output.write(toFile: "\(dir)/\(startedAt.prefix(10))-p\(presence)-s\(seed)-\(n).json",
                                      atomically: true, encoding: .utf8)
                }
            }
        }
        let minutes = try await generateMinutes(
            transcript: transcript, title: "迭代周会", startedAt: try Date(startedAt, strategy: .iso8601),
            template: .general, generator: recorder, model: LocalModel.qwen3_4B.id,
            timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let seconds = Date().timeIntervalSince(started)
        // 待办缺键、重复条目：看模型原始输出（解析后缺键和 null 分不出来）
        var missing = 0, duplicates = 0, maxRawRefs = 0
        for output in recorder.outputs {
            guard let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"),
                  let object = try? JSONSerialization.jsonObject(with: Data(output[open...close].utf8)) as? [String: Any]
            else { continue }
            for (key, value) in object {
                let items = (value as? [[String: Any]]) ?? []
                if key == "actions" {
                    missing += items.reduce(0) { n, item in
                        n + ["text", "owner", "due", "dueDate", "refs"].filter { item[$0] == nil }.count
                    }
                }
                maxRawRefs = max(maxRawRefs, items.map { ($0["refs"] as? [Any])?.count ?? 0 }.max() ?? 0)
                let texts = items.compactMap { $0["text"] as? String }
                duplicates += texts.count - Set(texts).count
            }
        }
        return Run(minutes: minutes, calls: recorder.stats.count, outputTokensEach: recorder.stats.map(\.outputTokens),
                   maxTokens: recorder.maxTokens, allEOG: recorder.stats.allSatisfy(\.endedByEOG), seconds: seconds,
                   missingKeys: missing, duplicates: duplicates, maxRawRefs: maxRawRefs)
    }
}

/// 三人短会：说话人 1 主持，说话人 2 是被叫作“王总”的客户方，说话人 3 是被叫作“小李”的同事
private func speakerMeetingTranscript() -> Transcript {
    let lines: [(String, String)] = [
        ("spk1", "今天主要对一下报价和上线时间"),
        ("spk1", "王总，您那边对上次的报价有什么意见"),
        ("spk2", "整体可以接受，但是实施费用还想再谈一谈"),
        ("spk2", "这样吧，下周三之前我把我们的预算范围发给你们"),
        ("spk1", "好的，那上线时间呢"),
        ("spk2", "我们希望一月底之前能上线"),
        ("spk1", "小李，测试那边来得及吗"),
        ("spk3", "来得及，我这周五之前把测试报告整理出来"),
        ("spk1", "那就先按一月底上线来准备"),
        ("spk2", "可以，培训的事情以后再说"),
    ]
    return Transcript(
        engine: "apple/speechanalyzer", createdAt: try! Date("2026-12-03T03:01:00Z", strategy: .iso8601), hotwords: [],
        items: lines.enumerated().map { i, line in
            .sentence(TranscriptSentence(id: "s\(i + 1)", start: Double(i * 8), end: Double(i * 8 + 6), text: line.1,
                                         speaker: line.0))
        },
        diarization: Diarization(engine: "fake", voiceprintModel: "fake", speakersCreatedAt: Date(timeIntervalSince1970: 0),
                                 speakers: ["spk1", "spk2", "spk3"].map {
                                     Speaker(id: $0, voiceprint: Voiceprint([1]), speechDuration: 20)
                                 }))
}

private func footprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
}

private nonisolated(unsafe) var lastRecorder: Recorder?

/// 记下每次调用的原始输出和统计
private final class Recorder: TextGenerator, @unchecked Sendable {
    let engine: LlamaTextGenerator
    var outputs: [String] = []
    var stats: [LlamaTextGenerator.Stats] = []
    var maxTokens: [Int] = []
    init(_ engine: LlamaTextGenerator) { self.engine = engine }
    var contextTokens: Int { engine.contextTokens }
    func countTokens(_ text: String) -> Int { engine.countTokens(text) }
    var isDownloaded: Bool { engine.isDownloaded }
    func load(progress: @escaping (Double) -> Void) async throws { try await engine.load(progress: progress) }
    func unload() { engine.unload() }
    func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        try await generate(system: system, prompt: prompt, maxTokens: maxTokens, grammar: nil)
    }
    func generate(system: String, prompt: String, maxTokens: Int, grammar: String?) async throws -> String {
        let output = try await engine.generate(system: system, prompt: prompt, maxTokens: maxTokens,
                                               grammar: env["FAYMEE_TUNING_NO_GRAMMAR"] == "1" ? nil : grammar)
        outputs.append(output)
        stats.append(engine.lastStats!)
        self.maxTokens.append(maxTokens)
        return output
    }
}

/// 按出处算 `denseTranscript` 的召回：某节有条目的出处落在该条构造的句子上就算召回。
/// 每个议题 14 句，决议是第 7、8 句，两条待办是第 9、10 句和第 11、12 句，未决问题是第 13、14 句。
/// 议题名有前缀关系（“登录页改版”和“登录页改版二期”），所以按出处而不按文字对
private func denseRecall(_ minutes: Minutes, rounds: Int) -> String {
    let topics = 16 * rounds
    func refs(_ kind: MinutesSectionKind) -> Set<String> {
        Set(minutes.sections.first { $0.kind == kind }?.items.flatMap { $0.refs.map(\.id) } ?? [])
    }
    func recalled(_ kind: MinutesSectionKind, _ lines: [[Int]]) -> String {
        let cited = refs(kind)
        let hits = (0..<topics).flatMap { t in lines.map { $0.map { "s\(t * 14 + $0)" } } }
            .filter { !cited.isDisjoint(with: $0) }.count
        return "\(hits)/\(topics * lines.count)"
    }
    let actions = minutes.sections.first { $0.kind == .actions }?.items ?? []
    return "决议 \(recalled(.decisions, [[7, 8]]))，待办 \(recalled(.actions, [[9, 10], [11, 12]]))，"
        + "未决 \(recalled(.questions, [[13, 14]]))；待办 \(actions.count) 条，有负责人 \(actions.count { $0.owner != nil })，"
        + "有截止日期 \(actions.count { $0.dueDate != nil })"
}

/// 合成的待办密集转写稿：每轮 16 个议题，每个议题有讨论、一条决议、两条带负责人和截止时间的待办、
/// 一个未决问题，一轮 224 句。第二轮起议题名加“二期”等，负责人错开
private func denseTranscript(rounds: Int = 1) -> Transcript {
    let topics = ["登录页改版", "支付回调", "数据导出", "消息推送", "搜索排序", "权限管理", "日志采集", "灰度发布",
                  "客服工单", "报表看板", "图片压缩", "离线缓存", "订单退款", "会员积分", "短信验证", "接口限流"]
    let people = ["张伟", "李娜", "王强", "刘洋", "陈静", "赵磊"]
    let dues = ["明天", "周五之前", "下周一", "下周三之前", "月底前", "本周内", "后天", "下周五"]
    var lines: [String] = []
    let phases = ["", "二期", "三期", "四期"]
    for (i, topic) in (0..<rounds).flatMap({ r in topics.map { $0 + phases[r] } }).enumerated() {
        let a = people[i % people.count], b = people[(i + 2) % people.count], c = people[(i + 4) % people.count]
        lines += [
            "下一个是\(topic)，\(a)你先说一下现在的情况",
            "\(topic)目前完成了大概七成，剩下的主要是边界情况和测试",
            "上周说的那个兼容问题解决了吗",
            "解决了一半，老版本的客户端还有点问题，要再看看",
            "那老版本还要不要支持，用的人已经很少了",
            "我看了数据，老版本占比不到百分之三",
            "那就定了，\(topic)不再支持老版本客户端",
            "好，那我这边把兼容代码删掉",
            "\(b)你负责把\(topic)的测试用例补齐，\(dues[i % dues.count])给我",
            "没问题，\(dues[i % dues.count])之前补完",
            "\(c)你去跟设计确认一下\(topic)的交互稿，\(dues[(i + 3) % dues.count])要",
            "行，我\(dues[(i + 3) % dues.count])之前确认好",
            "还有一个问题，\(topic)上线以后要不要单独做监控，这个还没想好",
            "这个先放一放，下次再讨论",
        ]
    }
    let sentences = lines.enumerated().map { n, text in
        TranscriptSentence(id: "s\(n + 1)", start: Double(n) * 8, end: Double(n) * 8 + 6, text: text)
    }
    return Transcript(engine: "apple/speechanalyzer", createdAt: Date(timeIntervalSince1970: 1_794_279_660),
                      hotwords: [], items: sentences.map { .sentence($0) })
}
