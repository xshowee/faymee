import Foundation
import Testing
@testable import FaymeeCore

/// 纠错的生成：分段、提示词、本机文法、解析（spec「输入与输出」本机部分，「测试决定」文法）
@Suite struct CorrectionGenerationTests {
    private func transcript(_ texts: [String], edited: Set<String> = [], speakers: Bool = false) -> Transcript {
        let items = texts.enumerated().map { i, text in
            let id = "s\(i + 1)"
            return TranscriptItem.sentence(TranscriptSentence(
                id: id, start: Double(i * 10), end: Double(i * 10 + 5), text: text,
                original: edited.contains(id) ? "原文" : nil, speaker: speakers ? "spk\(i % 2 + 1)" : nil))
        }
        var t = Transcript(engine: "apple/speechanalyzer", createdAt: Date(timeIntervalSince1970: 0), hotwords: [],
                           items: items)
        if speakers {
            let vp = Voiceprint([0])
            t.diarization = Diarization(engine: "sherpa", voiceprintModel: "m", speakersCreatedAt: Date(timeIntervalSince1970: 0),
                                        speakers: [Speaker(id: "spk1", name: "龚老师", nameSource: .user, voiceprint: vp, speechDuration: 1),
                                                   Speaker(id: "spk2", voiceprint: vp, speechDuration: 1)])
        }
        return t
    }

    @Test func 本机输出的替换过护栏后得出改后的文字() async throws {
        let t = transcript(["我们要避免对动的局面", "他在工会上说了这件事"])
        let generator = ScriptedGenerator(outputs: [
            #"{"fixes": [{"id": "s1", "from": "对动", "to": "被动"}, {"id": "s2", "from": "工会上", "to": "工位上"}]}"#,
        ])
        let review = try await correctTranscript(t, title: "周会", hotwords: [], method: .wordFixes,
                                                 generator: generator)
        #expect(review.texts == ["s1": "我们要避免被动的局面", "s2": "他在工位上说了这件事"])
    }

    @Test func 本机输出里from与to相同的条目不算修改_不连累同一句的其他修改() async throws {
        // 真实会议上 Qwen3.5 4B 常把没改的字也列出来（「掉」→「掉」），之前按 `from` 对不上整句丢弃
        let t = transcript(["钓了好几次都掉了", "他在工会上说了这件事"])
        let generator = ScriptedGenerator(outputs: [
            #"{"fixes": [{"id": "s1", "from": "钓", "to": "调"}, {"id": "s1", "from": "掉", "to": "掉"}, "#
                + #"{"id": "s2", "from": "说了", "to": "说了"}]}"#,
        ])
        let review = try await correctTranscript(t, title: "周会", hotwords: [], method: .wordFixes,
                                                 generator: generator)
        #expect(review.texts == ["s1": "调了好几次都掉了"])
        #expect(review.rejections.isEmpty)
    }

    @Test func 本机输出里重复列出的同一条只算一条() async throws {
        let t = transcript(["我们要避免对动的局面"])
        let generator = ScriptedGenerator(outputs: [
            #"{"fixes": [{"id": "s1", "from": "对动", "to": "被动"}, {"id": "s1", "from": "对动", "to": "被动"}]}"#,
        ])
        let review = try await correctTranscript(t, title: "周会", hotwords: [], method: .wordFixes,
                                                 generator: generator)
        #expect(review.texts == ["s1": "我们要避免被动的局面"])
        #expect(review.rejections.isEmpty)
    }

    @Test func 本机输出被截断时救回已写完的条目_不重试() async throws {
        // 长会议一段列很多条时碰到输出上限，停在半条上
        let t = transcript(["我们要避免对动的局面", "他在工会上说了这件事"])
        let generator = ScriptedGenerator(outputs: [
            #"{"fixes": [{"id": "s1", "from": "对动", "to": "被动"}, {"id": "s2", "from": "工会"#,
        ])
        let review = try await correctTranscript(t, title: "周会", hotwords: [], method: .wordFixes,
                                                 generator: generator)
        #expect(generator.calls.count == 1)
        #expect(review.texts == ["s1": "我们要避免被动的局面"])
        #expect(review.rejections.isEmpty)
    }

