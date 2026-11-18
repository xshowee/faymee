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
}
