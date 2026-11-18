import Testing
@testable import FaymeeCore

/// 纠错评估的计分（ticket 04）：字错率、改对 / 改坏的句子
@Suite struct CorrectionScoreTests {
    @Test func 改对一处_字错率下降_这句算改对() {
        let score = CorrectionScore(before: ["我们要避免对动的局面"], after: ["我们要避免被动的局面"],
                                    reference: "我们要避免被动的局面")
        #expect(score.referenceLength == 10)
        #expect(score.errorsBefore == 1)
        #expect(score.errorsAfter == 0)
        #expect(score.improved == 1)
        #expect(score.broken == 0)
    }

    @Test func 句子和标准稿的行对不齐时照样按整段比() {
        // 转写模型断句不同：标准稿一行被拆成两句
        let score = CorrectionScore(before: ["我们要避免", "对动的局面", "好的"], after: ["我们要避免", "被动的局面", "好的"],
                                    reference: "我们要避免被动的局面。\n好的。")
        #expect(score.referenceLength == 12)
        #expect(score.errorsBefore == 1)
        #expect(score.errorsAfter == 0)
        #expect(score.improved == 1)
    }

    @Test func 一句改对一句改坏_分开算() {
        let score = CorrectionScore(before: ["他在工会上说了", "测试机下周还"], after: ["他在工位上说了", "测试机下周换"],
                                    reference: "他在工位上说了。测试机下周还。")
        #expect(score.errorsBefore == 1)
        #expect(score.errorsAfter == 1)
        #expect(score.changed == 2)
        #expect(score.improved == 1)
        #expect(score.broken == 1)
        #expect(score.deltas == [0: -1, 1: 1])
    }

    @Test func 只改标点和大小写不算字错_全对的稿子里任何修改都算改坏() {
        let before = ["我们用 langchain 搭的流程"]
        let after = ["我们用LangChain搭的流程。"]
        let normal = CorrectionScore(before: before, after: after, reference: "我们用LangChain搭的流程")
        #expect(normal.errorsBefore == 0)
        #expect(normal.neutral == 1)
        #expect(normal.broken == 0)
        let clean = CorrectionScore(before: before, after: after, reference: "我们用LangChain搭的流程", clean: true)
        #expect(clean.broken == 1)
    }

    @Test func 删成空句的重复句算改对() {
        let score = CorrectionScore(before: ["测试机下周要还", "测试机下周要还"], after: ["测试机下周要还", ""],
                                    reference: "测试机下周要还")
        #expect(score.errorsBefore == 7)
        #expect(score.errorsAfter == 0)
        #expect(score.improved == 1)
    }
}
