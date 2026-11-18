import Testing
@testable import FaymeeCore

/// 纠错护栏（spec「护栏」「测试决定」护栏：换字词与数字部分；在线的补字、删字见 OnlineCorrectionGuardTests）
@Suite struct CorrectionGuardTests {
    /// 一份转写稿快照：每个字符串一句，id 依次是 s1、s2……
    private func sentences(_ texts: [String]) -> [TranscriptSentence] {
        texts.enumerated().map { TranscriptSentence(id: "s\($0 + 1)", start: Double($0), end: Double($0) + 1, text: $1) }
    }

    /// 本机换字词：只给 s1 一句可改，其余句子是转写稿的别处
    private func review(_ fixes: [WordFix], in texts: [String], editable: Set<String> = ["s1"],
                        hotwords: [String] = [], speakerNames: [String] = [], title: String = "",
                        sentences given: [TranscriptSentence]? = nil) -> CorrectionReview {
        let all = given ?? sentences(texts)
        let references = ReferenceWords(hotwords: hotwords, speakerNames: speakerNames, title: title, sentences: all)
        return reviewWordFixes(fixes, context: CorrectionContext(scope: .wordsOnly, editable: editable,
                                                                 sentences: all, references: references))
    }

    private func fix(_ from: String, _ to: String, id: String = "s1") -> WordFix {
        WordFix(id: id, from: from, to: to)
    }

    // MARK: 应过

    @Test(arguments: [
        ("我们要避免对动的局面", "对动", "被动", "我们要避免被动的局面"),
        ("他在工会上说了这件事", "工会上", "工位上", "他在工位上说了这件事"),
        ("我们做一个端道的方案", "端道的", "端到端", "我们做一个端到端方案"),
        ("请公老师来讲一下", "公老师", "龚老师", "请龚老师来讲一下"),
        ("我们用long chain搭了原型", "long chain", "LangChain", "我们用LangChain搭了原型"),
    ])
    func 读音相近的换字词直接应用(text: String, from: String, to: String, corrected: String) {
        let r = review([fix(from, to)], in: [text])
        #expect(r.texts == ["s1": corrected])
        #expect(r.rejections.isEmpty)
    }

    @Test func 自然体改智能体_别处出现两次智能体时过() {
        let r = review([fix("自然体", "智能体")],
                       in: ["这个自然体能自己调用工具", "智能体要能规划", "下一步做智能体的评测"])
        #expect(r.texts == ["s1": "这个智能体能自己调用工具"])
    }

    @Test func 自然体改智能体_别处没有智能体时不过() {
        let r = review([fix("自然体", "智能体")], in: ["这个自然体能自己调用工具", "智能体要能规划"])
        #expect(r.texts.isEmpty)
        #expect(r.rejections == [CorrectionRule.pinyin.rawValue: 1])
    }

    @Test func 改成热词_已命名说话人_会议标题里的词时放宽到零点五() {
        let text = "这个自然体能自己调用工具"
        #expect(review([fix("自然体", "智能体")], in: [text], hotwords: ["智能体"]).texts.count == 1)
        #expect(review([fix("自然体", "智能体")], in: [text], speakerNames: ["智能体"]).texts.count == 1)
        #expect(review([fix("自然体", "智能体")], in: [text], title: "智能体评审会").texts.count == 1)
    }

    @Test func 转写稿别处的参考词是整词_代词_虚词不算() {
        let others = ["我们这个方案先放一放", "这个我们下周再说", "下一步做智能体的评测", "智能体要能规划"]
        let references = ReferenceWords(hotwords: [], speakerNames: [], title: "",
                                        sentences: sentences(["s1 占位"] + others))
        // 「我们」「这个」别处各出现了两次，但不是有意义的词
        #expect(references.match(in: "我们来", covering: 0..<2, sentence: "s1") == nil)
        #expect(references.match(in: "这个来", covering: 0..<2, sentence: "s1") == nil)
        // 分词时「智能体」是「智能|体」两个词，连起来照样算
        #expect(references.match(in: "这个智能体", covering: 2..<5, sentence: "s1") == 2..<5)
        // 词中间切出来的片段不算
        #expect(references.match(in: "能体", covering: 0..<2, sentence: "s1") == nil)
    }

    @Test(arguments: [
        ("他们下午过来", "他们", "我们", ["我们下午开会", "我们先过一遍"]),
        ("他是说明天来", "是说", "不说", ["他不说明天的事", "我们不说这个"]),
    ])
    func 改成别处出现过的虚词_不放宽拼音(text: String, from: String, to: String, others: [String]) {
        let r = review([fix(from, to)], in: [text] + others)
        #expect(r.texts.isEmpty)
        #expect(r.rejections == [CorrectionRule.pinyin.rawValue: 1])
    }

    @Test func 单字不算参考词() {
        // 的→了 拼音比 0.5：单字参考词会把它放过去
        let r = review([fix("的", "了")], in: ["好的我们开始", "了", "了"], hotwords: ["了"])
        #expect(r.texts.isEmpty)
    }

    // MARK: 应挡

