import Testing
@testable import FaymeeCore

/// 在线整句改写过护栏（spec「护栏」4–7，「测试决定」护栏里的补字、删字、口吃保留、改动比例）。
/// 都用真实的整句改写走 `reviewCorrections`，切分交给 `TextDiff`
@Suite struct OnlineCorrectionGuardTests {
    /// 一份转写稿快照：每个字符串一句，id 依次是 s1、s2……
    private func sentences(_ texts: [String], speakers: [String?]? = nil) -> [TranscriptSentence] {
        texts.enumerated().map {
            TranscriptSentence(id: "s\($0 + 1)", start: Double($0), end: Double($0) + 1, text: $1, speaker: speakers?[$0])
        }
    }

    /// 在线整句改写：`rewrites` 是句子 id → 改后的整句，默认全部句子可改
    private func review(_ rewrites: [String: String], in texts: [String], editable: Set<String>? = nil,
                        hotwords: [String] = [], speakers: [String?]? = nil) -> CorrectionReview {
        let all = sentences(texts, speakers: speakers)
        let references = ReferenceWords(hotwords: hotwords, speakerNames: [], title: "", sentences: all)
        let changes = all.compactMap { s in
            rewrites[s.id].map { CorrectionChange(sentenceID: s.id, offset: 0, before: s.text, after: $0) }
        }
        return reviewCorrections(changes, context: CorrectionContext(
            scope: .full, editable: editable ?? Set(all.map(\.id)), sentences: all, references: references))
    }

    // MARK: 空白

