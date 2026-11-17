import Testing
@testable import FaymeeCore

@Suite struct ParaformerTextTests {
    // MARK: 英文字母合并

    @Test(arguments: [
        ("a i", "AI"),
        ("t r", "TR"),
        ("d r flow", "DR flow"),
        // 以下是真实会议里 Paraformer 的输出片段
        ("腾讯那个 a i pass。", "腾讯那个 AI pass。"),
        ("还没有 oo k o k 那就还好", "还没有 oo KOK 那就还好"),
        ("做一个 o i d c 的对接", "做一个 OIDC 的对接"),
        ("哪个嘛？a i款a i看。", "哪个嘛？AI款AI看。"),
    ])
    func 连续的单个小写字母合并并转大写(raw: String, expected: String) {
        #expect(ParaformerText.mergeLetters(raw) == expected)
    }

    @Test(arguments: [
        "ok ok 行",
        "比如说 long long long unch",
        "你要调 a 是调工具",
        "a，i",
        "AI 网关",
    ])
    func 单词_单独一个字母_被标点隔开的字母都不动(text: String) {
        #expect(ParaformerText.mergeLetters(text) == text)
    }

    // MARK: 标点并回

    @Test func 标点按字序插回原文() {
        #expect(ParaformerText.restorePunctuation(raw: "大家好今天我们讨论一下", punctuated: "大家好，今天我们讨论一下。")
            == "大家好，今天我们讨论一下。")
    }

    @Test func 保留原文英文前后的空格_中文标点后不留空格() {
        #expect(ParaformerText.restorePunctuation(raw: "我这个 ppt 你点一下", punctuated: "我这个ppt，你点一下。")
            == "我这个 ppt，你点一下。")
        #expect(ParaformerText.restorePunctuation(raw: "那个 a i pass 那现在", punctuated: "那个a i pass。那现在")
            == "那个 a i pass。那现在")
    }

    @Test func 标点模型改了大小写也用原文的字() {
        #expect(ParaformerText.restorePunctuation(raw: "ok ok 行", punctuated: "OK OK，行。") == "ok ok，行。")
    }

    @Test func 原文自带的撇号照原文保留() {
        #expect(ParaformerText.restorePunctuation(raw: "i don't know 啊", punctuated: "i don't know啊。")
            == "i don't know 啊。")
        #expect(ParaformerText.restorePunctuation(raw: "i don't know 啊", punctuated: "i dont know啊。")
            == "i don't know 啊。")
    }

    @Test func 开头的标点丢掉() {
        #expect(ParaformerText.restorePunctuation(raw: "大家好", punctuated: "，大家好。") == "大家好。")
    }

    @Test(arguments: [
        ("大家好", "大家好啊。"), // 多了字
        ("大家好啊", "大家好。"), // 少了字
        ("大家好", "大家号。"), // 改了字
    ])
    func 标点模型改了字就放弃标点_用原文(raw: String, punctuated: String) {
        #expect(ParaformerText.restorePunctuation(raw: raw, punctuated: punctuated) == raw)
    }
}
