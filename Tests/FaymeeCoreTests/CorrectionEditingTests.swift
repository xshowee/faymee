import Foundation
import Testing
@testable import FaymeeCore

/// 转写稿里看得见、撤得掉（ticket 02，spec「存储」「界面」）：下划线、数字建议的采纳与忽略、重新纠错
@Suite struct CorrectionEditingTests {
    private func sentence(_ text: String, correction: String?) -> TranscriptSentence {
        TranscriptSentence(id: "s1", start: 0, end: 1, text: text, correction: correction)
    }

    @Test func 下划线是改后文字里被换掉的字() {
        #expect(sentence("我们要避免被动", correction: "我们要避免对动").correctionHighlights == [5..<6])
        #expect(sentence("在工位上见", correction: "在工会上见").correctionHighlights == [2..<3])
    }

    @Test func 补的字加下划线_删掉的字不显示() {
        // 补字：「了」是补进去的
        #expect(sentence("我们开会了吧", correction: "我们开会吧").correctionHighlights == [4..<5])
        // 删字：改后文字里没有它，不画
        #expect(sentence("我觉得可以", correction: "我觉得得得得得得可以").correctionHighlights.isEmpty)
    }

    @Test func 改了标点也画_英文按词() {
        #expect(sentence("好，走吧", correction: "好走吧").correctionHighlights == [1..<2])
        #expect(sentence("用LangChain做", correction: "用long chain做").correctionHighlights == [1..<10])
    }

    @Test func 没纠错过的句子没有下划线() {
        #expect(sentence("我们要避免对动", correction: nil).correctionHighlights.isEmpty)
    }

    // MARK: - 数字建议

    private let created = Date(timeIntervalSince1970: 1_794_279_660)
    private let october = NumberSuggestion(sentence: "s2", from: "十月", to: "四月")

    /// s1 纠错改过，s2 有一条数字建议「十月→四月」
    private func corrected(_ suggestions: [NumberSuggestion]? = nil) -> Transcript {
        let items: [TranscriptItem] = [
            .sentence(TranscriptSentence(id: "s1", start: 0, end: 1, text: "我们要避免被动", correction: "我们要避免对动")),
            .sentence(TranscriptSentence(id: "s2", start: 1, end: 2, text: "十月底上线")),
        ]
        var t = Transcript(engine: "apple/speechanalyzer", createdAt: created, hotwords: [], items: items)
        t.correction = TranscriptCorrection(engine: "llama/qwen3.5-4b-q4km", createdAt: created, hotwords: [],
                                            suggestions: suggestions ?? [october])
        return t
    }

    @Test func 数字建议显示在那句旁() {
        #expect(corrected().numberSuggestions == ["s2": [october]])
        #expect(corrected([]).numberSuggestions.isEmpty)
    }

    @Test func 采纳建议按一处纠错处理_不算人工修改() {
        var t = corrected()
        let adopted = t.adopt(october)
        #expect(adopted)
        let s = t.sentences[1]
        #expect(s.text == "四月底上线")
        #expect(s.correction == "十月底上线")
        #expect(s.original == nil)
        #expect(t.editCount == 0)
        #expect(t.correctedCount == 2)
        #expect(s.correctionHighlights == [0..<1])  // 只有「十→四」变了
        // 采纳后句子里不再有「十月」，建议不再显示
        #expect(t.numberSuggestions.isEmpty)
    }

    @Test func 撤销采纳的建议_回到纠错前_建议重新显示() {
        var t = corrected()
        t.adopt(october)
        let undone = t.undoCorrection(sentence: "s2")
        #expect(undone)
        #expect(t.sentences[1].text == "十月底上线")
        #expect(t.sentences[1].correction == nil)
        #expect(t.numberSuggestions == ["s2": [october]])
    }

    @Test func 纠错改过的句子再采纳_撤销回到最早的原文() {
        let suggestion = NumberSuggestion(sentence: "s1", from: "要", to: "一")
        var t = corrected([suggestion])
        t.adopt(suggestion)
        #expect(t.sentences[0].text == "我们一避免被动")
        #expect(t.sentences[0].correction == "我们要避免对动")
        t.undoCorrection(sentence: "s1")
        #expect(t.sentences[0].text == "我们要避免对动")
    }

    @Test func 手动改过的句子_建议不显示也不能采纳() {
        // 纠错不碰手动改过的句子，建议也一样
        var t = corrected()
        t.edit(sentence: "s2", to: "十月底上线吧")
        #expect(t.numberSuggestions.isEmpty)
        let adopted = t.adopt(october)
        #expect(!adopted)
        #expect(t.sentences[1].text == "十月底上线吧")
    }

    @Test func 原文在句子里不是恰好一次_建议不显示也不能采纳() {
        // 「十月」出现两次：不知道该换哪一处
        let items: [TranscriptItem] = [
            .sentence(TranscriptSentence(id: "s2", start: 1, end: 2, text: "十月底上线，十月中提测")),
        ]
        var repeated = Transcript(engine: "apple/speechanalyzer", createdAt: created, hotwords: [], items: items)
        repeated.correction = corrected().correction
        #expect(repeated.numberSuggestions.isEmpty)
        let adoptedRepeated = repeated.adopt(october)
        #expect(!adoptedRepeated)
    }

