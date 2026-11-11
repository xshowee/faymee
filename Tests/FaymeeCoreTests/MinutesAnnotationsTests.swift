import Foundation
import Testing
@testable import FaymeeCore

/// 有会中标注时的纪要生成（spec「测试决定 › 主切入点：纪要生成」）

private let t0 = try! Date("2026-11-10T02:00:00Z", strategy: .iso8601)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

/// s1…sN，第 i 句从 (i-1)*10 秒开始、长 8 秒
private func sentences(_ count: Int, speaker: (Int) -> String? = { _ in nil }) -> [TranscriptItem] {
    (1...count).map { i in
        .sentence(TranscriptSentence(id: "s\(i)", start: Double(i - 1) * 10, end: Double(i - 1) * 10 + 8,
                                     text: "第\(i)句，大家讨论了项目的进度和下一步的安排", speaker: speaker(i)))
    }
}

/// 一场 3600 秒的会议，30 句（0–298 秒），之后没人说话
private let transcript = Transcript(engine: "fake/1", createdAt: at(3700), hotwords: [], items: sentences(30))

private func meeting(_ annotations: [Annotation], total: TimeInterval = 3600) -> Meeting {
    Meeting(id: "m1", title: "产品周会", startedAt: t0, endedAt: at(total), status: .done,
            segments: [Segment(file: "0001.caf", startedAt: t0, sampleRate: 48000, channels: 1,
                               device: "MacBook Pro 麦克风", deviceUID: "BuiltIn", offset: 0, duration: total)],
            recording: "recording.m4a", duration: total, annotations: annotations)
}

private func mark(_ id: String, _ seconds: TimeInterval) -> Annotation {
    Annotation(id: id, at: at(seconds), kind: .mark)
}

private func note(_ id: String, _ seconds: TimeInterval, _ text: String) -> Annotation {
    Annotation(id: id, at: at(seconds), kind: .note, text: text)
}

private func isMarkExpansion(_ system: String) -> Bool { system.contains("标记了一段重点") }
private func isNoteExpansion(_ system: String) -> Bool { system.contains("随手记了一条笔记") }
private func isExpansion(_ system: String) -> Bool { isMarkExpansion(system) || isNoteExpansion(system) }

private let emptyOutput = #"{"overview": [], "decisions": [], "actions": [], "questions": []}"#
private let oneOverview = #"{"overview": [{"text": "讨论了进度", "refs": ["s1"]}]}"#

/// 提取时给一条概要；展开时用 `expand` 按提示词里的句子编号现算
private func responder(expand: @escaping (_ system: String, _ ids: [String]) -> String)
    -> (String, String) -> String {
    { system, prompt in
        guard isExpansion(system) else { return oneOverview }
        let ids = transcriptLines(in: prompt).map { String($0.dropFirst().prefix { $0 != " " }) }
        return expand(system, ids)
    }
}

/// 展开时出处给输入里的第一句和最后一句
private let firstAndLast = responder { system, ids in
    #"{"text": "\#(isMarkExpansion(system) ? "标记" : "笔记")展开 \#(ids.first!)–\#(ids.last!)", "refs": ["\#(ids.first!)", "\#(ids.last!)"]}"#
}

private func generate(_ generator: ScriptedGenerator, meeting m: Meeting, transcript t: Transcript = transcript,
                      template: MinutesTemplate = .general,
                      progress: @escaping (Double) -> Void = { _ in }) async throws -> Minutes {
    try await generateMinutes(
        transcript: t, title: m.title, startedAt: m.startedAt, template: template,
        annotations: m.minutesAnnotations(in: t), generator: generator, model: "fake/scripted",
        createdAt: at(3800), timeZone: shanghai, progress: progress)
}