    @Test func 改写整句不过() {
        let r = review([fix("我们下周再讨论这个方案", "这个方案下次会议再说吧")], in: ["我们下周再讨论这个方案"])
        #expect(r.texts.isEmpty)
        #expect(r.rejections.values.reduce(0, +) == 1)
    }

    @Test func 改成读音不近的词不过() {
        let r = review([fix("重庆", "重要")], in: ["我们下个月去重庆出差"])
        #expect(r.texts.isEmpty)
        #expect(r.rejections == [CorrectionRule.pinyin.rawValue: 1])
    }

    @Test func 模型多带上下文也按改动处判读音_不被稀释() {
        // 整条「去重庆了」→「去重要了」的拼音比只有 0.31；最小改动「庆→要」扩到三个字是 0.36
        let r = review([fix("去重庆了", "去重要了")], in: ["他们下个月去重庆了"])
        #expect(r.texts.isEmpty)
    }

    @Test func from不在原句或出现两次不过() {
        let missing = review([fix("被动", "主动")], in: ["我们要避免对动的局面"])
        #expect(missing.texts.isEmpty)
        #expect(missing.rejections == [CorrectionRule.source.rawValue: 1])
        let twice = review([fix("对动", "被动")], in: ["对动和对动"])
        #expect(twice.texts.isEmpty)
        #expect(twice.rejections == [CorrectionRule.source.rawValue: 1])
    }

    @Test func 改手动修改过的句子不过() {
        let edited = [TranscriptSentence(id: "s1", start: 0, end: 1, text: "我们要避免对动的局面", original: "原文")]
        let r = review([fix("对动", "被动")], in: [], sentences: edited)
        #expect(r.texts.isEmpty)
        #expect(r.rejections == [CorrectionRule.notEditable.rawValue: 1])
    }

    @Test func 改只读上下文不过() {
        let r = review([fix("对动", "被动", id: "s2")], in: ["第一句", "我们要避免对动的局面"], editable: ["s1"])
        #expect(r.texts.isEmpty)
        #expect(r.rejections == [CorrectionRule.notEditable.rawValue: 1])
    }

    @Test func 本机不收补字和删字() {
        let insert = review([fix("避免对动", "避免这种对动")], in: ["我们要避免对动的局面"])
        #expect(insert.texts.isEmpty)
        #expect(insert.rejections == [CorrectionRule.scope.rawValue: 1])
        let delete = review([fix("的局面", "局面")], in: ["我们要避免对动的局面"])
        #expect(delete.texts.isEmpty)
        #expect(delete.rejections == [CorrectionRule.scope.rawValue: 1])
    }

    @Test func 一句里有一处不过_整句的修改都丢弃() {
        let r = review([fix("对动", "被动"), fix("局面", "重要")], in: ["我们要避免对动的局面"])
        #expect(r.texts.isEmpty)
        #expect(r.rejections == [CorrectionRule.pinyin.rawValue: 1])
    }

    @Test func 同一句的几处都过时一起应用() {
        let r = review([fix("对动", "被动"), fix("工会上", "工位上")], in: ["工会上大家都很对动"])
        #expect(r.texts == ["s1": "工位上大家都很被动"])
    }

    // MARK: 数字

    @Test func 十月改四月转为建议_不应用() {
        let r = review([fix("十月", "四月")], in: ["我们十月底上线"])
        #expect(r.texts.isEmpty)
        #expect(r.suggestions == [NumberSuggestion(sentence: "s1", from: "十月", to: "四月")])
        #expect(r.rejections.isEmpty)
    }

    @Test func 数字建议拼音不近且别处没出现时丢弃() {
        let r = review([fix("十月", "八月")], in: ["我们十月底上线"])
        #expect(r.suggestions.isEmpty)
        #expect(r.rejections == [CorrectionRule.number.rawValue: 1])
    }

    @Test func 数字建议拼音不近但改后的数字在别处出现过时保留() {
        let r = review([fix("十月", "八月")], in: ["我们十月底上线", "八月要交付"])
        #expect(r.suggestions == [NumberSuggestion(sentence: "s1", from: "十月", to: "八月")])
    }

    @Test func 同一句里的非数字修改照常应用() {
        let r = review([fix("十月", "四月"), fix("对动", "被动")], in: ["十月底之前别太对动"])
        #expect(r.texts == ["s1": "十月底之前别太被动"])
        #expect(r.suggestions == [NumberSuggestion(sentence: "s1", from: "十月", to: "四月")])
    }

    // MARK: 改动比例（规则 6，本机只换读音相近的字词时不会触发，03 的补字、删字会用到）

    @Test func 改动比例_十字以上不超过百分之三十_不到十字最多三个字() {
        #expect(!exceedsChangeRatio(changed: 6, sentence: "一二三四五六七八九十一二三四五六七八九十"))
        #expect(exceedsChangeRatio(changed: 7, sentence: "一二三四五六七八九十一二三四五六七八九十"))
        #expect(!exceedsChangeRatio(changed: 3, sentence: "我们开会吧"))
        #expect(exceedsChangeRatio(changed: 4, sentence: "我们开会吧"))
        // 标点、空白不算字数
        #expect(exceedsChangeRatio(changed: 6, sentence: "一二三四五六七八九十一二三四五六七八九，"))
    }
}
