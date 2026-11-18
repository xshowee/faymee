import Foundation
import Testing
@testable import FaymeeCore

/// 纠错的存储与撤销（spec「存储」「与手动编辑并发」，「测试决定」存储、并发）
@Suite struct TranscriptCorrectionTests {
    private let created = Date(timeIntervalSince1970: 1_794_279_660)

    private func transcript(_ texts: [String], speakers: [String?]? = nil) -> Transcript {
        let items = texts.enumerated().map { i, text in
            TranscriptItem.sentence(TranscriptSentence(id: "s\(i + 1)", start: Double(i), end: Double(i) + 1, text: text,
                                                       speaker: speakers?[i]))
        }
        return Transcript(engine: "apple/speechanalyzer", createdAt: created, hotwords: ["智能体"], items: items)
    }

    /// 按快照得出的纠错结果：s1、s3 改了，s2 有一条数字建议
    private func result(for snapshot: Transcript) -> CorrectionResult {
        CorrectionResult(
            snapshot: snapshot,
            review: CorrectionReview(texts: ["s1": "我们要避免被动", "s3": "工位上见"],
                                     suggestions: [NumberSuggestion(sentence: "s2", from: "十月", to: "四月")],
                                     rejections: ["pinyin": 2]),
            engine: "llama/qwen3.5-4b-q4km", createdAt: created.addingTimeInterval(60), hotwords: ["智能体"])
    }

    private var before: Transcript { transcript(["我们要避免对动", "十月底上线", "工会上见"]) }

    private func corrected() throws -> Transcript {
        var t = before
        try t.applyCorrection(result(for: before))
        return t
    }

    @Test func 纠错写进句子_correction是纠错前的文字() throws {
        let t = try corrected()
        #expect(t.sentences.map(\.text) == ["我们要避免被动", "十月底上线", "工位上见"])
        #expect(t.sentences.map(\.correction) == ["我们要避免对动", nil, "工会上见"])
        #expect(t.sentences.allSatisfy { $0.original == nil })
        #expect(t.correctedCount == 2)
        let info = try #require(t.correction)
        #expect(info.engine == "llama/qwen3.5-4b-q4km")
        #expect(info.hotwords == ["智能体"])
        #expect(info.suggestions == [NumberSuggestion(sentence: "s2", from: "十月", to: "四月")])
        #expect(info.rejections == ["pinyin": 2])
    }

    @Test func 纠错不改变editCount() throws {
        #expect(try corrected().editCount == 0)
        #expect(try corrected().retranscribeEditCount(diarizes: true) == 0)
    }

    @Test func 撤销一句_换回纠错前的文字() throws {
        var t = try corrected()
        let changed1 = t.undoCorrection(sentence: "s1")
        #expect(changed1)
        #expect(t.sentences[0].text == "我们要避免对动")
        #expect(t.sentences[0].correction == nil)
        #expect(t.sentences[2].text == "工位上见")
        let changed2 = t.undoCorrection(sentence: "s2")
        #expect(!changed2)
    }

    @Test func 撤销全部后句子与纠错前一致() throws {
        var t = try corrected()
        let changed3 = t.undoAllCorrections()
        #expect(changed3)
        #expect(t.items == before.items)
        #expect(t.textHash == before.textHash)
        #expect(t.correctedCount == 0)
        let changed4 = t.undoAllCorrections()
        #expect(!changed4)
    }

    @Test func 手动修改纠错过的句子_视为接受纠错() throws {
        var t = try corrected()
        let changed5 = t.edit(sentence: "s1", to: "我们要避免被动局面")
        #expect(changed5)
        let s = t.sentences[0]
        #expect(s.correction == nil)
        #expect(s.original == "我们要避免被动")
        let changed6 = t.restore(sentence: "s1")
        #expect(changed6)
        #expect(t.sentences[0].text == "我们要避免被动")
    }

    @Test func 旧transcript_json照常读_写出时不带纠错字段() throws {
        let old = #"""
        {"createdAt":"2026-11-10T02:00:00Z","engine":"apple/speechanalyzer","hotwords":[],"items":[{"end":1,"id":"s1","kind":"sentence","original":null,"start":0,"text":"你好"}],"version":1}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let t = try decoder.decode(Transcript.self, from: Data(old.utf8))
        #expect(t.correction == nil)
        #expect(t.sentences[0].correction == nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let written = try encoder.encode(t)
        #expect(!String(decoding: written, as: UTF8.self).contains("correction"))
        let reread = try JSONSerialization.jsonObject(with: written) as? NSDictionary
        #expect(reread == (try JSONSerialization.jsonObject(with: Data(old.utf8)) as? NSDictionary))
    }

    @Test func 纠错字段写盘读回不变() throws {
        let store = MeetingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("FaymeeCoreTests-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: store.root) }
        try FileManager.default.createDirectory(at: store.directory("m1"), withIntermediateDirectories: true)
        let t = try corrected()
        try store.saveTranscript(t, for: "m1")
        #expect(try store.loadTranscript("m1") == t)
        #expect(t.version == Transcript.currentVersion)
    }

    // MARK: 与手动编辑并发

    @Test func 纠错期间手动改了一句_只跳过那一句() throws {
        let snapshot = before
        var latest = before
        latest.edit(sentence: "s1", to: "我们要避免这种局面")
        try latest.applyCorrection(result(for: snapshot))
        #expect(latest.sentences.map(\.text) == ["我们要避免这种局面", "十月底上线", "工位上见"])
        #expect(latest.sentences[0].correction == nil)
    }

    @Test func 纠错期间改了说话人的句子跳过() throws {
        let snapshot = transcript(["我们要避免对动", "十月底上线", "工会上见"], speakers: ["spk1", "spk1", "spk2"])
        var latest = transcript(["我们要避免对动", "十月底上线", "工会上见"], speakers: ["spk1", "spk1", "spk1"])
        try latest.applyCorrection(result(for: snapshot))
        #expect(latest.sentences.map(\.text) == ["我们要避免被动", "十月底上线", "工会上见"])
    }

    @Test func 被跳过的句子上的数字建议也不要() throws {
        let snapshot = before
        var latest = before
        latest.edit(sentence: "s2", to: "十月底一定上线")
        try latest.applyCorrection(result(for: snapshot))
        #expect(latest.correction?.suggestions == [])
    }

    @Test func 重新转写过_整体作废() throws {
        let snapshot = before
        var latest = transcript(["我们要避免对动", "十月底上线", "工会上见"])
        latest.createdAt = created.addingTimeInterval(1)
        let outcome = Result { try latest.applyCorrection(result(for: snapshot)) }
        #expect(throws: CorrectionError.retranscribed) { try outcome.get() }
        #expect(latest.correctedCount == 0)
    }

    @Test func 忽略过的建议重新纠错后不再出现_未忽略的被新结果替换() throws {
        var t = try corrected()
        t.correction?.suggestions = [NumberSuggestion(sentence: "s2", from: "十月", to: "四月", ignored: true),
                                     NumberSuggestion(sentence: "s1", from: "一点", to: "两点")]
        t.undoAllCorrections()
        try t.applyCorrection(result(for: before))
        #expect(t.correction?.suggestions == [NumberSuggestion(sentence: "s2", from: "十月", to: "四月", ignored: true)])
    }
}
