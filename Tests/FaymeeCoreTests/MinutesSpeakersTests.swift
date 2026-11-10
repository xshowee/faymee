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
