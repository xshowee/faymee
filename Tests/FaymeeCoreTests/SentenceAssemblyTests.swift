import Foundation
import Testing
@testable import FaymeeCore

/// 每段的识别结果（文字 + 可选逐字开始时间）→ 带时间的句子
@Suite struct SentenceAssemblyTests {
    private func s(_ seconds: Double) -> Int { Int((seconds * 16000).rounded()) }

    private func segment(audio: Range<Double>, speech: Range<Double>) -> SpeechSegment {
        SpeechSegment(audio: s(audio.lowerBound)..<s(audio.upperBound), speech: s(speech.lowerBound)..<s(speech.upperBound))
    }

    private func timed(_ list: [(String, Double)]) -> [SegmentRecognition.Token] {
        list.map { SegmentRecognition.Token(text: $0.0, start: $0.1) }
    }

    /// 文字相同、时间相差不到 1 毫秒
    private func expectSentences(_ actual: [TranscribedSentence], _ expected: [(Double, Double, String)],
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.map(\.text) == expected.map(\.2), sourceLocation: sourceLocation)
        for (a, e) in zip(actual, expected) {
            #expect(abs(a.start - e.0) < 0.001 && abs(a.end - e.1) < 0.001, "\(a) ≠ \(e)", sourceLocation: sourceLocation)
        }
    }

    /// Paraformer：逐字开始时间相对这段音频开头；每个字到下一个字开始为止，最后一个字到说话部分结尾。
    /// 标点是标点模型加的，不在逐字结果里，按字的顺序对上
    @Test func 有逐字时间时按标点断句_字的结束取下一个字的开始() {
        let seg = segment(audio: 10..<16.5, speech: 10.3..<16.2)
        let result = SegmentRecognition(
            text: "好的，我先说一下。目前完成了百分之八十。",
            tokens: timed([("好", 0.30), ("的", 0.54), ("我", 0.94), ("先", 1.14), ("说", 1.38), ("一", 1.64),
                           ("下", 1.74), ("目", 3.44), ("前", 3.64), ("完", 4.90), ("成", 5.06), ("了", 5.30),
                           ("百", 5.50), ("分", 5.60), ("之", 5.78), ("八", 6.02), ("十", 6.12)]))

        expectSentences(SentenceAssembly.sentences([(seg, result)]), [
            (10.3, 13.44, "好的，我先说一下。"),
            (13.44, 16.2, "目前完成了百分之八十。"),
        ])
    }

    /// 停顿并进前一个字（「下」占到 3.44）也不在停顿前一个字处断句：sherpa 引擎不推断停顿
    @Test func 有逐字时间时不按长字断句() {
        let seg = segment(audio: 0..<8, speech: 0..<8)
        let result = SegmentRecognition(
            text: "我们来讨论一下下个季度的产品规划首先请各位看一下",
            tokens: timed(Array(zip("我们来讨论一下下个季度的产品规划首先请各位看一下".map(String.init),
                                    [1.58, 1.74, 1.92, 2.20, 2.38, 2.66, 2.80, 3.06, 3.28, 3.46, 3.64, 3.82, 3.90,
                                     4.10, 4.44, 4.64, 5.20, 5.42, 5.72, 6.04, 6.20, 6.44, 6.62, 6.78]))))

        expectSentences(SentenceAssembly.sentences([(seg, result)]), [
            (1.58, 8, "我们来讨论一下下个季度的产品规划首先请各位看一下"),
        ])
    }

    /// Fun-ASR-Nano / Qwen3-ASR：没有真实逐字时间。按标点断句，起止时间在说话部分内按字数（不算标点）比例估算
    @Test func 没有逐字时间时按字数比例估算() {
        let seg = segment(audio: 1.7..<12.3, speech: 2..<12)
        let result = SegmentRecognition(text: "好的。我们开始吧！下一个", tokens: nil)

        expectSentences(SentenceAssembly.sentences([(seg, result)]), [
            (2, 4, "好的。"),
            (4, 9, "我们开始吧！"),
            (9, 12, "下一个"),
        ])
    }

    /// 段边界一定断句（没有句末标点也断）；各段的句子落在各自的说话部分内，时间单调
    @Test func 段边界一定断句_时间单调且落在段内() {
        let first = segment(audio: 0.7..<5.3, speech: 1..<5)
        let second = segment(audio: 4.7..<9.3, speech: 5.4..<9)
        let results = [
            (first, SegmentRecognition(text: "我们看一下数据", tokens: nil)),
            // 逐字时间超出说话部分（段首补边里就有字、最后一个字的开始在段尾之后）：收到说话部分里
            (second, SegmentRecognition(text: "好的明白", tokens: timed([("好", 0.1), ("的", 0.9), ("明", 2.0),
                                                                       ("白", 4.5)]))),
        ]

        let sentences = SentenceAssembly.sentences(results)

        expectSentences(sentences, [(1, 5, "我们看一下数据"), (5.4, 9, "好的明白")])
        #expect(zip(sentences, sentences.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    /// 英文：识别结果是小写的单个字母或带 `@@` 的子词，文字经过后处理（合并、大写）。不分大小写、不计空格对上
    @Test func 英文子词和大小写不同也能对上逐字时间() {
        let seg = segment(audio: 0..<4, speech: 0..<4)
        let result = SegmentRecognition(
            text: "用 DeerFlow 跑 AI 模型。",
            tokens: timed([("用", 0.2), ("deer@@", 0.5), ("flow", 0.9), ("跑", 1.4), ("a", 1.8), ("i", 2.0),
                           ("模", 2.4), ("型", 2.8)]))

        let sentences = SentenceAssembly.sentences([(seg, result)])

        expectSentences(sentences, [(0.2, 4, "用 DeerFlow 跑 AI 模型。")])
    }

    /// 逐字结果和文字对不上（模型或后处理改了字）：退回按字数比例估算，不错位
    @Test func 逐字结果对不上文字时退回比例估算() {
        let seg = segment(audio: 0..<4, speech: 0..<4)
        let result = SegmentRecognition(text: "好的。明白了", tokens: timed([("好", 0.5), ("吧", 1.0)]))

        expectSentences(SentenceAssembly.sentences([(seg, result)]), [(0, 1.6, "好的。"), (1.6, 4, "明白了")])
    }

    @Test func 空结果和只有标点的结果不出句子() {
        let seg = segment(audio: 0..<4, speech: 0..<4)

        #expect(SentenceAssembly.sentences([
            (seg, SegmentRecognition(text: "", tokens: [])),
            (seg, SegmentRecognition(text: "  ", tokens: nil)),
            (seg, SegmentRecognition(text: "。", tokens: nil)),
        ]).isEmpty)
    }
}
