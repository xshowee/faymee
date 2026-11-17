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

    // MARK: 段边界的重复字

    /// VAD 强行断开的两段只隔约 0.07 秒，补边让两段的音频重叠约 0.5 秒，重叠处的字两段各识别一遍
    /// （真实会议：「…我这里」「我这里自己搞」，同字的开始时间相差不到 0.2 秒）。按逐字时间认出来，
    /// 去掉前一段的（它在段尾被截断，后一段对这块有完整的上下文）
    private let first = SpeechSegment(audio: 0..<85_920, speech: 0..<81_120) // 音频 0–5.37，说话 0–5.07
    private let second = SpeechSegment(audio: 76_320..<144_000, speech: 82_240..<139_200) // 音频 4.77–9，说话 5.14–8.7

    @Test func 补边重叠处两段都识别出的字只留后一段的() {
        let results = [
            (first, SegmentRecognition(text: "我们看一下，我这里。", tokens: timed([
                ("我", 3.0), ("们", 3.2), ("看", 3.4), ("一", 3.6), ("下", 3.8), ("我", 4.85), ("这", 4.95), ("里", 5.05),
            ]))),
            (second, SegmentRecognition(text: "我这里自己搞。", tokens: timed([
                ("我", 0.15), ("这", 0.25), ("里", 0.37), ("自", 0.6), ("己", 0.8), ("搞", 1.0),
            ]))),
        ]

        // 「，」去掉，原文结尾的「。」接上
        expectSentences(SentenceAssembly.sentences(results), [(3.0, 5.07, "我们看一下。"), (5.14, 8.7, "我这里自己搞。")])
    }

    @Test func 前一段末尾被截断的字也一起去掉_句末标点保留() {
        // 前一段「…。到时候会总」，后一段「到时候会准备」：「总」是被截断的「准」
        let results = [
            (first, SegmentRecognition(text: "我们看一下。到时候会总", tokens: timed([
                ("我", 3.0), ("们", 3.2), ("看", 3.4), ("一", 3.6), ("下", 3.8),
                ("到", 4.6), ("时", 4.75), ("候", 4.85), ("会", 4.95), ("总", 5.05),
            ]))),
            (second, SegmentRecognition(text: "到时候会准备", tokens: timed([
                ("到", 0.0), ("时", 0.08), ("候", 0.18), ("会", 0.28), ("准", 0.38), ("备", 0.5),
            ]))),
        ]

        expectSentences(SentenceAssembly.sentences(results), [(3.0, 5.07, "我们看一下。"), (5.14, 8.7, "到时候会准备")])
    }

    @Test func 英文子词按字对上() {
        let results = [
            (first, SegmentRecognition(text: "我们调 agent", tokens: timed([
                ("我", 3.0), ("们", 3.2), ("调", 4.5), ("ag@@", 4.9), ("ent", 5.05),
            ]))),
            (second, SegmentRecognition(text: "agent 调工具", tokens: timed([
                ("a@@", 0.2), ("gent", 0.3), ("调", 0.6), ("工", 0.8), ("具", 1.0),
            ]))),
        ]

        expectSentences(SentenceAssembly.sentences(results), [(3.0, 5.07, "我们调"), (5.14, 8.7, "agent 调工具")])
    }

    @Test func 没有同字同时间的孪生就不去掉() {
        let results = [
            // 「对」在后一段开头没有；「好」在后一段也有，但开始时间差 0.4 秒（真的说了两遍）
            (first, SegmentRecognition(text: "嗯对，好", tokens: timed([("嗯", 4.0), ("对", 4.6), ("好", 4.9)]))),
            (second, SegmentRecognition(text: "可以，好。", tokens: timed([("可", 0.1), ("以", 0.25), ("好", 0.53)]))),
        ]

        expectSentences(SentenceAssembly.sentences(results), [(4.0, 5.07, "嗯对，好"), (5.14, 8.7, "可以，好。")])
    }

    @Test func 前一段整段都是重复时不出句子() {
        let results = [
            (first, SegmentRecognition(text: "还有", tokens: timed([("还", 4.9), ("有", 5.05)]))),
            (second, SegmentRecognition(text: "还有年底了。", tokens: timed([
                ("还", 0.2), ("有", 0.33), ("年", 0.5), ("底", 0.7), ("了", 0.9),
            ]))),
        ]

        expectSentences(SentenceAssembly.sentences(results), [(5.14, 8.7, "还有年底了。")])
    }

    @Test func 没有逐字时间的模型不去重() {
        let results = [
            (first, SegmentRecognition(text: "我们看一下我这里", tokens: nil)),
            (second, SegmentRecognition(text: "我这里自己搞。", tokens: nil)),
        ]

        #expect(SentenceAssembly.sentences(results).map(\.text) == ["我们看一下我这里", "我这里自己搞。"])
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