@Suite struct MinutesAnnotationsTests {
    /// 标记在 120 秒：区间 60–135，句子 s7–s14。笔记在 200 秒：区间 80–230，句子 s9–s23
    @Test func 有标注时概要之后多出会中标注一节_按时间排列_关联标注id() async throws {
        let generator = ScriptedGenerator()
        generator.respond = firstAndLast
        let m = meeting([note("a2", 200, "预算 → 老王确认"), mark("a1", 120)])

        let minutes = try await generate(generator, meeting: m)

        #expect(minutes.sections.map(\.kind) == [.overview, .annotations, .decisions, .actions, .questions])
        #expect(minutes.sections[1].title == "会中标注")
        #expect(minutes.sections[1].items == [
            MinutesItem(id: "n1", text: "标记展开 s7–s14", refs: [MinutesRef(id: "s7", start: 60),
                                                               MinutesRef(id: "s14", start: 130)],
                        annotationIDs: ["a1"]),
            MinutesItem(id: "n2", text: "笔记展开 s9–s23", refs: [MinutesRef(id: "s9", start: 80),
                                                               MinutesRef(id: "s23", start: 220)],
                        annotationIDs: ["a2"], note: "预算 → 老王确认"),
        ])
        #expect(minutes.source.annotationsHash == m.annotationsHash)
        #expect(minutes.source.annotationsHash != nil)
    }

    @Test func 模板的额外节排在会中标注之后() async throws {
        let generator = ScriptedGenerator()
        generator.respond = firstAndLast

        let minutes = try await generate(generator, meeting: meeting([mark("a1", 120)]), template: .weekly)

        #expect(minutes.sections.map(\.kind) == [.overview, .annotations, .decisions, .actions, .questions,
                                                 .custom("progress")])
    }

    /// 输入只有区间里的句子；笔记另外给出原话
    @Test func 每个区间单独展开一次_输入只有区间里的句子() async throws {
        let generator = ScriptedGenerator()
        generator.respond = firstAndLast
        let m = meeting([mark("a1", 120), note("a2", 200, "预算 → 老王确认")])

        _ = try await generate(generator, meeting: m)

        let expansions = generator.calls.filter { isExpansion($0.system) }
        #expect(expansions.count == 2)
        #expect(isMarkExpansion(expansions[0].system))
        #expect(transcriptLines(in: expansions[0].prompt).map { $0.prefix { $0 != " " } }
            == (7...14).map { "[s\($0)" })
        #expect(isNoteExpansion(expansions[1].system))
        #expect(transcriptLines(in: expansions[1].prompt).map { $0.prefix { $0 != " " } }
            == (9...23).map { "[s\($0)" })
        #expect(expansions[1].prompt.contains("预算 → 老王确认"))
        #expect(!expansions[0].prompt.contains("预算 → 老王确认"))
        // 展开的输入里不带 ★
        #expect(!expansions.contains { $0.prompt.contains("★") })
    }

    /// 展开的输出文法：一个 {text, refs}，refs 1–3 个
    @Test func 展开用文法约束为text和refs() async throws {
        let generator = ScriptedGenerator()
        generator.respond = firstAndLast

        _ = try await generate(generator, meeting: meeting([mark("a1", 120)]))

        let grammar = try #require(generator.grammars.last ?? nil)
        #expect(grammar.contains(#"root ::= "{" ws "\"text\":" ws string "," ws "\"refs\":" ws refs ws "}""#))
        #expect(grammar.contains(#"refs ::= "[" ws ref ( "," ws ref ( "," ws ref )? )? ws "]""#))
    }

    @Test func 区间里的句子在主提取输入里带星号_系统提示说明星号() async throws {
        let generator = ScriptedGenerator()
        generator.respond = firstAndLast

        _ = try await generate(generator, meeting: meeting([mark("a1", 120)]))

        let extraction = try #require(generator.calls.first)
        let lines = transcriptLines(in: extraction.prompt)
        #expect(lines.count == 30)
        #expect(lines[5] == "[s6 00:50] 第6句，大家讨论了项目的进度和下一步的安排")
        #expect(lines[6] == "[s7 01:00 ★] 第7句，大家讨论了项目的进度和下一步的安排")
        #expect(lines[13] == "[s14 02:10 ★] 第14句，大家讨论了项目的进度和下一步的安排")
        #expect(lines[14] == "[s15 02:20] 第15句，大家讨论了项目的进度和下一步的安排")
        #expect(lines.count { $0.contains("★") } == 8)
        #expect(extraction.system.contains("★"))
        #expect(extraction.system.contains("不要漏"))
    }

    @Test func 有说话人时星号跟在说话人后面() async throws {
        let t = Transcript(engine: "fake/1", createdAt: at(3700), hotwords: [],
                           items: sentences(30) { [7: "spk1", 8: "spk2"][$0] },
                           diarization: Diarization(engine: "d", voiceprintModel: "v", speakersCreatedAt: at(3750),
                                                    speakers: ["spk1", "spk2"].map {
                                                        Speaker(id: $0, voiceprint: Voiceprint([1]), speechDuration: 10)
                                                    }))
        let generator = ScriptedGenerator()
        generator.respond = firstAndLast

        _ = try await generate(generator, meeting: meeting([mark("a1", 120)]), transcript: t)

        let lines = transcriptLines(in: generator.calls[0].prompt)
        #expect(lines[6] == "[s7 01:00 说话人 1 ★] 第7句，大家讨论了项目的进度和下一步的安排")
        // 展开的输入带说话人，不带星号
        let expansion = try #require(generator.calls.first { isExpansion($0.system) })
        #expect(transcriptLines(in: expansion.prompt).first == "[s7 01:00 说话人 1] 第7句，大家讨论了项目的进度和下一步的安排")
    }

    /// 出处只保留区间里的句子（区间外的、不存在的、重复的去掉）
    @Test func 展开的出处只保留区间里的句子() async throws {
        let generator = ScriptedGenerator()
        generator.respond = responder { _, _ in #"{"text": "展开", "refs": ["s1", "s99", "s9", "s9", "s20"]}"# }

        let minutes = try await generate(generator, meeting: meeting([mark("a1", 120)]))

        #expect(minutes.sections[1].items.map { $0.refs.map(\.id) } == [["s9"]])
    }

    /// 第一个标记的出处全在区间外：丢掉这一条，第二个照常；不为此重试
    @Test func 出处一个不剩时丢掉这一条_其余照常() async throws {
        let generator = ScriptedGenerator()
        var expansions = 0
        generator.respond = responder { _, ids in
            expansions += 1
            return expansions == 1 ? #"{"text": "编的", "refs": ["s30"]}"#
                : #"{"text": "第二个标记", "refs": ["\#(ids[0])"]}"#
        }
        let m = meeting([mark("a1", 120), mark("a2", 290)])

        let minutes = try await generate(generator, meeting: m)

        #expect(expansions == 2)
        #expect(minutes.sections[1].items.map(\.text) == ["第二个标记"])
        #expect(minutes.sections[1].items.map(\.id) == ["n1"])
        #expect(minutes.sections[1].items.map(\.annotationIDs) == [["a2"]])
        #expect(minutes.sections[0].items.map(\.text) == ["讨论了进度"])
    }

    @Test func 解析失败时用同一段输入重试一次() async throws {
        let generator = ScriptedGenerator()
        var outputs = ["抱歉", #"{"text": "重试成功", "refs": ["s9"]}"#]
        generator.respond = responder { _, _ in outputs.removeFirst() }

        let minutes = try await generate(generator, meeting: meeting([mark("a1", 120)]))

        let expansions = generator.calls.filter { isExpansion($0.system) }
        #expect(expansions.count == 2)
        #expect(expansions[0].prompt == expansions[1].prompt)
        #expect(minutes.sections[1].items.map(\.text) == ["重试成功"])
    }

    @Test func 重试后仍解析不出时丢掉这个标记_纪要照常生成() async throws {
        let generator = ScriptedGenerator()
        generator.respond = responder { _, _ in #"{"text": "", "refs": ["s9"]}"# }

        let minutes = try await generate(generator, meeting: meeting([mark("a1", 120)]))

        #expect(generator.calls.count { isExpansion($0.system) } == 2)
        #expect(minutes.sections.map(\.kind) == [.overview, .annotations, .decisions, .actions, .questions])
        #expect(minutes.sections[1].items.isEmpty)
        #expect(minutes.sections[0].items.map(\.text) == ["讨论了进度"])
    }

    /// 笔记在 1800 秒，区间 1680–1830 里没人说话（句子只到 298 秒）：不调用模型，条目是原话
    @Test func 笔记区间里没有句子时不调用模型_条目为原话标为笔记原话() async throws {
        let generator = ScriptedGenerator()
        generator.respond = firstAndLast

        let minutes = try await generate(generator, meeting: meeting([note("a1", 1800, "散会后再聊预算")]))

        #expect(!generator.calls.contains { isExpansion($0.system) })
        #expect(minutes.sections[1].items == [
            MinutesItem(id: "n1", text: "散会后再聊预算", refs: [], origin: .note, annotationIDs: ["a1"],
                        note: "散会后再聊预算"),
        ])
        #expect(minutes.sections[1].items[0].isUnsourced == false)
    }

    @Test(arguments: [#"{"text": "编的", "refs": ["s1"]}"#, "抱歉，我无法完成"])
    func 笔记扩写失败时退回原话(bad: String) async throws {
        let generator = ScriptedGenerator()
        generator.respond = responder { _, _ in bad }

        let minutes = try await generate(generator, meeting: meeting([note("a1", 200, "预算 → 老王确认")]))

        #expect(minutes.sections[1].items == [
            MinutesItem(id: "n1", text: "预算 → 老王确认", refs: [], origin: .note, annotationIDs: ["a1"],
                        note: "预算 → 老王确认"),
        ])
    }

    /// 标记在 1800 秒，附近没有转写稿：不进纪要，也不调用模型。「会中标注」一节仍在（生成时会议有标注）
    @Test func 标记附近完全没有转写稿时不进纪要() async throws {
        let generator = ScriptedGenerator()
        generator.respond = firstAndLast

        let minutes = try await generate(generator, meeting: meeting([mark("a1", 1800)]))

        #expect(!generator.calls.contains { isExpansion($0.system) })
        #expect(minutes.sections.map(\.kind) == [.overview, .annotations, .decisions, .actions, .questions])
        #expect(minutes.sections[1].items.isEmpty)
        // 没有句子带星号，系统提示也不提星号（与没有标注时相同）
        #expect(!generator.calls[0].system.contains("★"))
        #expect(!generator.calls[0].prompt.contains("★"))
    }

    /// 合并的标记展开一次，关联全部标记 id
    @Test func 合并的标记展开一次_关联全部标记id() async throws {
        let generator = ScriptedGenerator()
        generator.respond = firstAndLast

        let minutes = try await generate(generator, meeting: meeting([mark("a1", 120), mark("a2", 150)]))

        #expect(generator.calls.count { isExpansion($0.system) } == 1)
        #expect(minutes.sections[1].items.map(\.annotationIDs) == [["a1", "a2"]])
        #expect(minutes.sections[1].items.map(\.text) == ["标记展开 s7–s17"])
    }

    @Test func 展开时引擎报错原样抛出_不重试() async throws {
        let generator = ScriptedGenerator()
        generator.respond = firstAndLast
        let m = meeting([mark("a1", 120)])
        // 提取成功，展开时引擎报错
        let failing = FailingOnExpansion(generator)
        await #expect(throws: CancellationError.self) {
            try await generateMinutes(transcript: transcript, title: m.title, startedAt: m.startedAt,
                                      template: .general, annotations: m.minutesAnnotations(in: transcript),
                                      generator: failing, model: "fake/scripted", timeZone: shanghai)
        }
        #expect(failing.expansions == 1)
    }

    /// 长会议分段提取（contextTokens 4000 时 200 句分成好几段），区间跨过分段边界也一次展开、
    /// 输入是区间里的全部句子；进度的总步数是分段数、合并、区间数之和
    @Test func 长会议分段时跨段的标注照常展开_进度计入展开() async throws {
        let long = Transcript(engine: "fake/1", createdAt: at(3700), hotwords: [], items: sentences(200))
        let generator = ScriptedGenerator(contextTokens: 4000)
        generator.respond = { system, prompt in
            if isExpansion(system) { return firstAndLast(system, prompt) }
            let first = transcriptLines(in: prompt).first { $0.hasPrefix("[s") }.map { $0.dropFirst().prefix { $0 != " " } }
            return first.map { #"{"overview": [{"text": "\#($0) 开始的一段", "refs": ["\#($0)"]}]}"# }
                ?? #"{"overview": [{"text": "全场概要", "refs": ["s1"]}]}"#
        }
        // 先找出第一个切点，把标记放在它附近
        let probe = ScriptedGenerator(contextTokens: 4000)
        probe.respond = generator.respond
        _ = try await generate(probe, meeting: meeting([]), transcript: long)
        let segmentStarts = probe.calls.compactMap { call -> Int? in
            guard let line = transcriptLines(in: call.prompt).first else { return nil }
            return Int(line.dropFirst(2).prefix { $0 != " " })
        }
        #expect(segmentStarts.count >= 3)
        let cut = segmentStarts[1]
        // 第 cut 句从 (cut-1)*10 秒开始；标记在它之后 5 秒，区间里有切点前 6 句、切点后 2 句
        let m = meeting([mark("a1", Double(cut - 1) * 10 + 5)])
        var reported: [Double] = []

        let minutes = try await generate(generator, meeting: m, transcript: long) { reported.append($0) }

        let expansions = generator.calls.filter { isExpansion($0.system) }
        #expect(expansions.count == 1)
        #expect(transcriptLines(in: expansions[0].prompt).map { $0.prefix { $0 != " " } }
            == ((cut - 6)...(cut + 1)).map { "[s\($0)" })
        #expect(minutes.sections[1].items.map { $0.refs.map(\.id) } == [["s\(cut - 6)", "s\(cut + 1)"]])
        // 区间跨过分段边界：带星号的句子分在两段的输入里（星号让行变长，切点可能挪一两句，区间仍跨过它）
        let extractions = generator.calls.filter { !isExpansion($0.system) && !transcriptLines(in: $0.prompt).isEmpty }
        #expect(extractions.count { $0.prompt.contains("★") } == 2)

        let n = extractions.count
        let total = Double(n + 1 + 1)
        #expect(reported == (1...(n + 2)).map { Double($0) / total })
    }

    @Test func 只有一段时进度按提取和各区间计() async throws {
        let generator = ScriptedGenerator()
        generator.respond = firstAndLast
        var reported: [Double] = []

        _ = try await generate(generator, meeting: meeting([mark("a1", 120), note("a2", 1800, "散会")])) {
            reported.append($0)
        }

        #expect(reported == [1.0 / 3, 2.0 / 3, 1])
    }

    /// 放不下时从区间两端去句子：每次去掉离标注时刻远的一端，直到放下。
    /// 每句约 300 字：提取时一段只放得下几句，分成很多段；笔记的区间（80–230 秒，s9–s23，15 句）一次放不下
    @Test func 区间一次放不下时从两端去掉句子() async throws {
        let items: [TranscriptItem] = (1...30).map { i in
            .sentence(TranscriptSentence(id: "s\(i)", start: Double(i - 1) * 10, end: Double(i - 1) * 10 + 8,
                                         text: "第\(i)句" + String(repeating: "大家讨论了项目的进度和下一步的安排", count: 18)))
        }
        let t = Transcript(engine: "fake/1", createdAt: at(3700), hotwords: [], items: items)
        let generator = ScriptedGenerator(contextTokens: 5000)
        generator.respond = { system, prompt in
            if isExpansion(system) { return firstAndLast(system, prompt) }
            return oneOverview
        }

        let minutes = try await generate(generator, meeting: meeting([note("a1", 200, "预算")]), transcript: t)

        let expansion = try #require(generator.calls.first { isExpansion($0.system) })
        let ids = transcriptLines(in: expansion.prompt).map { Int($0.dropFirst(2).prefix { $0 != " " })! }
        #expect(ids.count > 1 && ids.count < 15)
        // 连续的一段，含笔记时刻（200 秒）那句 s21
        #expect(ids == Array(ids.first!...ids.last!))
        #expect(ids.contains(21))
        #expect(ids.first! > 9)
        #expect(generator.countTokens(expansion.prompt)
            <= 5000 - 5000 * 2 / 5 - generator.countTokens(expansion.system))
        #expect(minutes.sections[1].items.map(\.origin) == [.model])
    }

    /// 「会中标注」的条目和其他节一样可以修改、删除、恢复原文；修改不动关联和笔记原话
    @Test func 会中标注的条目可以修改删除恢复原文_不动关联和笔记原话() async throws {
        let generator = ScriptedGenerator()
        generator.respond = firstAndLast
        let generated = try await generate(generator, meeting: meeting([note("a1", 200, "预算 → 老王确认")]))
        let item = generated.sections[1].items[0]
        var minutes = generated

        let changed1 = minutes.edit(item: "n1", text: "预算由老王确认")
        #expect(changed1)
        #expect(minutes.sections[1].items[0].text == "预算由老王确认")
        #expect(minutes.sections[1].items[0].original == MinutesItem.Original(text: item.text))
        #expect(minutes.sections[1].items[0].annotationIDs == ["a1"])
        #expect(minutes.sections[1].items[0].note == "预算 → 老王确认")
        #expect(minutes.editCount == 1)

        let changed2 = minutes.restore(item: "n1")
        #expect(changed2)
        #expect(minutes == generated)
        let changed3 = minutes.delete(item: "n1")
        #expect(changed3)
        #expect(minutes.sections[1].visibleItems.isEmpty)
        #expect(minutes.editCount == 1)
        let changed4 = minutes.undoDelete(item: "n1")
        #expect(changed4)
        #expect(minutes == generated)
    }

    @Test func 笔记原话的条目改过也算一处修改_恢复后回到原话() async throws {
        let generator = ScriptedGenerator()
        generator.respond = firstAndLast
        let generated = try await generate(generator, meeting: meeting([note("a1", 1800, "散会后再聊")]))
        var minutes = generated

        let changed5 = minutes.edit(item: "n1", text: "散会后再聊预算")
        #expect(changed5)
        #expect(minutes.editCount == 1)
        #expect(minutes.sections[1].items[0].origin == .note)
        #expect(minutes.sections[1].items[0].note == "散会后再聊")
        let changed6 = minutes.restore(item: "n1")
        #expect(changed6)
        #expect(minutes == generated)
        #expect(minutes.editCount == 0)
    }

    /// 没有分片换算不了区间，但会议有标注：一节照样有（空），哈希照样记，免得一直提示“会中标注有改动”
    @Test func 换算不了区间时仍记下标注哈希() async throws {
        var m = meeting([mark("a1", 120)])
        m.segments = []
        let generator = ScriptedGenerator()
        generator.respond = firstAndLast

        let minutes = try await generate(generator, meeting: m)

        #expect(minutes.source.annotationsHash == m.annotationsHash)
        #expect(minutes.sections.map(\.kind) == [.overview, .annotations, .decisions, .actions, .questions])
        #expect(minutes.sync(with: transcript, meeting: m) == .inSync)
    }

    @Test func 没有标注的会议不多出一节_不记哈希() async throws {
        let generator = ScriptedGenerator()
        generator.respond = firstAndLast

        let minutes = try await generate(generator, meeting: meeting([]))

        #expect(minutes.sections.map(\.kind) == [.overview, .decisions, .actions, .questions])
        #expect(minutes.source.annotationsHash == nil)
        #expect(generator.calls.count == 1)
    }
}

/// 提取照常交给 base，展开时抛取消
private final class FailingOnExpansion: TextGenerator, @unchecked Sendable {
    let base: ScriptedGenerator
    private(set) var expansions = 0
    init(_ base: ScriptedGenerator) { self.base = base }
    var contextTokens: Int { base.contextTokens }
    func countTokens(_ text: String) -> Int { base.countTokens(text) }
    var isDownloaded: Bool { true }
    func load(progress: @escaping (Double) -> Void) async throws {}
    func unload() {}
    func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        if isExpansion(system) {
            expansions += 1
            throw CancellationError()
        }
        return try await base.generate(system: system, prompt: prompt, maxTokens: maxTokens)
    }
}
