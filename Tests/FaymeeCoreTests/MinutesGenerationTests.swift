import Foundation
import Testing
@testable import FaymeeCore

private func date(_ iso: String) -> Date {
    try! Date(iso, strategy: .iso8601)
}

private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

/// 假引擎：按脚本依次返回固定输出，记录每次调用。countTokens 按字数计
private final class ScriptedGenerator: TextGenerator, @unchecked Sendable {
    let contextTokens: Int
    var outputs: [String]
    /// 设了就在 generate 里抛出
    var error: Error?
    /// 设了就不用 outputs，按提示词现算输出
    var respond: ((_ system: String, _ prompt: String) -> String)?
    private(set) var calls: [(system: String, prompt: String, maxTokens: Int)] = []
    /// 每次调用收到的输出文法
    private(set) var grammars: [String?] = []

    init(contextTokens: Int = 100_000, outputs: [String] = []) {
        self.contextTokens = contextTokens
        self.outputs = outputs
    }

    /// 提取调用：提示词里有转写稿的句子行。其余是合并调用
    var extractionCalls: [String] { calls.map(\.prompt).filter { !transcriptLines(in: $0).isEmpty } }
    var mergeCalls: [String] { calls.map(\.prompt).filter { transcriptLines(in: $0).isEmpty } }

    func countTokens(_ text: String) -> Int { text.count }
    var isDownloaded: Bool { true }
    func load(progress: @escaping (Double) -> Void) async throws {}
    func unload() {}

    func generate(system: String, prompt: String, maxTokens: Int, grammar: String?) async throws -> String {
        grammars.append(grammar)
        return try await generate(system: system, prompt: prompt, maxTokens: maxTokens)
    }

    func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        calls.append((system, prompt, maxTokens))
        if let error { throw error }
        if let respond { return respond(system, prompt) }
        guard !outputs.isEmpty else { Issue.record("脚本里的输出用完了"); return "" }
        return outputs.removeFirst()
    }
}

