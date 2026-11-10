import Foundation
import Testing
@testable import FaymeeCore

private func date(_ iso: String) -> Date {
    try! Date(iso, strategy: .iso8601)
}

private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
private let speakersCreatedAt = date("2026-11-10T03:02:00Z")

private func speaker(_ id: String, _ name: String? = nil) -> Speaker {
    Speaker(id: id, name: name, nameSource: name == nil ? nil : .user, voiceprint: Voiceprint([1]), speechDuration: 30)
}

/// 每句写成 (说话人 id, 文字)，句子 id 依次为 s1、s2…，每句 10 秒
private func transcript(_ lines: [(String?, String)], speakers: [Speaker]?,
                        speakersCreatedAt: Date = speakersCreatedAt) -> Transcript {
    Transcript(engine: "apple/speechanalyzer", createdAt: date("2026-11-10T03:01:00Z"), hotwords: [],
               items: lines.enumerated().map { i, line in
                   .sentence(TranscriptSentence(id: "s\(i + 1)", start: Double(i * 10), end: Double(i * 10 + 8),
                                                text: line.1, speaker: line.0))
               },
               diarization: speakers.map {
                   Diarization(engine: "fake-diarizer/1", voiceprintModel: "fake-embedding/1",
                               speakersCreatedAt: speakersCreatedAt, speakers: $0)
               })
}

/// 王总（spk2）被叫了名字，张三（spk3）已命名
private let meeting = transcript([
    ("spk1", "王总你怎么看这个方案"),
    ("spk2", "我觉得可以，下周三之前我把报价单发给客户"),
    ("spk3", "那我来整理会议纪要"),
    (nil, "嗯"),
], speakers: [speaker("spk1"), speaker("spk2"), speaker("spk3", "张三")])

private func generate(_ generator: ScriptedGenerator, transcript: Transcript = meeting) async throws -> Minutes {
    try await generateMinutes(
        transcript: transcript, title: "客户沟通", startedAt: date("2026-11-10T02:00:00Z"),
        template: .general, generator: generator, model: "fake/scripted",
        createdAt: date("2026-11-10T03:05:00Z"), timeZone: shanghai)
}

private let emptyOutput = #"{"overview": [], "decisions": [], "actions": [], "questions": []}"#

