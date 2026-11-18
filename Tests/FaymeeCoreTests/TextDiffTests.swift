import Testing
@testable import FaymeeCore

/// 纠错前后文字的字符级比对（spec「输入与输出」最后一条、「测试决定」比对）
@Suite struct TextDiffTests {
    private func shape(_ diff: TextDiff) -> [String] {
        diff.segments.map { "\($0.kind) \($0.before)→\($0.after)" }
    }

    @Test func 整句改写切成替换_补字_删字各处() {
        let diff = TextDiff(from: "我们讨论对动的那个问题", to: "我们来讨论被动那个问题吧")
        #expect(shape(diff) == ["insert →来", "replace 对→被", "delete 的→", "insert →吧"])
    }

    @Test func 各处带着在原文和改后文字里的字符位置() {
        let diff = TextDiff(from: "我们讨论对动的那个问题", to: "我们来讨论被动那个问题吧")
        #expect(diff.segments.map(\.beforeRange) == [2..<2, 4..<5, 6..<7, 11..<11])
        #expect(diff.segments.map(\.afterRange) == [2..<3, 5..<6, 7..<7, 11..<12])
    }

    @Test func 标点单独成一处_不算补字删字() {
        let diff = TextDiff(from: "好的，我们开始吧", to: "好的我们开始吧。")
        #expect(shape(diff) == ["punctuation ，→", "punctuation →。"])
    }

    @Test func 同一处里的标点和文字分开() {
        let diff = TextDiff(from: "开会，好", to: "开会了。好")
        #expect(shape(diff) == ["punctuation ，→。", "insert →了"])
    }

    @Test func 英文按词比对_词间空格跟着文字走() {
        let diff = TextDiff(from: "用long chain搭", to: "用LangChain搭")
        #expect(shape(diff) == ["replace long chain→LangChain"])
    }

    @Test func 没改时没有任何一处() {
        #expect(TextDiff(from: "一样的话", to: "一样的话").segments.isEmpty)
    }

    @Test func 只应用选中的几处() {
        let diff = TextDiff(from: "我们讨论对动的那个问题", to: "我们来讨论被动那个问题吧")
        let replace = diff.segments.filter { $0.kind == .replace }
        #expect(diff.applying(replace) == "我们讨论被动的那个问题")
        #expect(diff.applying(diff.segments) == "我们来讨论被动那个问题吧")
        #expect(diff.applying([]) == "我们讨论对动的那个问题")
    }
}
