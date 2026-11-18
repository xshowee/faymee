import Foundation
import Testing
@testable import FaymeeCore

/// 在线纠错的生成：整句改写的提示词、输出容错（spec「输入与输出」在线部分，「测试决定」在线输出）
@Suite struct OnlineCorrectionGenerationTests {
    private func transcript(_ texts: [String]) -> Transcript {
        let items = texts.enumerated().map { i, text in
            TranscriptItem.sentence(TranscriptSentence(id: "s\(i + 1)", start: Double(i * 10), end: Double(i * 10 + 5),
                                                       text: text))
        }
        return Transcript(engine: "apple/speechanalyzer", createdAt: Date(timeIntervalSince1970: 0), hotwords: [],
                          items: items)
    }

    private func correct(_ texts: [String], outputs: [String]) async throws -> (CorrectionReview, ScriptedGenerator) {
        let generator = ScriptedGenerator(outputs: outputs)
        let review = try await correctTranscript(transcript(texts), title: "周会", hotwords: [],
                                                 method: .sentenceRewrite, generator: generator)
        return (review, generator)
    }

    @Test func 在线纪要引擎用整句改写_范围是全部() {
        #expect(CorrectionMethod.forMinutesEngine(isOnline: true) == .sentenceRewrite)
        #expect(CorrectionMethod.forMinutesEngine(isOnline: false) == .wordFixes)
        #expect(CorrectionMethod.sentenceRewrite.scope == .full)
    }

    @Test func 在线输出改后的整句_比对后过护栏() async throws {
        let (review, generator) = try await correct(
            ["我们要避免对动的局面", "那我们就开始吧吧吧吧吧吧", "好的"],
            outputs: [#"{"edits": [{"id": "s1", "text": "我们要避免被动的局面"}, {"id": "s2", "text": "那我们就开始吧"}]}"#])
        #expect(review.texts == ["s1": "我们要避免被动的局面", "s2": "那我们就开始吧"])
        #expect(review.rejections.isEmpty)
        // 没有文法，靠各协议的 JSON 模式
        #expect(generator.grammars == [nil])
    }

    @Test func 提示词写明整句改写的范围和输出形状() async throws {
        let (_, generator) = try await correct(["我们开始吧"], outputs: [#"{"edits": []}"#])
        let system = try #require(generator.calls.first?.system)
        #expect(system.contains(#"{"edits": [{"id": "s12", "text": "#))
        #expect(system.contains("JSON"))
        #expect(system.contains("补"))
        #expect(system.contains("保留"))
        #expect(system.contains(#""""#))
    }

    @Test func 多余文字_形状不对的条目_超范围的id都丢弃_不报失败() async throws {
        let output = #"""
        好的，改动如下：
        {"edits": [{"id": "s1", "text": "我们要避免被动的局面"}, {"id": "s2"}, 5, {"id": 3, "text": "x"},
        {"id": "s9", "text": "不存在的句子"}]}
        以上。
        """#
        let (review, generator) = try await correct(["我们要避免对动的局面", "好的"], outputs: [output])
        #expect(generator.calls.count == 1)
        #expect(review.texts == ["s1": "我们要避免被动的局面"])
        #expect(review.rejections[CorrectionRule.unparseable.rawValue] == nil)
    }

    @Test func 输出解析不出时重试一次_仍不行这一段不改() async throws {
        let (review, generator) = try await correct(["我们要避免对动的局面"], outputs: ["不是 JSON", #"{"fixes": []}"#])
        #expect(generator.calls.count == 2)
        #expect(review.texts.isEmpty)
        #expect(review.rejections == [CorrectionRule.unparseable.rawValue: 1])
    }

    @Test func 解析_空字符串表示删成空句_同一句只认第一条_带了行首编号的去掉() {
        let edits = parseSentenceEdits(#"""
        {"edits": [{"id": "s2", "text": ""}, {"id": "s1", "text": "第一条"}, {"id": "s1", "text": "第二条"},
        {"id": "s3", "text": "[s3 说话人 2] 我们开始吧"}]}
        """#)
        #expect(edits == [SentenceEdit(id: "s2", text: ""), SentenceEdit(id: "s1", text: "第一条"),
                          SentenceEdit(id: "s3", text: "我们开始吧")])
        #expect(parseSentenceEdits(#"{"fixes": []}"#) == nil)
        #expect(parseSentenceEdits("没有 JSON") == nil)
    }

    @Test func 输出被截断时救回已写完的条目() {
        let truncated = #"{"edits": [{"id": "s1", "text": "我们要避免被动的局面"}, {"id": "s2", "text": "那我们就"#
        #expect(parseSentenceEdits(truncated) == [SentenceEdit(id: "s1", text: "我们要避免被动的局面")])
    }
}
