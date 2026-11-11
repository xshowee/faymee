import Foundation
import Testing
@testable import FaymeeCore

/// SpeechTranscriber 只给出约 20 秒一段的结果，标点稀少，逐字带时间。
/// 断句器把逐字结果切成适合一行展示、点击跳转的句子
@Suite struct SentenceSplitterTests {
    private func tokens(_ list: [(String, Double, Double)]) -> [TimedToken] {
        list.map { TimedToken(text: $0.0, start: $0.1, end: $0.2) }
    }

    @Test func 在句末标点处断句() {
        let input = tokens([("你", 0, 0.2), ("好", 0.2, 0.4), ("。", 0.4, 0.5),
                            ("开", 0.5, 0.7), ("始", 0.7, 0.9), ("吧", 0.9, 1.1), ("！", 1.1, 1.2)])

        #expect(SentenceSplitter.split(input) == [
            TranscribedSentence(start: 0, end: 0.5, text: "你好。"),
            TranscribedSentence(start: 0.5, end: 1.2, text: "开始吧！"),
        ])
    }

    /// 实时字幕边收边断句：一段定稿结果末尾没说完的半句先留着，和下一段的字拼起来再断
    @Test func 末尾没说完的半句留给下一段() {
        let first = SentenceSplitter.splitKeepingOpen(tokens([
            ("你", 0, 0.2), ("好", 0.2, 0.4), ("。", 0.4, 0.5), ("开", 0.5, 0.7), ("始", 0.7, 0.9),
        ]))
        #expect(first.closed == [TranscribedSentence(start: 0, end: 0.5, text: "你好。")])
        #expect(first.open == tokens([("开", 0.5, 0.7), ("始", 0.7, 0.9)]))

        let second = SentenceSplitter.splitKeepingOpen(first.open + tokens([("吧", 0.9, 1.1), ("！", 1.1, 1.2)]))
        #expect(second.closed == [TranscribedSentence(start: 0.5, end: 1.2, text: "开始吧！")])
        #expect(second.open.isEmpty)
    }

    /// 本机流式识别的真实情形：上一段定稿结果没带句号，句号出现在下一段开头，与前一个字隔了 0.42 秒。
    /// 句号接到前一句，前一句仍在最后一个字处结束，中间的静音不算进去
    @Test func 停顿后紧跟的标点归前一句_不单独成句() {
        let input = tokens([("一", 32.4, 32.7), ("周", 32.7, 32.88), ("左", 32.88, 32.94), ("右", 32.94, 33.06),
                            ("。", 33.48, 33.66), ("明", 33.66, 33.9), ("白", 33.9, 34.1), ("了", 34.1, 34.3)])

        #expect(SentenceSplitter.split(input) == [
            TranscribedSentence(start: 32.4, end: 33.06, text: "一周左右。"),
            TranscribedSentence(start: 33.66, end: 34.3, text: "明白了"),
        ])
    }

    /// 停顿后的逗号同样归前一句，但静音处仍要断开：不能让一句话横跨真正的静音
    @Test func 停顿后紧跟的逗号归前一句_静音处仍断开() {
        let input = tokens([("一", 32.4, 32.7), ("周", 32.7, 32.88), ("左", 32.88, 32.94), ("右", 32.94, 33.06),
                            ("，", 33.48, 33.66), ("明", 33.66, 33.9), ("白", 33.9, 34.1), ("了", 34.1, 34.3)])

        #expect(SentenceSplitter.split(input) == [
            TranscribedSentence(start: 32.4, end: 33.06, text: "一周左右，"),
            TranscribedSentence(start: 33.66, end: 34.3, text: "明白了"),
        ])
    }

    /// 开引号、开括号属于后面的话：停顿后紧跟的开引号不接到前一句，而是开始下一句
    @Test func 停顿后的开引号开始下一句() {
        let input = tokens([("他", 0, 0.2), ("说", 0.2, 0.4),
                            ("“", 1.0, 1.0), ("我", 1.0, 1.2), ("们", 1.2, 1.4), ("下", 1.4, 1.6), ("周", 1.6, 1.8),
                            ("发", 1.8, 2.0), ("布", 2.0, 2.2), ("”", 2.2, 2.2), ("。", 2.2, 2.3)])

        #expect(SentenceSplitter.split(input) == [
            TranscribedSentence(start: 0, end: 0.4, text: "他说"),
            TranscribedSentence(start: 1.0, end: 2.3, text: "“我们下周发布”。"),
        ])
    }

    /// 没有逐字时间的开引号紧接在前一个字后面（见 `SpeechAnalyzerTranscriber.token`），停顿落在它后面：
    /// 断开时开引号仍归后面的话，下一句从它后面那个字的时间开始
    @Test func 停顿前没有时间的开引号也归下一句() {
        let input = tokens([("他", 0, 0.2), ("说", 0.2, 0.4), ("“", 0.4, 0.4),
                            ("我", 1.0, 1.2), ("们", 1.2, 1.4), ("下", 1.4, 1.6), ("周", 1.6, 1.8),
                            ("发", 1.8, 2.0), ("布", 2.0, 2.2), ("”", 2.2, 2.2), ("。", 2.2, 2.3)])
        let expected = [
            TranscribedSentence(start: 0, end: 0.4, text: "他说"),
            TranscribedSentence(start: 1.0, end: 2.3, text: "“我们下周发布”。"),
        ]

        #expect(SentenceSplitter.split(input) == expected)
        // 实时字幕分两段断：开引号留在第一段末尾没断完的半句里
        let first = SentenceSplitter.splitKeepingOpen(Array(input[..<3]))
        let second = SentenceSplitter.splitKeepingOpen(first.open + input[3...])
        #expect(first.closed + second.closed + (SentenceSplitter.sentence(second.open).map { [$0] } ?? []) == expected)
    }

    /// 同上，停顿并在后一个字的时间里（已有足够多的字，在这个字前面断）
    @Test func 长字前没有时间的开括号也归下一句() {
        let input = tokens([("我", 0, 0.2), ("们", 0.2, 0.4), ("先", 0.4, 0.6), ("过", 0.6, 0.8), ("一", 0.8, 1.0),
                            ("下", 1.0, 1.2), ("（", 1.2, 1.2), ("草", 1.2, 1.8), ("案", 1.8, 2.0), ("）", 2.0, 2.0)])

        #expect(SentenceSplitter.split(input) == [
            TranscribedSentence(start: 0, end: 1.2, text: "我们先过一下"),
            TranscribedSentence(start: 1.2, end: 2.0, text: "（草案）"),
        ])
    }

    /// 停顿并在开括号的时间里时，停顿在它前面（同普通的字），不在它后面断开
    @Test func 开括号占得久时在它前面断句() {
        let input = tokens([("我", 0, 0.2), ("们", 0.2, 0.4), ("先", 0.4, 0.6), ("过", 0.6, 0.8), ("一", 0.8, 1.0),
                            ("下", 1.0, 1.2), ("（", 1.2, 1.8), ("草", 1.8, 2.0), ("案", 2.0, 2.2), ("）", 2.2, 2.2)])

        #expect(SentenceSplitter.split(input) == [
            TranscribedSentence(start: 0, end: 1.2, text: "我们先过一下"),
            TranscribedSentence(start: 1.2, end: 2.2, text: "（草案）"),
        ])
    }

    /// 流式识别里没有逐字时间的标点放在这段结果的开头，离前一个字隔着整段静音。
    /// 接到前一句时不把它的结束拉到静音之后，否则点击、高亮会把这段静音算进前一句
    @Test func 停顿后的标点接到前一句时不拉长它的结束() {
        let input = tokens([("一", 32.4, 32.7), ("周", 32.7, 32.88), ("左", 32.88, 32.94), ("右", 32.94, 33.06),
                            ("。", 38, 38), ("明", 38, 38.2), ("白", 38.2, 38.4), ("了", 38.4, 38.6)])

        #expect(SentenceSplitter.split(input) == [
            TranscribedSentence(start: 32.4, end: 33.06, text: "一周左右。"),
            TranscribedSentence(start: 38, end: 38.6, text: "明白了"),
        ])
    }

    @Test func 没有标点时在停顿处断句且不切出过短的片段() {
        // 本机真实输出（say -v Tingting「大家好，我们先过一下上周的待办。第二件事，下周三要和飞书团队开会。」）。
        // 停顿被并进下一个字的时间里：「第」「下」各占 0.48、0.6 秒，普通字 0.1–0.3 秒
        let input = tokens([
            ("大", 0.0, 0.24), ("家", 0.24, 0.36), ("好", 0.36, 0.6), (" ，", 0.6, 1.08),
            ("我", 1.08, 1.2), ("们", 1.2, 1.32), ("先", 1.32, 1.62), ("过", 1.62, 1.86), ("一", 1.86, 2.04),
            ("下", 2.04, 2.22), ("上", 2.22, 2.52), ("周", 2.52, 2.7), ("的", 2.7, 2.88), ("代", 2.88, 3.06),
            ("办", 3.06, 3.3), ("第", 3.3, 3.78), ("二", 3.78, 3.96), ("件", 3.96, 4.2), ("事", 4.2, 4.5),
            ("下", 4.5, 5.1), ("周", 5.1, 5.28), ("三", 5.28, 5.58), ("要", 5.58, 5.76), ("和", 5.76, 6.0),
            ("飞", 6.0, 6.24), ("书", 6.24, 6.48), ("团", 6.48, 6.72), ("队", 6.72, 6.9), ("开", 6.9, 7.2),
            ("会", 7.2, 7.38), ("。", 7.38, 7.6900625),
        ])

        #expect(SentenceSplitter.split(input) == [
            TranscribedSentence(start: 0, end: 3.3, text: "大家好，我们先过一下上周的代办"),
            TranscribedSentence(start: 3.3, end: 7.6900625, text: "第二件事下周三要和飞书团队开会。"),
        ])
    }

    @Test func 在两段结果之间的静音处断句() {
        let input = tokens([("我", 10, 10.2), ("们", 10.2, 10.4), ("看", 10.4, 10.6), ("一", 10.6, 10.8),
                            ("下", 10.8, 11.0), ("数", 11.0, 11.2), ("据", 11.2, 11.4),
                            ("好", 14, 14.2), ("的", 14.2, 14.4)])

        #expect(SentenceSplitter.split(input) == [
            TranscribedSentence(start: 10, end: 11.4, text: "我们看一下数据"),
            TranscribedSentence(start: 14, end: 14.4, text: "好的"),
        ])
    }
}