    @Test func 只加减空白的地方不应用_同一句的其他修改照常() {
        // deepseek-flash 常在中英文之间加空格（「AI干」→「AI 干」），这是润色，不显示成纠错
        let r = review(["s1": "用 AI 干这个活，我们要避免被动", "s2": "用 AI 干这个活"],
                       in: ["用AI干这个活，我们要避免对动", "用AI干这个活"])
        #expect(r.texts == ["s1": "用AI干这个活，我们要避免被动"])
        #expect(r.rejections.isEmpty)
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

    // MARK: 删字（规则 5）

    @Test(arguments: [
        ("好的 [breath] 我们开始", "好的我们开始"),
        ("调 agent [breath] 的接口", "调 agent 的接口"),
        ("我们先 /sil 看一下", "我们先看一下"),
    ])
    func 删标记过(text: String, corrected: String) {
        let r = review(["s1": corrected], in: [text])
        #expect(r.texts == ["s1": corrected])
        #expect(r.rejections.isEmpty)
    }

    @Test(arguments: [
        ("那我们就开始吧吧吧吧吧吧", "那我们就开始吧"),
        ("好的好的好的好的好的我们开始", "好的我们开始"),
        ("好的，好的，好的，好的，好的，我们开始", "好的，我们开始"),
    ])
    func 删连续重复五次以上的复读_保留一次过(text: String, corrected: String) {
        let r = review(["s1": corrected], in: [text])
        #expect(r.texts == ["s1": corrected])
        #expect(r.rejections.isEmpty)
    }

    @Test func 复读删得一次不留不过() {
        let r = review(["s1": "那我们就开始"], in: ["那我们就开始吧吧吧吧吧吧"])
        #expect(r.texts.isEmpty)
        #expect(r.rejections == [CorrectionRule.deletion.rawValue: 1])
    }

    @Test func 只重复四次不算复读残留() {
        let r = review(["s1": "那我们就开始吧"], in: ["那我们就开始吧吧吧吧"])
        #expect(r.texts.isEmpty)
        #expect(r.rejections == [CorrectionRule.deletion.rawValue: 1])
    }

    @Test(arguments: [
        ("我我我觉得可以", "我觉得可以"),
        ("就是就是这个问题", "就是这个问题"),
        ("嗯我们开始吧", "我们开始吧"),
        ("那个接口还没好", "接口还没好"),
        ("接口还没有准备好", "接口没有准备好"),
    ])
    func 口吃和口语词不删(text: String, corrected: String) {
        let r = review(["s1": corrected], in: [text])
        #expect(r.texts.isEmpty)
        #expect(r.rejections == [CorrectionRule.deletion.rawValue: 1])
    }

    @Test func 与上一句完全相同的整句重复可以删成空句() {
        let r = review(["s2": ""], in: ["我们下周发布", "我们下周发布", "好的"])
        #expect(r.texts == ["s2": ""])
        #expect(r.rejections.isEmpty)
    }

    @Test func 删整句只认与上一句相同_两句不会都删掉() {
        let r = review(["s1": "", "s2": ""], in: ["我们下周发布", "我们下周发布"])
        #expect(r.texts == ["s2": ""])
        #expect(r.rejections == [CorrectionRule.deletion.rawValue: 1])
    }

    @Test func 两个人各说一句相同的话不算整句重复() {
        let r = review(["s2": ""], in: ["好的", "好的"], speakers: ["spk1", "spk2"])
        #expect(r.texts.isEmpty)
        #expect(r.rejections == [CorrectionRule.deletion.rawValue: 1])
        #expect(review(["s2": ""], in: ["好的", "好的"], speakers: ["spk1", "spk1"]).texts == ["s2": ""])
    }

    @Test func 与相邻句不同的整句不能删() {
        let r = review(["s2": ""], in: ["我们下周发布", "我们下周再发布"])
        #expect(r.texts.isEmpty)
        #expect(r.rejections == [CorrectionRule.deletion.rawValue: 1])
    }

    // MARK: 数字（规则 7）

    @Test func 改数字转为建议_不应用() {
        let r = review(["s1": "我们四月底上线"], in: ["我们十月底上线"])
        #expect(r.texts.isEmpty)
        #expect(r.suggestions == [NumberSuggestion(sentence: "s1", from: "十月", to: "四月")])
    }

    @Test func 补数字也转为建议() {
        let r = review(["s1": "我们十一月底上线"], in: ["我们十月底上线"])
        #expect(r.texts.isEmpty)
        #expect(r.suggestions == [NumberSuggestion(sentence: "s1", from: "十月", to: "十一月")])
    }

    @Test func 同一句里的非数字修改照常应用() {
        let r = review(["s1": "我们四月底之前别太被动"], in: ["我们十月底之前别太对动"])
        #expect(r.texts == ["s1": "我们十月底之前别太被动"])
        #expect(r.suggestions == [NumberSuggestion(sentence: "s1", from: "十月", to: "四月")])
    }

    @Test func 建议的原文在句子里只出现一次_采纳时换得到模型改的那处() throws {
        let text = "我们三点开会，三点半结束"
        let r = review(["s1": "我们四点开会，三点半结束"], in: [text])
        let suggestion = try #require(r.suggestions.first)
        #expect(r.suggestions.count == 1)
        #expect(text.occurrences(of: suggestion.from) == 1)
        #expect(text.replacingOccurrences(of: suggestion.from, with: suggestion.to) == "我们四点开会，三点半结束")
    }

    // MARK: 改动比例（规则 6）

    @Test func 补字超过改动比例不过_含不到十字的短句() {
        // 5 个字的短句最多改 3 个字
        #expect(review(["s1": "我们了开了会了吧"], in: ["我们开会吧"]).texts.count == 1)
        let short = review(["s1": "我了们了开了会了吧"], in: ["我们开会吧"])
        #expect(short.texts.isEmpty)
        #expect(short.rejections == [CorrectionRule.changeRatio.rawValue: 1])
        // 12 个字最多改 3 个字（30% 向下取整）
        let long = review(["s1": "这了个方了案我了们下周再了讨论一下"], in: ["这个方案我们下周再讨论一下"])
        #expect(long.texts.isEmpty)
        #expect(long.rejections == [CorrectionRule.changeRatio.rawValue: 1])
    }

    @Test func 识别残留的删除和过了拼音校验的替换不计入改动比例() {
        let r = review(["s1": "开始吧"], in: ["开始吧吧吧吧吧吧"])
        #expect(r.texts == ["s1": "开始吧"])
        // 12 个字最多改 3 个字，这里换了 4 个字，都过了拼音校验
        let replace = review(["s1": "工位上说端到端方案很被动"], in: ["工会上说端道的方案很对动"])
        #expect(replace.texts == ["s1": "工位上说端到端方案很被动"])
    }

    // MARK: 应挡（在线也一样）

    @Test func 改写整句_改说法不过() {
        let r = review(["s1": "这个方案下次会议再说吧"], in: ["我们下周再讨论这个方案"])
        #expect(r.texts.isEmpty)
        #expect(r.rejections.values.reduce(0, +) == 1)
    }

    @Test func 改只读上下文不过() {
        let r = review(["s1": "我们要避免被动的局面"], in: ["我们要避免对动的局面", "第二句"], editable: ["s2"])
        #expect(r.texts.isEmpty)
        #expect(r.rejections == [CorrectionRule.notEditable.rawValue: 1])
    }

    // MARK: 识别残留里有数字字符

    @Test func 含数字字符的识别残留照删_不转为建议() {
        let duplicate = review(["s2": ""], in: ["我们看一下数据", "我们看一下数据"])
        #expect(duplicate.texts == ["s2": ""])
        #expect(duplicate.suggestions.isEmpty)
        let repeated = review(["s1": "等一下我们开始"], in: ["等一下等一下等一下等一下等一下我们开始"])
        #expect(repeated.texts == ["s1": "等一下我们开始"])
        #expect(repeated.rejections.isEmpty)
    }

    @Test func 全是数字的复读不算识别残留_按数字处理不删() {
        // 「五五五五五」可能是真的编号；读音不近、别处也没有「五」，建议也丢弃
        let r = review(["s1": "编号是五"], in: ["编号是五五五五五"])
        #expect(r.texts.isEmpty)
        #expect(r.rejections == [CorrectionRule.number.rawValue: 1])
    }

    @Test func 删掉数字的建议_建议的写法不为空() throws {
        let r = review(["s1": "这是第步了"], in: ["这是第一步了"])
        let suggestion = try #require(r.suggestions.first)
        #expect(!suggestion.to.isEmpty)
        #expect("这是第一步了".replacingOccurrences(of: suggestion.from, with: suggestion.to) == "这是第步了")
    }
}