    @Test func 忽略后不再显示() {
        var t = corrected()
        let ignored = t.ignore(october)
        #expect(ignored)
        #expect(t.numberSuggestions.isEmpty)
        #expect(t.correction?.suggestions == [NumberSuggestion(sentence: "s2", from: "十月", to: "四月", ignored: true)])
        let again = t.ignore(october)
        #expect(!again)
    }

    // MARK: - 重新纠错

    @Test func 重新纠错前_撤销全部并清掉未忽略的建议() {
        let other = NumberSuggestion(sentence: "s1", from: "要", to: "一")
        var t = corrected([october, other])
        t.ignore(october)
        let changed = t.resetForRecorrection()
        #expect(changed)
        #expect(t.sentences.map(\.text) == ["我们要避免对动", "十月底上线"])
        #expect(t.correctedCount == 0)
        #expect(t.correction?.suggestions == [NumberSuggestion(sentence: "s2", from: "十月", to: "四月", ignored: true)])
        let again = t.resetForRecorrection()
        #expect(!again)
    }

    @Test func 忽略的建议在重新纠错后保留_不再出现() throws {
        var t = corrected()
        t.ignore(october)
        t.resetForRecorrection()
        let review = CorrectionReview(texts: ["s1": "我们要避免被动"], suggestions: [october], rejections: [:])
        try t.applyCorrection(CorrectionResult(snapshot: t, review: review, engine: "llama/qwen3.5-4b-q4km",
                                               createdAt: created, hotwords: []))
        #expect(t.sentences[0].text == "我们要避免被动")
        #expect(t.numberSuggestions.isEmpty)
        #expect(t.correction?.suggestions.count == 1)
    }

    @Test func 重新纠错前_采纳过的建议也撤销() {
        var t = corrected()
        t.adopt(october)
        t.resetForRecorrection()
        #expect(t.sentences[1].text == "十月底上线")
        #expect(t.correction?.suggestions.isEmpty == true)
    }

    @Test func 重新纠错不碰手动改过的句子() {
        var t = corrected()
        t.edit(sentence: "s1", to: "我们要避免被动局面")
        t.resetForRecorrection()
        let s = t.sentences[0]
        #expect(s.text == "我们要避免被动局面")
        #expect(s.original == "我们要避免被动")
        #expect(t.editCount == 1)
    }

    // MARK: - 转写稿菜单

    private func menu(_ transcript: Transcript?, state: CorrectionState? = nil, available: Bool = true,
                      editable: Bool = true) -> CorrectionMenuItem {
        CorrectionMenuItem(transcript: transcript, state: state, isAvailable: available, isEditable: editable)
    }

    @Test func 没纠错过是纠错_纠错过是重新纠错() {
        var plain = corrected()
        plain.correction = nil
        plain.undoAllCorrections()
        #expect(menu(plain).title == "纠错")
        #expect(menu(corrected(), state: CorrectionState(status: .done)).title == "重新纠错")
        // 撤销全部后仍是纠错过的
        var undone = corrected()
        undone.undoAllCorrections()
        #expect(menu(undone, state: CorrectionState(status: .done)).title == "重新纠错")
    }

    @Test func 开关关着也能点_排队或进行中不能点() {
        #expect(menu(corrected()).isEnabled)
        #expect(menu(corrected(), state: CorrectionState(status: .failed)).isEnabled)
        #expect(!menu(corrected(), state: CorrectionState(status: .queued)).isEnabled)
        #expect(!menu(corrected(), state: CorrectionState(status: .running)).isEnabled)
    }

    @Test func 引擎不支持_转写中_没有句子时不能点() {
        #expect(!menu(corrected(), available: false).isEnabled)
        #expect(!menu(corrected(), editable: false).isEnabled)
        #expect(!menu(nil).isEnabled)
        let empty = Transcript(engine: "e", createdAt: created, hotwords: [], items: [])
        #expect(!menu(empty).isEnabled)
    }

    @Test func 重新纠错要先复位() {
        #expect(menu(corrected(), state: CorrectionState(status: .done)).resets)
        var plain = corrected()
        plain.correction = nil
        #expect(!menu(plain).resets)
    }

    // MARK: - 下游

    @Test func 撤销一句或采纳建议后_纪要显示转写稿有修改() {
        let t = corrected()
        let minutes = Minutes(model: "fake", template: "general", createdAt: created,
                              source: MinutesSource(transcriptCreatedAt: t.createdAt, textHash: t.textHash),
                              sections: [])
        var undone = t
        undone.undoCorrection(sentence: "s1")
        #expect(minutes.sync(with: undone, meeting: nil) == .edited)
        var adopted = t
        adopted.adopt(october)
        #expect(minutes.sync(with: adopted, meeting: nil) == .edited)
    }

    @Test func 复制全文用改后的文字_未采纳的数字建议不算() {
        var t = corrected()
        #expect(t.plainText(meeting: nil) == "[00:00] 我们要避免被动\n[00:01] 十月底上线")
        t.adopt(october)
        #expect(t.plainText(meeting: nil) == "[00:00] 我们要避免被动\n[00:01] 四月底上线")
    }
}
