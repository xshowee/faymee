import Testing
@testable import FaymeeCore

/// 在线整句改写过护栏（spec「护栏」4–7，「测试决定」护栏里的补字、删字、口吃保留、改动比例）。
/// 都用真实的整句改写走 `reviewCorrections`，切分交给 `TextDiff`
@Suite struct OnlineCorrectionGuardTests {
    /// 一份转写稿快照：每个字符串一句，id 依次是 s1、s2……
    private func sentences(_ texts: [String]) -> [TranscriptSentence] {
        texts.enumerated().map { TranscriptSentence(id: "s\($0 + 1)", start: Double($0), end: Double($0) + 1, text: $1) }
    }

    /// 在线整句改写：`rewrites` 是句子 id → 改后的整句，默认全部句子可改
    private func review(_ rewrites: [String: String], in texts: [String], editable: Set<String>? = nil,
                        hotwords: [String] = []) -> CorrectionReview {
        let all = sentences(texts)
        let references = ReferenceWords(hotwords: hotwords, speakerNames: [], title: "", sentences: all)
        let changes = all.compactMap { s in
            rewrites[s.id].map { CorrectionChange(sentenceID: s.id, offset: 0, before: s.text, after: $0) }
        }
        return reviewCorrections(changes, context: CorrectionContext(
            scope: .full, editable: editable ?? Set(all.map(\.id)), sentences: all, references: references))
    }

    // MARK: 补字（规则 4）

    @Test func 补单字不限来源() {
        let r = review(["s1": "这个方案我们下周再来讨论"], in: ["这个方案我们下周再讨论"])
        #expect(r.texts == ["s1": "这个方案我们下周再来讨论"])
        #expect(r.rejections.isEmpty)
    }

    @Test func 补两字以上_在前后五句里出现过时过() {
        let texts = ["支付接口下周联调", "第二句", "第三句", "第四句", "第五句", "我们先把接口准备好"]
        let r = review(["s6": "我们先把支付接口准备好"], in: texts)
        #expect(r.texts == ["s6": "我们先把支付接口准备好"])
    }

    @Test func 补两字以上_只在五句以外出现过时不过() {
        let texts = ["支付接口下周联调", "第二句", "第三句", "第四句", "第五句", "第六句", "我们先把接口准备好"]
        let r = review(["s7": "我们先把支付接口准备好"], in: texts)
        #expect(r.texts.isEmpty)
        #expect(r.rejections == [CorrectionRule.insertion.rawValue: 1])
    }

    @Test func 补两字以上_是参考词时过() {
        let r = review(["s1": "我们先把支付接口准备好"], in: ["我们先把接口准备好"], hotwords: ["支付"])
        #expect(r.texts == ["s1": "我们先把支付接口准备好"])
    }

    @Test func 补两字以上_没有来源时不过() {
        let r = review(["s1": "我们先把支付接口准备好"], in: ["我们先把接口准备好"])
        #expect(r.texts.isEmpty)
        #expect(r.rejections == [CorrectionRule.insertion.rawValue: 1])
    }

    /// 30 个字的句子：改动比例允许 9 个字，挡住的是补字合计
    private let long = "我们今天下午开会讨论下个版本发布时间支付接口还没有准备好需要再等"

    @Test func 每句补字合计不超过六个() {
        // 六处各补一个「了」
        let six = "我们今天下午了开会了讨论下个了版本发布了时间支付了接口还没有准备好了需要再等"
        #expect(review(["s1": six], in: [long]).texts == ["s1": six])
        let seven = "我们今天了下午了开会了讨论下个了版本发布了时间支付了接口还没有准备好了需要再等"
        let r = review(["s1": seven], in: [long])
        #expect(r.texts.isEmpty)
        #expect(r.rejections == [CorrectionRule.insertion.rawValue: 1])
    }
}