    @Test func 文法把id限定在这一段可改的句子里_条数不超过句数() async throws {
        let t = transcript(["第一句话", "第二句话", "第三句话"], edited: ["s2"])
        let generator = ScriptedGenerator(outputs: [#"{"fixes": []}"#])
        _ = try await correctTranscript(t, title: "周会", hotwords: [], method: .wordFixes, generator: generator)
        let grammar = try #require(generator.grammars.first ?? nil)
        #expect(grammar.contains(#""\"s1\"""#))
        #expect(grammar.contains(#""\"s3\"""#))
        // 手动改过的句子当上下文给模型，但不能改
        #expect(!grammar.contains(#""\"s2\"""#))
        // 两句可改：除第一条外最多再 1 条
        #expect(grammar.contains("{0,1}"))
    }

    @Test func 文法写的是fixes的形状() {
        let grammar = wordFixGrammar(ids: ["s1", "s12"])
        #expect(grammar.contains(#""\"fixes\":""#))
        #expect(grammar.contains(#"id ::= "\"s1\"" | "\"s12\"""#))
        #expect(grammar.contains(#""\"from\":""#) && grammar.contains(#""\"to\":""#))
    }

    @Test func 输入行带说话人标签_不带时间() async throws {
        let t = transcript(["我们开始吧", "好的"], speakers: true)
        let generator = ScriptedGenerator(outputs: [#"{"fixes": []}"#])
        _ = try await correctTranscript(t, title: "周会", hotwords: [], method: .wordFixes, generator: generator)
        let prompt = try #require(generator.calls.first?.prompt)
        #expect(prompt.contains("[s1 龚老师] 我们开始吧"))
        #expect(prompt.contains("[s2 说话人 2] 好的"))
    }

    @Test func 提示词附参考词_热词_已命名说话人_会议标题() async throws {
        let t = transcript(["我们开始吧", "好的"], speakers: true)
        let generator = ScriptedGenerator(outputs: [#"{"fixes": []}"#])
        _ = try await correctTranscript(t, title: "智能体评审会", hotwords: ["LangChain"], method: .wordFixes,
                                        generator: generator)
        let system = try #require(generator.calls.first?.system)
        #expect(system.contains("LangChain"))
        #expect(system.contains("龚老师"))
        #expect(system.contains("智能体评审会"))
        #expect(system.contains("保留"))
    }

    @Test func 长转写稿分段_后一段带上一段最后3句作只读上下文_对它们的修改丢弃() async throws {
        let texts = (1...12).map { "这是第\($0)句很长很长很长很长的话，对动" }
        let t = transcript(texts)
        let generator = ScriptedGenerator(contextTokens: 900)
        generator.respond = { _, prompt in
            // 每段都想改第 s2 句（只在第一段可改）
            #"{"fixes": [{"id": "s2", "from": "对动", "to": "被动"}]}"#
        }
        let review = try await correctTranscript(t, title: "周会", hotwords: [], method: .wordFixes,
                                                 generator: generator)
        #expect(generator.calls.count > 1)
        let second = generator.calls[1].prompt
        let grammars = generator.grammars.compactMap { $0 }
        // 第二段的上下文是第一段的最后 3 句，不在第二段的文法里
        let firstIDs = ids(in: generator.calls[0].prompt)
        let context = Array(firstIDs.suffix(3))
        for id in context {
            #expect(second.contains("[\(id)]"))
            #expect(!grammars[1].contains("\"\\\"\(id)\\\"\""))
        }
        #expect(review.texts.keys.sorted() == ["s2"])
        #expect(review.rejections[CorrectionRule.notEditable.rawValue] == generator.calls.count - 1)
    }

    @Test func 输出解析不出时重试一次_仍不行这一段不改_记一条() async throws {
        let t = transcript(["我们要避免对动的局面"])
        let generator = ScriptedGenerator(outputs: ["不是 JSON", "还不是"])
        let review = try await correctTranscript(t, title: "周会", hotwords: [], method: .wordFixes,
                                                 generator: generator)
        #expect(generator.calls.count == 2)
        #expect(review.texts.isEmpty)
        #expect(review.rejections == [CorrectionRule.unparseable.rawValue: 1])
    }

    @Test func 形状不对的条目丢弃_其余照常() {
        let fixes = parseWordFixes(#"好的 {"fixes": [{"id": "s1", "from": "对动"}, 3, {"id": "s1", "from": "对动", "to": "被动"}]} 完"#)
        #expect(fixes == [WordFix(id: "s1", from: "对动", to: "被动")])
        #expect(parseWordFixes(#"{"edits": []}"#) == nil)
    }

    @Test func 引擎报错原样抛出() async throws {
        struct Boom: Error {}
        let generator = ScriptedGenerator(outputs: [])
        generator.error = Boom()
        await #expect(throws: Boom.self) {
            try await correctTranscript(transcript(["一句"]), title: "周会", hotwords: [], method: .wordFixes,
                                        generator: generator)
        }
    }

    @Test func 没有可改的句子时不调模型() async throws {
        let generator = ScriptedGenerator(outputs: [])
        let review = try await correctTranscript(transcript(["一句"], edited: ["s1"]), title: "周会", hotwords: [],
                                                 method: .wordFixes, generator: generator)
        #expect(generator.calls.isEmpty)
        #expect(review == CorrectionReview())
    }

    private func ids(in prompt: String) -> [String] {
        prompt.split(separator: "\n").compactMap { line in
            line.firstMatch(of: try! Regex(#"^\[(s\d+)"#)).map { String($0.output[1].substring!) }
        }
    }
}