@Suite struct MinutesSpeakersTests {
    @Test func 输入行带说话人显示名_已命名的用名字_未知的不带() async throws {
        let generator = ScriptedGenerator(outputs: [emptyOutput])

        _ = try await generate(generator)

        #expect(transcriptLines(in: generator.calls[0].prompt) == [
            "[s1 00:00 说话人 1] 王总你怎么看这个方案",
            "[s2 00:10 说话人 2] 我觉得可以，下周三之前我把报价单发给客户",
            "[s3 00:20 张三] 那我来整理会议纪要",
            "[s4 00:30] 嗯",
        ])
    }

    @Test(arguments: [true, false])
    func 只有一个说话人或没区分时不带说话人_提示词与没有说话人时相同(diarized: Bool) async throws {
        let lines: [(String?, String)] = [("spk1", "我们今天讨论发布时间"), (nil, "嗯"), ("spk1", "那就推迟一周")]
        let single = transcript(lines, speakers: diarized ? [speaker("spk1"), speaker("spk2")] : nil)
        let plain = transcript(lines.map { (nil, $0.1) }, speakers: nil)
        let a = ScriptedGenerator(outputs: [emptyOutput])
        let b = ScriptedGenerator(outputs: [emptyOutput])

        _ = try await generate(a, transcript: single)
        _ = try await generate(b, transcript: plain)

        #expect(transcriptLines(in: a.calls[0].prompt) == ["[s1 00:00] 我们今天讨论发布时间", "[s2 00:10] 嗯",
                                                             "[s3 00:20] 那就推迟一周"])
        #expect(a.calls[0].system == b.calls[0].system)
        #expect(a.calls[0].prompt == b.calls[0].prompt)
        #expect(a.grammars == b.grammars)
    }

    @Test func 负责人与说话人的标签相同时记下说话人id_其他不关联() async throws {
        let generator = ScriptedGenerator(outputs: [#"""
        {"overview": [], "decisions": [],
         "actions": [{"text": "把报价单发给客户", "owner": "说话人 2", "due": "下周三", "dueDate": null, "refs": ["s2"]},
                     {"text": "整理会议纪要", "owner": "张三", "due": null, "dueDate": null, "refs": ["s3"]},
                     {"text": "确认预算", "owner": "说话人2", "due": null, "dueDate": null, "refs": ["s1"]},
                     {"text": "约下次会议", "owner": "李四", "due": null, "dueDate": null, "refs": ["s1"]},
                     {"text": "跟进合同", "owner": "未知", "due": null, "dueDate": null, "refs": ["s4"]},
                     {"text": "准备材料", "owner": null, "due": null, "dueDate": null, "refs": ["s1"]}],
         "questions": []}
        """#])

        let minutes = try await generate(generator)

        let actions = try #require(minutes.sections.first { $0.kind == .actions }).items
        #expect(actions.map(\.owner) == ["说话人 2", "张三", "说话人2", "李四", "未知", nil])
        #expect(actions.map(\.ownerSpeaker) == ["spk2", "spk3", "spk2", nil, nil, nil])
    }

    @Test func 没区分说话人时负责人不关联() async throws {
        let plain = transcript([(nil, "说话人 2 你把报价单发给客户")], speakers: nil)
        let generator = ScriptedGenerator(outputs: [#"""
        {"actions": [{"text": "把报价单发给客户", "owner": "说话人 2", "due": null, "dueDate": null, "refs": ["s1"]}]}
        """#])

        let minutes = try await generate(generator, transcript: plain)

        #expect(minutes.sections.first { $0.kind == .actions }?.items.map(\.ownerSpeaker) == [nil])
        #expect(minutes.source.speakersCreatedAt == nil)
    }

    @Test func source记下快照的speakersCreatedAt() async throws {
        let minutes = try await generate(ScriptedGenerator(outputs: [emptyOutput]))

        #expect(minutes.source.speakersCreatedAt == speakersCreatedAt)
    }

    @Test func 姓名建议记下说话人id名字和出处() async throws {
        let generator = ScriptedGenerator(outputs: [#"""
        {"overview": [], "decisions": [], "actions": [], "questions": [],
         "speakers": [{"speaker": "说话人 2", "name": "王总", "refs": ["s1"]}]}
        """#])

        let minutes = try await generate(generator)

        #expect(minutes.nameSuggestions == [NameSuggestion(speaker: "spk2", name: "王总",
                                                           refs: [MinutesRef(id: "s1", start: 0)])])
    }

    /// 防止模型编造：出处原句里没有这个名字、标签不是输入里的未命名说话人、出处都不存在的建议丢弃
    @Test func 姓名建议_出处原句不含名字_标签不存在_已命名_出处不存在的都丢弃() async throws {
        let generator = ScriptedGenerator(outputs: [#"""
        {"overview": [], "decisions": [], "actions": [], "questions": [],
         "speakers": [{"speaker": "说话人 1", "name": "李总", "refs": ["s1", "s2"]},
                      {"speaker": "说话人 9", "name": "王总", "refs": ["s1"]},
                      {"speaker": "张三", "name": "王总", "refs": ["s1"]},
                      {"speaker": "未知", "name": "王总", "refs": ["s1"]},
                      {"speaker": "说话人 2", "name": "王总", "refs": ["s99"]},
                      {"speaker": "说话人 2", "name": " ", "refs": ["s1"]}]}
        """#])

        let minutes = try await generate(generator)

        #expect(minutes.nameSuggestions.isEmpty)
    }

    /// 出处里有一处含名字就算数；存下的出处把含名字的排在前面
    @Test func 姓名建议至少一处出处含名字即可_含名字的出处排前面() async throws {
        let generator = ScriptedGenerator(outputs: [#"""
        {"overview": [], "decisions": [], "actions": [], "questions": [],
         "speakers": [{"speaker": "说话人 2", "name": "王总", "refs": ["s2", "s99", "s1"]}]}
        """#])

        let minutes = try await generate(generator)

        #expect(minutes.nameSuggestions.map(\.refs) == [[MinutesRef(id: "s1", start: 0), MinutesRef(id: "s2", start: 10)]])
    }
}

/// 60 句，单数句说话人 1、双数句说话人 2（都没命名），每句都提到几个称呼
private let longMeeting = transcript((1...60).map { i in
    (i % 2 == 1 ? "spk1" : "spk2", "第\(i)句：王总、李总、张经理、赵总都在，大家讨论了项目的进度和下一步的安排")
}, speakers: [speaker("spk1"), speaker("spk2")])

private func sentenceIDs(in prompt: String) -> Set<String> {
    Set(transcriptLines(in: prompt).compactMap { line in
        line.hasPrefix("[s") ? String(line.dropFirst().prefix { $0 != " " }) : nil
    })
}

extension MinutesSpeakersTests {
    /// 说话人 2：一段说王总（2 处出处），另一段说李总（1 处）→ 王总。
    /// 说话人 1：张经理、赵总各 1 处 → 平票丢弃
    @Test func 多段的姓名建议按出处数投票_平票丢弃() async throws {
        let generator = ScriptedGenerator(contextTokens: 5000)
        generator.respond = { _, prompt in
            let ids = sentenceIDs(in: prompt)
            guard !ids.isEmpty else { return #"{"overview": []}"# }
            var guesses: [String] = []
            if ids.contains("s5") && ids.contains("s7") {
                guesses.append(#"{"speaker": "说话人 2", "name": "王总", "refs": ["s5", "s7"]}"#)
            }
            if ids.contains("s1") { guesses.append(#"{"speaker": "说话人 1", "name": "张经理", "refs": ["s1"]}"#) }
            if ids.contains("s59") { guesses.append(#"{"speaker": "说话人 1", "name": "赵总", "refs": ["s59"]}"#) }
            if ids.contains("s60") { guesses.append(#"{"speaker": "说话人 2", "name": "李总", "refs": ["s60"]}"#) }
            return #"{"overview": [], "speakers": [\#(guesses.joined(separator: ", "))]}"#
        }

        let minutes = try await generate(generator, transcript: longMeeting)

        let first = try #require(generator.extractionCalls.first)
        #expect(sentenceIDs(in: first).isSuperset(of: ["s1", "s5", "s7"]))
        #expect(!sentenceIDs(in: first).contains("s59"))
        #expect(minutes.nameSuggestions == [NameSuggestion(speaker: "spk2", name: "王总",
                                                           refs: [MinutesRef(id: "s5", start: 40),
                                                                  MinutesRef(id: "s7", start: 60)])])
    }

    /// 同一个名字在几段里的出处合起来计票：王总 1 + 1 处胜过一段里的李总 1 处
    @Test func 同一名字各段的出处合起来计票() async throws {
        let generator = ScriptedGenerator(contextTokens: 5000)
        generator.respond = { _, prompt in
            let ids = sentenceIDs(in: prompt)
            guard !ids.isEmpty else { return #"{"overview": []}"# }
            var guesses: [String] = []
            if ids.contains("s2") { guesses.append(#"{"speaker": "说话人 2", "name": "王总", "refs": ["s2"]}"#) }
            if ids.contains("s4") { guesses.append(#"{"speaker": "说话人 2", "name": "李总", "refs": ["s4"]}"#) }
            if ids.contains("s60") { guesses.append(#"{"speaker": "说话人 2", "name": "王总", "refs": ["s60"]}"#) }
            return #"{"overview": [], "speakers": [\#(guesses.joined(separator: ", "))]}"#
        }

        let minutes = try await generate(generator, transcript: longMeeting)

        #expect(generator.extractionCalls.count >= 2)
        #expect(minutes.nameSuggestions.map(\.name) == ["王总"])
        #expect(minutes.nameSuggestions.first?.refs.map(\.id) == ["s2", "s60"])
    }

    /// 只有提取调用要说话人身份，文法只允许输入里未命名说话人的标签；合并调用不变
    @Test func 提取的文法带说话人身份_只允许未命名说话人的标签_合并的不带() async throws {
        let generator = ScriptedGenerator(contextTokens: 5000)
        generator.respond = { _, prompt in sentenceIDs(in: prompt).isEmpty ? #"{"overview": []}"# : emptyOutput }

        _ = try await generate(generator, transcript: longMeeting)

        #expect(generator.mergeCalls.count >= 1)
        for (call, grammar) in zip(generator.calls, generator.grammars) {
            let grammar = try #require(grammar)
            let isExtraction = !sentenceIDs(in: call.prompt).isEmpty
            #expect(grammar.contains(#""\"speakers\":""#) == isExtraction)
            #expect(grammar.contains(#"label ::= "\"说话人 1\"" | "\"说话人 2\"""#) == isExtraction)
        }
    }

    @Test func 说话人都已命名时不要说话人身份() async throws {
        let named = transcript([("spk1", "王总你怎么看"), ("spk2", "可以")],
                               speakers: [speaker("spk1", "李四"), speaker("spk2", "王五")])
        let generator = ScriptedGenerator(outputs: [emptyOutput])

        _ = try await generate(generator, transcript: named)

        #expect(transcriptLines(in: generator.calls[0].prompt) == ["[s1 00:00 李四] 王总你怎么看", "[s2 00:10 王五] 可以"])
        #expect(generator.grammars[0]?.contains("speakers") == false)
        #expect(!generator.calls[0].system.contains("speakers"))
    }
}

/// 生成时的纪要：待办 a1 关联说话人 2，a2 只有文字；说话人 2 有姓名建议“王总”
private func generatedMinutes(speakersCreatedAt: Date? = speakersCreatedAt) -> Minutes {
    Minutes(model: "fake/scripted", template: "general", createdAt: date("2026-11-10T03:05:00Z"),
            source: MinutesSource(transcriptCreatedAt: date("2026-11-10T03:01:00Z"), textHash: meeting.textHash,
                                  speakersCreatedAt: speakersCreatedAt),
            sections: [MinutesSection(kind: .actions, title: "待办", items: [
                MinutesItem(id: "a1", text: "把报价单发给客户", owner: "说话人 2", ownerSpeaker: "spk2",
                            refs: [MinutesRef(id: "s2", start: 10)]),
                MinutesItem(id: "a2", text: "整理会议纪要", owner: "张三", refs: [MinutesRef(id: "s3", start: 20)]),
            ])],
            nameSuggestions: [NameSuggestion(speaker: "spk2", name: "王总", refs: [MinutesRef(id: "s1", start: 0)])])
}

/// 当前转写稿：说话人 2 改名为 `name`（nil 为没改），说话人完成时间为 `at`
private func current(spk2 name: String?, at: Date = speakersCreatedAt) -> Transcript {
    var t = meeting
    t.diarization?.speakersCreatedAt = at
    t.diarization?.speakers[1].name = name
    return t
}

@Suite struct MinutesSpeakerDisplayTests {
    private func owners(_ m: Minutes, _ t: Transcript?) -> [String?] {
        m.sections[0].items.map { m.displayedOwner(of: $0, transcript: t) }
    }

    @Test func 关联有效时负责人显示说话人当前的名字() {
        #expect(owners(generatedMinutes(), current(spk2: "王总")) == ["王总", "张三"])
        #expect(owners(generatedMinutes(), current(spk2: nil)) == ["说话人 2", "张三"])
    }

    /// 写盘丢掉小数秒：内存里的转写稿与读回的差不到 1 秒仍算同一次区分
    @Test func 说话人完成时间差不到1秒仍算同一次区分() {
        let t = current(spk2: "王总", at: speakersCreatedAt.addingTimeInterval(0.6))
        #expect(owners(generatedMinutes(), t) == ["王总", "张三"])
    }

    @Test func 重新区分过_转写稿不可用_说话人已不在时负责人显示生成时的文字() {
        let later = current(spk2: "王总", at: speakersCreatedAt.addingTimeInterval(60))
        #expect(owners(generatedMinutes(), later) == ["说话人 2", "张三"])
        #expect(owners(generatedMinutes(), nil) == ["说话人 2", "张三"])
        var merged = current(spk2: "王总")
        merged.diarization?.speakers.remove(at: 1)
        #expect(owners(generatedMinutes(), merged) == ["说话人 2", "张三"])
    }

    @Test func 生成时没区分过说话人_负责人显示生成时的文字() {
        #expect(owners(generatedMinutes(speakersCreatedAt: nil), current(spk2: "王总")) == ["说话人 2", "张三"])
    }

    @Test func 姓名建议在说话人未命名且对应同一次区分时显示() {
        let m = generatedMinutes()
        #expect(m.visibleNameSuggestions(transcript: current(spk2: nil)).map(\.name) == ["王总"])
        #expect(m.visibleNameSuggestions(transcript: current(spk2: "  ")).map(\.name) == ["王总"])
    }

    @Test func 姓名建议在重新区分过_说话人已命名_已忽略_说话人不在时不显示() {
        let m = generatedMinutes()
        #expect(m.visibleNameSuggestions(transcript: current(spk2: nil, at: speakersCreatedAt.addingTimeInterval(60))).isEmpty)
        #expect(m.visibleNameSuggestions(transcript: current(spk2: "李四")).isEmpty)
        #expect(m.visibleNameSuggestions(transcript: nil).isEmpty)
        var merged = current(spk2: nil)
        merged.diarization?.speakers.remove(at: 1)
        #expect(m.visibleNameSuggestions(transcript: merged).isEmpty)

        var ignored = m
        let changed = ignored.ignoreNameSuggestion(speaker: "spk2", name: "王总")
        #expect(changed)
        #expect(ignored.nameSuggestions.map(\.ignored) == [true])
        #expect(ignored.visibleNameSuggestions(transcript: current(spk2: nil)).isEmpty)
    }

    @Test func 忽略不存在或已忽略的建议没有变化_不算人工修改() {
        var m = generatedMinutes()
        let results = [m.ignoreNameSuggestion(speaker: "spk2", name: "李总"),
                       m.ignoreNameSuggestion(speaker: "spk1", name: "王总"),
                       m.ignoreNameSuggestion(speaker: "spk2", name: "王总"),
                       m.ignoreNameSuggestion(speaker: "spk2", name: "王总")]
        #expect(results == [false, false, true, false])
        #expect(m.editCount == 0)
    }
}

/// 说话人列表、段首上的姓名建议：按说话人查，出处解析成可点的时间（同纪要条目的出处）
@Suite struct NameSuggestionPromptTests {
    @Test func 按说话人给出要显示的建议_出处是当前的原句() {
        var t = current(spk2: nil)
        t.edit(sentence: "s1", to: "王总，你怎么看这个方案")

        let prompts = generatedMinutes().nameSuggestionPrompts(transcript: t)

        #expect(prompts == ["spk2": NameSuggestionPrompt(speaker: "spk2", name: "王总", refs: [
            MinutesRefChip(label: "00:00", hint: "王总，你怎么看这个方案",
                           target: MinutesRefTarget(time: 0, sentenceID: "s1", quote: "王总，你怎么看这个方案")),
        ])])
    }

    @Test func 不显示的建议不给() {
        let m = generatedMinutes()
        #expect(m.nameSuggestionPrompts(transcript: current(spk2: "李四")).isEmpty)
        #expect(m.nameSuggestionPrompts(transcript: nil).isEmpty)
        #expect(m.nameSuggestionPrompts(transcript: current(spk2: nil, at: speakersCreatedAt + 60)).isEmpty)
    }
}

/// 重新生成时继承忽略：旧纪要里被忽略的建议，新纪要里同一说话人同一名字也是忽略
@Suite struct NameSuggestionInheritanceTests {
    private func regenerated(_ suggestions: [NameSuggestion], at: Date? = speakersCreatedAt) -> Minutes {
        var m = generatedMinutes(speakersCreatedAt: at)
        m.nameSuggestions = suggestions
        return m
    }

    private func ignored(_ speaker: String, _ name: String) -> NameSuggestion {
        NameSuggestion(speaker: speaker, name: name, refs: [MinutesRef(id: "s1", start: 0)], ignored: true)
    }

    private func fresh(_ speaker: String, _ name: String) -> NameSuggestion {
        NameSuggestion(speaker: speaker, name: name, refs: [MinutesRef(id: "s2", start: 10)])
    }

    @Test func 同一说话人同一名字再次出现时仍是忽略_其他照常() {
        var m = regenerated([fresh("spk1", "李总"), fresh("spk2", "王总")])
        m.inheritIgnoredNameSuggestions(from: regenerated([ignored("spk2", "王总"), fresh("spk1", "李总")]))

        #expect(m.nameSuggestions.map(\.ignored) == [false, true])
        #expect(m.visibleNameSuggestions(transcript: current(spk2: nil)).map(\.name) == ["李总"])
    }

    /// 这次模型没再给出的也留着，免得再下一次生成又冒出来
    @Test func 这次没出现的忽略记录也带过来() {
        var m = regenerated([fresh("spk2", "李总")])
        m.inheritIgnoredNameSuggestions(from: regenerated([ignored("spk2", "王总")]))

        #expect(m.nameSuggestions == [fresh("spk2", "李总"), ignored("spk2", "王总")])

        var again = regenerated([fresh("spk2", "王总")])
        again.inheritIgnoredNameSuggestions(from: m)
        #expect(again.nameSuggestions == [ignored("spk2", "王总").with(refs: fresh("spk2", "王总").refs)])
        #expect(again.visibleNameSuggestions(transcript: current(spk2: nil)).isEmpty)
    }

    /// 重新区分过：说话人编号已重排，旧的忽略不再对应同一个人
    @Test func 重新区分过或旧纪要没区分过时不继承() {
        var m = regenerated([fresh("spk2", "王总")])
        m.inheritIgnoredNameSuggestions(from: regenerated([ignored("spk2", "王总")],
                                                          at: speakersCreatedAt.addingTimeInterval(-600)))
        #expect(m.nameSuggestions == [fresh("spk2", "王总")])

        m.inheritIgnoredNameSuggestions(from: regenerated([ignored("spk2", "王总")], at: nil))
        m.inheritIgnoredNameSuggestions(from: nil)
        #expect(m.nameSuggestions == [fresh("spk2", "王总")])
    }
}

private extension NameSuggestion {
    func with(refs: [MinutesRef]) -> NameSuggestion {
        var s = self
        s.refs = refs
        return s
    }
}

/// 改纪要时负责人与说话人关联：界面按显示出来的负责人预填，原样保存不算改负责人
@Suite struct MinutesOwnerEditingTests {
    private let renamed = current(spk2: "王总")

    private func a1(_ m: Minutes) -> MinutesItem { m.sections[0].items[0] }

    @Test func 只改文字时保留关联() {
        var m = generatedMinutes()
        let changed = m.edit(item: "a1", text: "把新报价单发给客户", owner: "王总", transcript: renamed)

        #expect(changed)
        #expect(a1(m).owner == "说话人 2")
        #expect(a1(m).ownerSpeaker == "spk2")
        #expect(m.displayedOwner(of: a1(m), transcript: renamed) == "王总")
        #expect(m.editCount == 1)
    }

    @Test func 原样保存显示出来的负责人不算修改() {
        var m = generatedMinutes()
        let changed = m.edit(item: "a1", text: "把报价单发给客户", owner: "王总", transcript: renamed)

        #expect(!changed)
        #expect(m == generatedMinutes())
    }

    @Test func 手动修改负责人后清掉关联_不再跟着改名() {
        var m = generatedMinutes()
        m.edit(item: "a1", text: "把报价单发给客户", owner: "李四", transcript: renamed)

        #expect(a1(m).owner == "李四")
        #expect(a1(m).ownerSpeaker == nil)
        #expect(m.displayedOwner(of: a1(m), transcript: current(spk2: "王五")) == "李四")
        #expect(a1(m).original == MinutesItem.Original(text: "把报价单发给客户", owner: "说话人 2", ownerSpeaker: "spk2"))
    }

    @Test func 清空负责人也清掉关联() {
        var m = generatedMinutes()
        m.edit(item: "a1", text: "把报价单发给客户", owner: nil, transcript: renamed)

        #expect(a1(m).owner == nil)
        #expect(a1(m).ownerSpeaker == nil)
    }

    @Test func 恢复原文时关联也恢复() {
        var m = generatedMinutes()
        m.edit(item: "a1", text: "把报价单发给客户", owner: "李四", transcript: renamed)
        m.restore(item: "a1")

        #expect(m == generatedMinutes())
        #expect(m.displayedOwner(of: a1(m), transcript: renamed) == "王总")
    }

    /// 改回模型原文等于恢复原文：负责人改回显示出来的名字时关联回来
    @Test func 负责人改回原来显示的名字等于恢复原文() {
        var m = generatedMinutes()
        m.edit(item: "a1", text: "把报价单发给客户", owner: "李四", transcript: renamed)
        m.edit(item: "a1", text: "把报价单发给客户", owner: "王总", transcript: renamed)

        #expect(m == generatedMinutes())
        #expect(m.editCount == 0)
    }

    /// 已修改标记里的“原文负责人”：和恢复原文后显示的一样
    @Test func 原文的负责人关联有效时显示说话人当前的名字() {
        var m = generatedMinutes()
        m.edit(item: "a1", text: "把报价单发给客户", owner: "李四", transcript: renamed)
        let original = try! #require(a1(m).original)

        #expect(m.displayedOwner(of: original, transcript: renamed) == "王总")
        #expect(m.displayedOwner(of: original, transcript: nil) == "说话人 2")
        #expect(m.displayedOwner(of: original, transcript: current(spk2: "王总", at: speakersCreatedAt + 60))
            == "说话人 2")
    }

    /// 不给转写稿时只认存下的文字
    @Test func 不给转写稿时按生成时的文字比较() {
        var m = generatedMinutes()
        m.edit(item: "a1", text: "把新报价单发给客户", owner: "说话人 2")
        #expect(a1(m).ownerSpeaker == "spk2")

        m.edit(item: "a1", text: "把新报价单发给客户", owner: "王总")
        #expect(a1(m).owner == "王总")
        #expect(a1(m).ownerSpeaker == nil)
    }
}