/// 提示词里的转写稿行：句子行 `[s12 …] …` 和合盖行 `[合盖，…]`
private func transcriptLines(in prompt: String) -> [String] {
    prompt.split(separator: "\n").map(String.init)
        .filter { $0.hasPrefix("[合盖") || $0.wholeMatch(of: try! Regex(#"\[s\d+ [\d:]+\] .*"#)) != nil }
}

/// 一份长转写稿：s1…sN 每句 30 来个字，句间隔 10 秒（停顿 2 秒）。
/// `gapAfter` 句之后插一段合盖空白，`pauseAfter` 句之后停顿 60 秒
private func longTranscript(count: Int, gapAfter: Int? = nil, pauseAfter: Int? = nil) -> Transcript {
    var items: [TranscriptItem] = []
    var t: TimeInterval = 0
    for i in 1...count {
        items.append(.sentence(TranscriptSentence(id: "s\(i)", start: t, end: t + 8,
                                                  text: "这是第\(i)句话，大家讨论了项目的进度和下一步的安排")))
        t += 10
        if i == gapAfter {
            items.append(.gap(TranscriptGap(start: t, end: t + 120, reason: .lidClosed)))
            t += 120
        }
        if i == pauseAfter { t += 60 }
    }
    return Transcript(engine: "apple/speechanalyzer", createdAt: date("2026-11-10T03:01:00Z"), hotwords: [],
                      items: items)
}

/// 提取时每段给一条概要，出处是该段第一句；合并时把收到的出处都放进一条概要
private func echoingResponder(_ system: String, _ prompt: String) -> String {
    let lines = transcriptLines(in: prompt)
    if let first = lines.first(where: { $0.hasPrefix("[s") }) {
        let id = first.dropFirst().prefix { $0 != " " }
        return #"{"overview": [{"text": "\#(id) 开始的一段", "refs": ["\#(id)"]}]}"#
    }
    let ids = prompt.matches(of: try! Regex(#""s\d+""#)).map { String(prompt[$0.range]) }
    return #"{"overview": [{"text": "全场概要", "refs": [\#(ids.joined(separator: ", "))]}]}"#
}

/// 一份短转写稿：五句，中间一段合盖空白；s3 被人工修改过。
/// start 故意取和时间标签对不上的小数，证明出处记的是句子的 start
private let transcript = Transcript(
    engine: "apple/speechanalyzer", createdAt: date("2026-11-10T03:01:00Z"), hotwords: [],
    items: [
        .sentence(TranscriptSentence(id: "s1", start: 3.2, end: 6, text: "我们今天讨论 v2.3 的发布时间")),
        .sentence(TranscriptSentence(id: "s2", start: 760.4, end: 765, text: "支付接口还没准备好")),
        .gap(TranscriptGap(start: 800, end: 980, reason: .lidClosed)),
        .sentence(TranscriptSentence(id: "s3", start: 1880.2, end: 1885, text: "张三你下周三之前把报价单发给客户",
                                     original: "张三你下周三之前把报价但发给客户")),
        .sentence(TranscriptSentence(id: "s4", start: 1890, end: 1893, text: "那就推迟一周发布")),
        .sentence(TranscriptSentence(id: "s5", start: 2645.5, end: 2650, text: "海外版的预算还没定")),
    ])

private func generate(_ generator: ScriptedGenerator, transcript: Transcript = transcript,
                      template: MinutesTemplate = .general,
                      progress: @escaping (Double) -> Void = { _ in }) async throws -> Minutes {
    try await generateMinutes(
        transcript: transcript, title: "产品周会", startedAt: date("2026-11-10T02:00:00Z"),
        template: template, generator: generator, model: "fake/scripted",
        createdAt: date("2026-11-10T03:05:00Z"), timeZone: shanghai, progress: progress)
}

@Suite struct MinutesGenerationTests {
    @Test func 出处记下句子的start_不存在的出处被丢弃() async throws {
        let generator = ScriptedGenerator(outputs: [#"""
        {"overview": [{"text": "讨论了 v2.3 的发布时间", "refs": ["s1", "s99", "s2"]}],
         "decisions": [{"text": "推迟一周发布", "refs": ["s4"]}],
         "actions": [],
         "questions": [{"text": "竞品的定价", "refs": ["s42", "x"]}]}
        """#])

        let minutes = try await generate(generator)

        let overview = try #require(minutes.sections.first { $0.kind == .overview })
        #expect(overview.items.map(\.refs) == [[MinutesRef(id: "s1", start: 3.2), MinutesRef(id: "s2", start: 760.4)]])
        let decisions = try #require(minutes.sections.first { $0.kind == .decisions })
        #expect(decisions.items.map(\.refs) == [[MinutesRef(id: "s4", start: 1890)]])
        let questions = try #require(minutes.sections.first { $0.kind == .questions })
        #expect(questions.items.map(\.text) == ["竞品的定价"])
        #expect(questions.items.map(\.isUnsourced) == [true])
        #expect(overview.items.map(\.isUnsourced) == [false])
    }

    /// 实测模型会在 refs 里一直往下列编号（ticket 04），每条最多留 3 个：
    /// 先丢掉不存在的和重复的，再按模型给的顺序取前 3 个
    @Test func 每条出处最多保留3个_丢掉无效的之后取最先列出的() async throws {
        let generator = ScriptedGenerator(outputs: [#"""
        {"decisions": [{"text": "推迟一周发布", "refs": ["s99", "s4", "s4", "s2", "x", "s5", "s1", "s3"]}],
         "actions": [{"text": "发报价单", "owner": "张三", "refs": ["s3", "s1"]}]}
        """#])

        let minutes = try await generate(generator)

        #expect(minutes.sections[1].items.map { $0.refs.map(\.id) } == [["s4", "s2", "s5"]])
        #expect(minutes.sections[2].items.map { $0.refs.map(\.id) } == [["s3", "s1"]])
    }

    @Test func 输入用修改后的文字_合盖空白以标记行出现_附会议标题日期星期() async throws {
        let generator = ScriptedGenerator(outputs: [emptyOutput])

        _ = try await generate(generator)

        let prompt = try #require(generator.calls.first?.prompt)
        #expect(prompt.contains("""
        [s1 00:03] 我们今天讨论 v2.3 的发布时间
        [s2 12:40] 支付接口还没准备好
        [合盖，未录到声音 13:20–16:20]
        [s3 31:20] 张三你下周三之前把报价单发给客户
        [s4 31:30] 那就推迟一周发布
        [s5 44:05] 海外版的预算还没定
        """))
        #expect(!prompt.contains("报价但"))
        #expect(prompt.contains("产品周会"))
        #expect(prompt.contains("2026-11-10"))
        #expect(prompt.contains("星期二"))
        #expect(prompt.contains("10:00"))
    }

    @Test func 输入附上会议之后的相对日期对照表_供换算截止时间() async throws {
        // 2026-11-10 是星期二
        let generator = ScriptedGenerator(outputs: [emptyOutput])

        _ = try await generate(generator)

        let prompt = try #require(generator.calls.first?.prompt)
        #expect(prompt.contains("""
        - 今天：2026-11-10（星期二）
        - 明天：2026-11-11（星期三）
        - 后天：2026-11-12（星期四）
        - 本周三：2026-11-11（星期三）
        - 本周四：2026-11-12（星期四）
        - 本周五：2026-11-13（星期五）
        - 本周六：2026-11-14（星期六）
        - 本周日：2026-11-15（星期日）
        - 下周一：2026-11-16（星期一）
        - 下周二：2026-11-17（星期二）
        - 下周三：2026-11-18（星期三）
        - 下周四：2026-11-19（星期四）
        - 下周五：2026-11-20（星期五）
        - 下周六：2026-11-21（星期六）
        - 下周日：2026-11-22（星期日）
        - 本月底：2026-11-30（星期一）
        """))
    }

    @Test func 周日开会时本周只剩今天_下周从明天开始() async throws {
        let generator = ScriptedGenerator(outputs: [emptyOutput])

        _ = try await generateMinutes(
            transcript: transcript, title: "周日加班", startedAt: date("2026-11-15T02:00:00Z"),
            template: .general, generator: generator, model: "fake/scripted", timeZone: shanghai)

        let prompt = try #require(generator.calls.first?.prompt)
        #expect(prompt.contains("""
        - 今天：2026-11-15（星期日）
        - 明天：2026-11-16（星期一）
        - 后天：2026-11-17（星期二）
        - 下周一：2026-11-16（星期一）
        """))
        #expect(!prompt.contains("本周"))
        #expect(prompt.contains("- 下周日：2026-11-22（星期日）\n- 本月底：2026-11-30（星期一）"))
    }

    /// 模型查表也会抄错行（实测把“周五”“后天”填晚一天），due 是常见说法时由代码按会议日期换算，
    /// 不认识的说法才用模型给的 dueDate。2026-11-10 是星期二
    @Test func 常见的相对日期由代码换算_不认识的说法用模型给的() async throws {
        let generator = ScriptedGenerator(outputs: [#"""
        {"actions": [
           {"text": "a", "due": "周五之前", "dueDate": "2026-11-14", "refs": ["s1"]},
           {"text": "b", "due": "下周三", "dueDate": null, "refs": ["s1"]},
           {"text": "c", "due": "今天下午", "dueDate": "2026-11-11", "refs": ["s1"]},
           {"text": "d", "due": "这周内", "dueDate": null, "refs": ["s1"]},
           {"text": "e", "due": "下星期一以前", "dueDate": "2026-11-10", "refs": ["s1"]},
           {"text": "f", "due": "后天", "dueDate": "2026-11-13", "refs": ["s1"]},
           {"text": "g", "due": "月底前", "dueDate": null, "refs": ["s1"]},
           {"text": "h", "due": "周日", "dueDate": null, "refs": ["s1"]},
           {"text": "i", "due": "客户确认以后", "dueDate": "2026-11-20", "refs": ["s1"]},
           {"text": "j", "due": "周二", "dueDate": null, "refs": ["s1"]}
         ]}
        """#])

        let minutes = try await generate(generator)

        let dates = minutes.sections[2].items.map { $0.dueDate?.description }
        #expect(dates == ["2026-11-13", "2026-11-18", "2026-11-10", "2026-11-13", "2026-11-16",
                          "2026-11-12", "2026-11-30", "2026-11-15", "2026-11-20", "2026-11-17"])
        #expect(minutes.sections[2].items.map(\.due) == ["周五之前", "下周三", "今天下午", "这周内", "下星期一以前",
                                                         "后天", "月底前", "周日", "客户确认以后", "周二"])
    }

    @Test func source记录快照的createdAt和哈希() async throws {
        let minutes = try await generate(ScriptedGenerator(outputs: [emptyOutput]))

        #expect(minutes.source == MinutesSource(transcriptCreatedAt: date("2026-11-10T03:01:00Z"),
                                                textHash: transcript.textHash))
        #expect(minutes.model == "fake/scripted")
        #expect(minutes.template == "general")
        #expect(minutes.createdAt == date("2026-11-10T03:05:00Z"))
    }

    @Test func 待办带负责人和截止时间_dueDate非法时置空保留due_空节保留() async throws {
        let generator = ScriptedGenerator(outputs: [#"""
        {"overview": [{"text": "讨论了发布时间", "refs": ["s1"], "owner": "李四"}],
         "decisions": [],
         "actions": [
           {"text": "把报价单发给客户", "owner": "张三", "due": "下周三", "dueDate": "2026-11-18", "refs": ["s3"]},
           {"text": "确认支付接口", "owner": null, "due": "等支付那边回复以后", "dueDate": "2026-11-31", "refs": ["s2"]},
           {"text": "整理海外版预算", "owner": "", "due": "", "dueDate": "下周", "refs": ["s5"]},
           {"refs": ["s4"]},
           "坏条目"
         ]}
        """#])

        let minutes = try await generate(generator)

        #expect(minutes.sections.map(\.kind) == [.overview, .decisions, .actions, .questions])
        #expect(minutes.sections.map(\.title) == ["概要", "决议", "待办", "未决问题"])
        #expect(minutes.sections[0].items == [
            MinutesItem(id: "o1", text: "讨论了发布时间", refs: [MinutesRef(id: "s1", start: 3.2)]),
        ])
        #expect(minutes.sections[1].items.isEmpty)
        #expect(minutes.sections[2].items == [
            MinutesItem(id: "a1", text: "把报价单发给客户", owner: "张三", due: "下周三",
                        dueDate: CalendarDate(year: 2026, month: 11, day: 18),
                        refs: [MinutesRef(id: "s3", start: 1880.2)]),
            MinutesItem(id: "a2", text: "确认支付接口", due: "等支付那边回复以后", refs: [MinutesRef(id: "s2", start: 760.4)]),
            MinutesItem(id: "a3", text: "整理海外版预算", refs: [MinutesRef(id: "s5", start: 2645.5)]),
        ])
        #expect(minutes.sections[3].items.isEmpty)
    }

    /// 生成的纪要写盘再读回应当不变：01 的编码只给待办节写 owner/due/dueDate
    @Test func 生成的纪要写盘读回不变() async throws {
        let generator = ScriptedGenerator(outputs: [#"""
        {"overview": [{"text": "讨论了发布时间", "refs": ["s1"], "owner": "李四", "due": "明天"}],
         "actions": [{"text": "把报价单发给客户", "owner": "张三", "due": "下周三", "dueDate": "2026-11-18", "refs": ["s3"]}],
         "questions": [{"text": "海外版预算", "refs": ["s5", "s5"]}]}
        """#])
        let minutes = try await generate(generator)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Minutes.self, from: encoder.encode(minutes)) == minutes)
        #expect(minutes.sections[3].items.map(\.refs) == [[MinutesRef(id: "s5", start: 2645.5)]])
    }

    @Test(arguments: [
        ("general", "通用", [], nil),
        ("weekly", "周会", [("progress", "各项进展")], "风险"),
        ("customer", "客户拜访", [("requests", "客户诉求"), ("commitments", "我方承诺")], "预算"),
        ("interview", "面试", [("strengths", "候选人亮点"), ("concerns", "顾虑"), ("recommendation", "结论建议")],
         "不替面试官下结论"),
        ("review", "评审", [("issues", "问题清单")], "严重程度"),
    ] as [(String, String, [(String, String)], String?)])
    func 每个模板都生成出对应的节(key: String, name: String, custom: [(String, String)], focus: String?) async throws {
        let template = try #require(MinutesTemplate(key: key))
        let customJSON = custom.map { #""\#($0.0)": [{"text": "\#($0.1)的一条", "refs": ["s2"]}]"# }
        let generator = ScriptedGenerator(outputs: [
            "{" + ([#""overview": [{"text": "概要的一条", "refs": ["s1"]}]"#] + customJSON).joined(separator: ", ") + "}",
        ])

        let minutes = try await generate(generator, template: template)

        #expect(template.name == name)
        #expect(minutes.template == key)
        #expect(minutes.sections.map(\.kind) == [.overview, .decisions, .actions, .questions] + custom.map { .custom($0.0) })
        #expect(minutes.sections.map(\.title) == ["概要", "决议", "待办", "未决问题"] + custom.map(\.1))
        #expect(minutes.sections.map(\.items.count) == [1, 0, 0, 0] + custom.map { _ in 1 })
        for (section, (k, title)) in zip(minutes.sections.dropFirst(4), custom) {
            #expect(section.items.map(\.id) == ["\(k)-1"])
            #expect(section.items.map(\.text) == ["\(title)的一条"])
            #expect(generator.calls[0].system.contains(title))
        }
        if let focus { #expect(generator.calls[0].system.contains(focus)) }
    }

    @Test func 内置五个模板_通用为默认() {
        #expect(MinutesTemplate.all.map(\.key) == ["general", "weekly", "customer", "interview", "review"])
        #expect(MinutesTemplate.all.first == .general)
        #expect(MinutesTemplate(key: "nope") == nil)
    }

    @Test func 长转写稿按contextTokens分段_每段都在预算内_切点落在句子边界() async throws {
        let long = longTranscript(count: 200, gapAfter: 120)
        let generator = ScriptedGenerator(contextTokens: 4000)
        generator.respond = echoingResponder

        _ = try await generate(generator, transcript: long)

        #expect(generator.extractionCalls.count >= 3)
        #expect(generator.mergeCalls.count >= 1)
        for call in generator.calls {
            #expect(call.maxTokens > 0)
            #expect(call.system.count + call.prompt.count + call.maxTokens <= 4000)
        }
        // 按顺序拼起来正好是完整的输入，每行都完整、只出现一次
        let expected = (1...200).flatMap { i -> [String] in
            let t = (i - 1) * 10 + (i > 120 ? 120 : 0)
            let line = String(format: "[s%d %02d:%02d] 这是第%d句话，大家讨论了项目的进度和下一步的安排", i, t / 60, t % 60, i)
            return i == 120 ? [line, "[合盖，未录到声音 20:00–22:00]"] : [line]
        }
        #expect(generator.extractionCalls.flatMap(transcriptLines) == expected)
    }

    /// 合并时出处只认合并输入里出现过的：转写稿里存在、但提取时没人引用过的句子也要丢掉
    @Test func 合并输出里没在合并输入中出现过的出处被丢弃() async throws {
        let long = longTranscript(count: 200)
        let generator = ScriptedGenerator(contextTokens: 4000)
        let allIDs = (1...200).map { #""s\#($0)""# }.joined(separator: ", ")
        generator.respond = { system, prompt in
            let lines = transcriptLines(in: prompt)
            if let first = lines.first {
                let id = first.dropFirst().prefix { $0 != " " }
                return #"{"decisions": [{"text": "\#(id) 开始的一段", "refs": ["\#(id)", "s999"]}]}"#
            }
            return #"""
            {"decisions": [{"text": "全场决议", "refs": [\#(allIDs)]}],
             "questions": [{"text": "编出来的问题", "refs": ["s999"]}]}
            """#
        }

        let minutes = try await generate(generator, transcript: long)

        let cited = generator.extractionCalls.map { prompt in
            Int(transcriptLines(in: prompt)[0].dropFirst(2).prefix { $0 != " " })!
        }
        #expect(cited.count >= 3)
        #expect(minutes.sections[1].items.map(\.refs) == [cited.prefix(maxRefs).map { MinutesRef(id: "s\($0)", start: Double($0 - 1) * 10) }])
        #expect(minutes.sections[3].items.map(\.isUnsourced) == [true])
        // 合并只给条目和出处，不给原文
        #expect(generator.mergeCalls.allSatisfy { !$0.contains("大家讨论了项目的进度") })
        #expect(generator.mergeCalls.allSatisfy { !$0.contains("s999") })
    }

    /// 合并输入的字段顺序固定（与输出格式示例一致），待办的负责人和截止时间一并带上
    @Test func 合并输入里的待办带负责人和截止时间_字段顺序固定() async throws {
        let generator = ScriptedGenerator(contextTokens: 4000)
        generator.respond = { system, prompt in
            if !transcriptLines(in: prompt).isEmpty {
                return #"{"actions": [{"text": "发报价单", "owner": "张三", "due": "下周三", "dueDate": "2026-11-18", "refs": ["s1"]}]}"#
            }
            return emptyOutput
        }

        _ = try await generate(generator, transcript: longTranscript(count: 200))

        let merge = try #require(generator.mergeCalls.first)
        #expect(merge.contains(#"{"text":"发报价单","owner":"张三","due":"下周三","dueDate":"2026-11-18","refs":["s1"]}"#))
    }

    /// 先不带空白跑一遍，看第一段装满时切在哪；再把合盖空白或长停顿放在切点前几句，第一段应该切在那里
    @Test(arguments: [true, false])
    func 优先在合盖空白或长停顿处切(gap: Bool) async throws {
        let plain = ScriptedGenerator(contextTokens: 4000)
        plain.respond = echoingResponder
        _ = try await generate(plain, transcript: longTranscript(count: 200))
        let full = transcriptLines(in: plain.extractionCalls[0]).count
        let cut = full - 5

        let generator = ScriptedGenerator(contextTokens: 4000)
        generator.respond = echoingResponder
        let transcript = gap ? longTranscript(count: 200, gapAfter: cut) : longTranscript(count: 200, pauseAfter: cut)
        _ = try await generate(generator, transcript: transcript)

        let first = transcriptLines(in: generator.extractionCalls[0])
        let second = transcriptLines(in: generator.extractionCalls[1])
        if gap {
            #expect(first.count == cut + 1)
            #expect(first.last?.hasPrefix("[合盖") == true)
        } else {
            #expect(first.count == cut)
        }
        #expect(second.first?.hasPrefix("[s\(cut + 1) ") == true)
    }

    /// 合并的输出和输入的条目差不多长（去重之后也少不了多少），输出预算要装得下输入的全部条目，
    /// 否则多轮合并时输出被截断，表现为“模型输出无法解析”
    @Test func 合并时留给输出的token不少于输入的条目() async throws {
        let generator = ScriptedGenerator(contextTokens: 6000)
        generator.respond = { system, prompt in
            if let first = transcriptLines(in: prompt).first(where: { $0.hasPrefix("[s") }) {
                let id = first.dropFirst().prefix { $0 != " " }
                let items = (0..<6).map { _ in #"{"text": "\#(id) 这一段里说定的一件事，要写得长一点", "refs": ["\#(id)"]}"# }
                return #"{"decisions": [\#(items.joined(separator: ", "))]}"#
            }
            let ids = prompt.matches(of: try! Regex(#""s\d+""#)).map { String(prompt[$0.range]) }
            return #"{"decisions": [{"text": "合并", "refs": [\#(ids.joined(separator: ", "))]}]}"#
        }

        _ = try await generate(generator, transcript: longTranscript(count: 300))

        let merges = generator.calls.filter { transcriptLines(in: $0.prompt).isEmpty }
        #expect(!merges.isEmpty)
        for call in merges {
            let entries = try #require(call.prompt.range(of: "各段提取的条目：\n"))
            #expect(call.maxTokens >= generator.countTokens(String(call.prompt[entries.upperBound...])))
        }
    }

    /// 各段条目加起来一次放不下时，分批多轮合并，每次调用都在预算内，出处仍只来自提取时引用过的句子
    @Test func 合并输入超出预算时分批多轮合并() async throws {
        let generator = ScriptedGenerator(contextTokens: 6000)
        generator.respond = { system, prompt in
            let lines = transcriptLines(in: prompt)
            if !lines.isEmpty {
                // 每段给 8 条长条目，几段加起来就超出一次合并的预算
                let items = lines.prefix(8).map { line in
                    let id = line.dropFirst().prefix { $0 != " " }
                    return #"{"text": "\#(id) 这一句提到的事情需要后续跟进，大家讨论了很久还没有最终的结论，下次会议之前各自再想一想有没有更好的办法", "refs": ["\#(id)"]}"#
                }
                return #"{"questions": [\#(items.joined(separator: ", "))]}"#
            }
            let ids = prompt.matches(of: try! Regex(#""s\d+""#)).map { String(prompt[$0.range]) }
            return #"{"questions": [{"text": "合并后的问题", "refs": [\#(ids.joined(separator: ", ")), "s200"]}]}"#
        }

        let minutes = try await generate(generator, transcript: longTranscript(count: 200))

        #expect(generator.mergeCalls.count >= 2)
        for call in generator.calls {
            #expect(call.system.count + call.prompt.count + call.maxTokens <= 6000)
        }
        let cited = Set(generator.extractionCalls.flatMap { transcriptLines(in: $0).prefix(8) }
            .map { String($0.dropFirst().prefix { $0 != " " }) })
        // 多轮合并收敛到一份，没有落进拼接的兜底
        #expect(minutes.sections[3].items.map(\.text) == ["合并后的问题"])
        let refs = minutes.sections[3].items.flatMap(\.refs)
        #expect(!refs.isEmpty)
        #expect(Set(refs.map(\.id)).isSubset(of: cited))
        #expect(!refs.map(\.id).contains("s200"))
    }

    /// 任意两段的条目加起来都放不下一次合并（ticket 04 实测的 1 小时密集稿就是这样）：不让整场失败，
    /// 各节直接拼接各段条目（文字、负责人、截止时间都相同的去重，出处取并集），概要单独做一次小合并
    @Test func 任意两段都凑不成一批合并时_直接拼接各段条目_概要单独合并() async throws {
        let generator = ScriptedGenerator(contextTokens: 6000)
        generator.respond = { system, prompt in
            if let output = bulkyExtraction(prompt) { return output }
            // 合并：把输入里的出处都放进一条概要，再加一个输入里没有的
            let ids = prompt.matches(of: try! Regex(#""s\d+""#)).map { String(prompt[$0.range]) }
            return #"{"overview": [{"text": "全场概要", "refs": [\#((ids + ["\"s200\""]).joined(separator: ", "))]}]}"#
        }

        let minutes = try await generate(generator, transcript: longTranscript(count: 200))

        for call in generator.calls {
            #expect(call.system.count + call.prompt.count + call.maxTokens <= 6000)
        }
        let cited = generator.extractionCalls.map { String(transcriptLines(in: $0)[0].dropFirst().prefix { $0 != " " }) }
        #expect(cited.count >= 3)
        // 只有一次合并，输入只有各段的概要
        #expect(generator.mergeCalls.count == 1)
        #expect(!generator.mergeCalls[0].contains("定下的"))
        #expect(!generator.mergeCalls[0].contains("补齐测试用例"))

        func ids(_ kind: MinutesSectionKind) -> [[String]] {
            minutes.sections.first { $0.kind == kind }!.items.map { $0.refs.map(\.id) }
        }
        #expect(minutes.sections[0].items.map(\.text) == ["全场概要"])
        #expect(ids(.overview) == [Array(cited.prefix(3))])

        let decisions = minutes.sections[1].items.map(\.text)
        let expected = cited.enumerated().flatMap { n, id in
            (1...20).map { "\(id) 这一段定下的第\($0)件事，大家讨论了很久，最后一致同意按这个方案执行" } + (n == 0 ? ["老版本客户端不再支持"] : [])
        }
        #expect(decisions == expected)
        let shared = try #require(minutes.sections[1].items.first { $0.text == "老版本客户端不再支持" })
        #expect(shared.refs.map(\.id) == Array(cited.prefix(3)))

        let actions = minutes.sections[2].items
        #expect(actions.map(\.text) == ["补齐测试用例"] + cited.map { _ in "确认交互稿" })
        #expect(actions.map(\.owner) == ["张三"] + cited.map { "\($0) 的人" })
        #expect(actions[0].refs.map(\.id) == Array(cited.prefix(3)))
        #expect(actions[0].due == "明天")
        #expect(minutes.sections.flatMap(\.items).allSatisfy { $0.refs.count <= 3 })
    }

    /// 兜底时概要的小合并不守“3–6 条”（ticket 11 实测给了 12 条）：代码里只留前 6 条。
    /// 小合并失败、改用各段概要拼接时同样只留 6 条，见 `分批合并重试后仍解析不出时_退回拼接各段条目`
    @Test func 兜底时概要小合并最多留6条() async throws {
        let generator = ScriptedGenerator(contextTokens: 6000)
        generator.respond = { system, prompt in
            if let output = bulkyExtraction(prompt) { return output }
            let id = prompt.matches(of: try! Regex(#""s\d+""#)).map { String(prompt[$0.range]) }[0]
            let items = (1...8).map { #"{"text": "概要\#($0)", "refs": [\#(id)]}"# }
            return #"{"overview": [\#(items.joined(separator: ", "))]}"#
        }

        let minutes = try await generate(generator, transcript: longTranscript(count: 200))

        #expect(generator.mergeCalls.count == 1)
        #expect(minutes.sections[0].items.map(\.text) == (1...6).map { "概要\($0)" })
    }

    /// 兜底时概要的小合并重试后仍解析不出：也不让整场失败，概要用各段的拼起来
    @Test func 兜底时概要合并解析失败_用各段概要拼接() async throws {
        let generator = ScriptedGenerator(contextTokens: 6000)
        generator.respond = { system, prompt in bulkyExtraction(prompt) ?? "抱歉，我无法完成。" }

        let minutes = try await generate(generator, transcript: longTranscript(count: 200))

        #expect(generator.mergeCalls.count == 2)
        let cited = generator.extractionCalls.map { String(transcriptLines(in: $0)[0].dropFirst().prefix { $0 != " " }) }
        #expect(minutes.sections[0].items.map(\.text) == cited.map { "\($0) 开始的一段" })
        #expect(minutes.sections[0].items.map { $0.refs.map(\.id) } == cited.map { [$0] })
        #expect(minutes.sections[1].items.count == cited.count * 20 + 1)
    }

    /// 合并的输出被截断（输出侧的放不下）表现为解析失败。各段的条目已经提取好了，
    /// 重试一次仍解析不出时退回拼接，不让整场失败
    @Test func 分批合并重试后仍解析不出时_退回拼接各段条目() async throws {
        let generator = ScriptedGenerator(contextTokens: 4000)
        generator.respond = { system, prompt in
            if let first = transcriptLines(in: prompt).first(where: { $0.hasPrefix("[s") }) {
                let id = first.dropFirst().prefix { $0 != " " }
                return #"{"overview": [{"text": "\#(id) 开始的一段", "refs": ["\#(id)"]}], "decisions": [{"text": "\#(id) 定下的事", "refs": ["\#(id)"]}]}"#
            }
            // 合并的输出到上限被截断
            return #"{"overview": [{"text": "全场概要", "refs": ["s1", "s21", "s41", "#
        }

        let minutes = try await generate(generator, transcript: longTranscript(count: 200))

        let cited = generator.extractionCalls.map { String(transcriptLines(in: $0)[0].dropFirst().prefix { $0 != " " }) }
        #expect(cited.count >= 3)
        // 第一批合并试两次，概要的小合并再试两次
        #expect(generator.mergeCalls.count == 4)
        // 概要用各段的拼接，最多留 6 条
        #expect(cited.count > 6)
        #expect(minutes.sections[0].items.map(\.text) == cited.prefix(6).map { "\($0) 开始的一段" })
        #expect(minutes.sections[1].items.map(\.text) == cited.map { "\($0) 定下的事" })
    }

    /// 每次调用都带上约束输出形状的文法：提取和合并是模板的全部节，兜底时概要的小合并只有概要
    @Test func 每次调用都带输出文法_列出该次要的节() async throws {
        let generator = ScriptedGenerator(contextTokens: 6000)
        generator.respond = { system, prompt in bulkyExtraction(prompt) ?? #"{"overview": []}"# }

        _ = try await generate(generator, transcript: longTranscript(count: 200), template: .customer)

        #expect(generator.grammars.count == generator.calls.count)
        let keys = ["overview", "decisions", "actions", "questions", "requests", "commitments"]
        for (call, grammar) in zip(generator.calls, generator.grammars) {
            let grammar = try #require(grammar)
            let expected = transcriptLines(in: call.prompt).isEmpty ? ["overview"] : keys
            #expect(keys.filter { grammar.contains(#"\"\#($0)\""#) } == expected)
        }
    }

    @Test func 二分找放得下的最多条目_先试上限() {
        var tried: [Int] = []
        #expect(largestFitting(1, 100) { tried.append($0); return $0 <= 37 } == 37)
        #expect(tried.first == 100)
        #expect(tried.count <= 8)
        #expect(largestFitting(1, 10) { _ in true } == 10)
        #expect(largestFitting(1, 10) { _ in false } == nil)
        #expect(largestFitting(5, 4) { _ in true } == nil)
    }

    @Test func 倍增试探再二分_结果小时不必先试上限() {
        var tried: [Int] = []
        #expect(largestFittingGrowing(2, 1000) { tried.append($0); return $0 <= 5 } == 5)
        #expect(tried.max()! < 20)
        for limit in [2, 3, 4, 7, 8, 9, 37, 99, 100] {
            #expect(largestFittingGrowing(2, 100) { $0 <= limit } == limit)
        }
        #expect(largestFittingGrowing(2, 100) { _ in false } == nil)
        #expect(largestFittingGrowing(3, 2) { _ in true } == nil)
    }

    @Test func 连一句都放不下时抛错() async throws {
        let generator = ScriptedGenerator(contextTokens: 200, outputs: [emptyOutput])

        await #expect(throws: MinutesGenerationError.contextTooSmall) { try await generate(generator) }
        #expect(generator.calls.isEmpty)
    }

    @Test func 进度按完成的段数加合并计() async throws {
        let generator = ScriptedGenerator(contextTokens: 4000)
        generator.respond = echoingResponder
        var reported: [Double] = []

        _ = try await generate(generator, transcript: longTranscript(count: 200)) { reported.append($0) }

        let n = generator.extractionCalls.count
        #expect(n >= 3)
        #expect(reported == (1...n).map { Double($0) / Double(n + 1) } + [1])
    }

    @Test func 只有一段时进度直接到1() async throws {
        var reported: [Double] = []
        _ = try await generate(ScriptedGenerator(outputs: [emptyOutput])) { reported.append($0) }
        #expect(reported == [1])
    }

    @Test func 只有一段时跳过合并() async throws {
        let generator = ScriptedGenerator()
        generator.respond = echoingResponder

        _ = try await generate(generator, transcript: longTranscript(count: 20))

        #expect(generator.calls.count == 1)
    }

    @Test func 解析容忍代码块包裹和前后多余文字() async throws {
        let generator = ScriptedGenerator(outputs: [#"""
        好的，下面是纪要：
        ```json
        {"overview": [], "decisions": [{"text": "推迟一周发布", "refs": ["s4"]}], "actions": [], "questions": []}
        ```
        以上内容仅供参考。
        """#])

        let minutes = try await generate(generator)

        #expect(minutes.sections.first { $0.kind == .decisions }?.items.map(\.text) == ["推迟一周发布"])
    }

    @Test func 解析失败时用同一段输入重试一次() async throws {
        let generator = ScriptedGenerator(outputs: ["抱歉，我无法完成。", #"{"decisions": [{"text": "推迟一周发布", "refs": ["s4"]}]}"#])

        let minutes = try await generate(generator)

        #expect(generator.calls.count == 2)
        #expect(generator.calls[0].prompt == generator.calls[1].prompt)
        #expect(generator.calls[0].system == generator.calls[1].system)
        #expect(minutes.sections.first { $0.kind == .decisions }?.items.map(\.text) == ["推迟一周发布"])
    }

    /// 没有一个预期的节，如多包了一层，不能当成各节为空，悄悄产出一份空纪要
    @Test(arguments: ["这次会议没有什么内容", #"{"error": "context too long"}"#,
                      #"{"minutes": {"overview": []}}"#, #"{"overview": [ "#])
    func 两次都解析失败时抛错_模型输出无法解析(bad: String) async throws {
        let generator = ScriptedGenerator(outputs: [bad, bad])

        let error = await #expect(throws: MinutesGenerationError.unparseableOutput) { try await generate(generator) }

        #expect(error?.localizedDescription == "模型输出无法解析")
        #expect(generator.calls.count == 2)
    }

    /// 引擎报错（含取消）不是解析失败，不重试
    @Test func 引擎报错原样抛出_不重试() async throws {
        let generator = ScriptedGenerator(outputs: [])
        generator.error = CancellationError()

        await #expect(throws: CancellationError.self) { try await generate(generator) }
        #expect(generator.calls.count == 1)
    }
}

/// 提取时每段给很多条长条目，任意两段加起来都放不下一次合并（contextTokens 6000 时）。
/// 每段都有一条文字相同的决议和一条负责人、截止时间都相同的待办。不是提取调用时返回 nil
private func bulkyExtraction(_ prompt: String) -> String? {
    guard let first = transcriptLines(in: prompt).first(where: { $0.hasPrefix("[s") }) else { return nil }
    let id = first.dropFirst().prefix { $0 != " " }
    let decisions = (1...20).map { k in
        #"{"text": "\#(id) 这一段定下的第\#(k)件事，大家讨论了很久，最后一致同意按这个方案执行", "refs": ["\#(id)"]}"#
    } + [#"{"text": "老版本客户端不再支持", "refs": ["\#(id)"]}"#]
    return #"""
    {"overview": [{"text": "\#(id) 开始的一段", "refs": ["\#(id)"]}],
     "decisions": [\#(decisions.joined(separator: ", "))],
     "actions": [{"text": "补齐测试用例", "owner": "张三", "due": "明天", "refs": ["\#(id)"]},
                 {"text": "确认交互稿", "owner": "\#(id) 的人", "refs": ["\#(id)"]}]}
    """#
}

private let emptyOutput = #"{"overview": [], "decisions": [], "actions": [], "questions": []}"#
