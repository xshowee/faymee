import Foundation

/// 识别器对一段音频的输出
public struct SegmentRecognition: Hashable, Sendable {
    /// 识别器给出的一个 token（中文通常一个字，英文可能是单个字母或带 `@@` 的子词）和它的开始时间
    public struct Token: Hashable, Sendable {
        public var text: String
        /// 秒，相对这段音频（`SpeechSegment.audio`）开头
        public var start: TimeInterval

        public init(text: String, start: TimeInterval) {
            self.text = text
            self.start = start
        }
    }

    /// 最终文字：可以带标点（模型自带或标点模型加的），可以经过后处理（如英文字母合并、大写）
    public var text: String
    /// 真实的逐字开始时间（Paraformer），按顺序；nil 表示模型没有真实逐字时间（Fun-ASR-Nano、Qwen3-ASR），
    /// 句子时间按字数比例估算。不需要和 `text` 一一对应：按“去掉标点和空白、不分大小写后的字”顺序对齐，
    /// 对不上时也退回比例估算
    public var tokens: [Token]?

    public init(text: String, tokens: [Token]?) {
        self.text = text
        self.tokens = tokens
    }
}

/// 把每段的识别结果组装成句子（sherpa 整段模型共用）。
///
/// - 每段单独断句，段边界一定断（段与段之间是 VAD 判定的静音，也可能换了说话人）
/// - 句子时间都落在这段的说话部分（`SpeechSegment.speech`，不含补边）里；各段说话部分不重叠，所以整体时间单调
/// - 有真实逐字时间：每个字的结束取下一个字的开始，最后一个字到说话部分结尾。这样停顿并进了前一个字，
///   `SentenceSplitter` 的“长字即停顿”推断不成立（会把停顿前的最后一个字切进下一句），所以关掉它，
///   只按句末标点断句
/// - 没有真实逐字时间：每个字（不算标点和空白）在说话部分里等分时间，同样只按句末标点断句
/// - 标点不占时间：接在前一个字的结尾
enum SentenceAssembly {
    static func sentences(_ results: [(segment: SpeechSegment, recognition: SegmentRecognition)]) -> [TranscribedSentence] {
        results.flatMap { sentences(in: $0.segment, $0.recognition) }
    }

    private static func sentences(in segment: SpeechSegment, _ result: SegmentRecognition) -> [TranscribedSentence] {
        let rate = Double(SpeechSegmentation.sampleRate)
        let lo = Double(segment.speech.lowerBound) / rate
        let hi = Double(segment.speech.upperBound) / rate
        let offset = Double(segment.audio.lowerBound) / rate

        let units = self.units(result.text)
        let content = units.filter(\.isContent)
        guard !content.isEmpty else { return [] }

        var starts = result.tokens.flatMap { align(content.map(\.character), to: $0) }?.map { offset + $0 }
            ?? content.indices.map { lo + (hi - lo) * Double($0) / Double(content.count) }
        // 收进说话部分，且不倒退
        var floor = lo
        for i in starts.indices {
            starts[i] = min(hi, max(floor, starts[i]))
            floor = starts[i]
        }

        var tokens: [TimedToken] = []
        var next = 0
        for unit in units {
            if unit.isContent {
                let end = next + 1 < starts.count ? starts[next + 1] : hi
                tokens.append(TimedToken(text: unit.text, start: starts[next], end: end))
                next += 1
            } else {
                let at = tokens.last?.end ?? starts[0]
                tokens.append(TimedToken(text: unit.text, start: at, end: at))
            }
        }
        return SentenceSplitter.split(tokens, inferPauses: false)
    }

    /// 文字拆成单元：每个字一个（带上它前面的空白，拼回去保留中英文之间的空格），每个标点一个
    private static func units(_ text: String) -> [(text: String, character: Character, isContent: Bool)] {
        var units: [(text: String, character: Character, isContent: Bool)] = []
        var space = ""
        for c in text {
            if c.isWhitespace {
                space.append(c)
            } else if c.isPunctuation {
                units.append((String(c), c, false))
                space = ""
            } else {
                units.append((space + String(c), c, true))
                space = ""
            }
        }
        return units
    }

    /// 文字里每个字的开始时间（相对这段音频开头）；token 拼起来的字和文字的字（不分大小写）对不上时为 nil
    static func align(_ characters: [Character], to tokens: [SegmentRecognition.Token]) -> [TimeInterval]? {
        var stream: [(character: String, start: TimeInterval)] = []
        for token in tokens {
            for c in token.text.replacingOccurrences(of: "@@", with: "")
            where !c.isWhitespace && !c.isPunctuation && c != "▁" {
                stream.append((c.lowercased(), token.start))
            }
        }
        guard stream.count == characters.count,
              zip(stream, characters).allSatisfy({ $0.character == $1.lowercased() }) else { return nil }
        return stream.map(\.start)
    }
}
