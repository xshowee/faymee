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
/// - 去掉段边界的重复字：有真实逐字时间时按时间，没有时按文字（见 `droppingOverlapDuplicates`）
enum SentenceAssembly {
    typealias Result = (segment: SpeechSegment, recognition: SegmentRecognition)

    static func sentences(_ results: [Result]) -> [TranscribedSentence] {
        droppingOverlapDuplicates(results).flatMap { sentences(in: $0.segment, $0.recognition) }
    }

    /// 两段里“同一个字”的开始时间最多差多少（真实会议里 Paraformer 的重复字相差 0.01–0.17 秒）
    static let twinTolerance: TimeInterval = 0.2

    /// 段边界的重复字：补边让相邻两段的音频重叠（VAD 强行断开的两段只隔约 0.07 秒，各补 0.3 秒），
    /// 重叠处的字两段各识别一遍（真实会议：「…我这里」「我这里自己搞」）。补边不能收窄：Paraformer 在被截断的段边上
    /// 会丢字，补边重叠时后一段还能认出来。
    ///
    /// 做法：前一段末尾从后一段音频开头（再早 `twinTolerance`）起的字里，找第一个在后一段开头（前一段音频结束前）
    /// 有“孪生”的字——同一个字、开始时间相差不超过 `twinTolerance`；从它起去掉前一段剩下的字（前一段在这里被截断，
    /// 末尾常是半个字，如「到时候会总」对「到时候会准备」；后一段对这块有完整的上下文）。
    /// 去掉后留在末尾的非句末标点（逗号等）一起去掉。
    ///
    /// 没有逐字时间（Fun-ASR-Nano、Qwen3-ASR，时间是估算的）时按文字去重：只在补边伸进了邻段的说话部分时
    /// （只在静音里重叠的话，交界处相同的字更可能是真说了两遍），前一段末尾和后一段开头相同的字
    /// （最多 `maxTextTwins` 个，不算标点）从前一段去掉。三场真实会议里 Fun-ASR-Nano 有约 11 处这样的重复
    /// （「…当我们。」「我们搭的那套」）。代价：交界处真实的重复（「对。」「对，」）会少一个
    static func droppingOverlapDuplicates(_ results: [Result]) -> [Result] {
        let rate = Double(SpeechSegmentation.sampleRate)
        var out = results
        for i in out.indices.dropLast() {
            let a = out[i], b = out[i + 1]
            guard a.segment.audio.upperBound > b.segment.audio.lowerBound else { continue }
            guard let tail = timedCharacters(a), let head = timedCharacters(b) else {
                if a.segment.audio.upperBound > b.segment.speech.lowerBound
                    || b.segment.audio.lowerBound < a.segment.speech.upperBound {
                    out[i].recognition = droppingTextTwins(of: a.recognition, before: b.recognition)
                }
                continue
            }
            let bStart = Double(b.segment.audio.lowerBound) / rate
            let aEnd = Double(a.segment.audio.upperBound) / rate
            let candidates = head.filter { $0.start < aEnd }
            guard let cut = tail.firstIndex(where: { c in
                c.start >= bStart - twinTolerance
                    && candidates.contains { $0.character == c.character && abs($0.start - c.start) <= twinTolerance }
            }) else { continue }
            let offset = Double(a.segment.audio.lowerBound) / rate
            out[i].recognition = keeping(cut, of: a.recognition, starts: tail.map { $0.start - offset })
        }
        return out
    }

    /// 按文字去重时最多去掉几个字（补边重叠最多约 0.5 秒）
    static let maxTextTwins = 4

    /// 前一段末尾与后一段开头相同的字（不分大小写，最多 `maxTextTwins` 个，取最长）从前一段去掉；逐字时间不留。
    /// 实时字幕定稿的相邻两句也用它
    static func droppingTextTwins(of first: SegmentRecognition, before second: SegmentRecognition)
        -> SegmentRecognition {
        let tail = units(first.text).filter(\.isContent).map { $0.character.lowercased() }
        let head = units(second.text).filter(\.isContent).map { $0.character.lowercased() }
        for k in stride(from: min(maxTextTwins, tail.count, head.count), through: 1, by: -1)
        where tail.suffix(k).elementsEqual(head.prefix(k)) {
            return keeping(tail.count - k, of: first, starts: nil)
        }
        return first
    }

    /// 文字里每个字（不算标点和空白，小写）和它的开始时间（相对录音开头）；没有逐字时间或对不上时为 nil
    private static func timedCharacters(_ result: Result) -> [(character: String, start: TimeInterval)]? {
        let content = units(result.recognition.text).filter(\.isContent).map(\.character)
        guard let tokens = result.recognition.tokens, !content.isEmpty,
              let starts = align(content, to: tokens) else { return nil }
        let offset = Double(result.segment.audio.lowerBound) / Double(SpeechSegmentation.sampleRate)
        return zip(content, starts).map { ($0.lowercased(), offset + $1) }
    }

    /// 只留前 `count` 个字（和它们之间的标点、空白），末尾的非句末标点去掉；原文以句末标点结尾而留下的部分没有，
    /// 把它接上（「我这里，我这里。」→「我这里。」）。逐字时间换成每字一个（`starts` 为 nil 时不留）
    private static func keeping(_ count: Int, of result: SegmentRecognition, starts: [TimeInterval]?) -> SegmentRecognition {
        let all = units(result.text)
        var kept: [(text: String, character: Character, isContent: Bool)] = []
        var n = 0
        for unit in all {
            if unit.isContent {
                guard n < count else { break }
                n += 1
            }
            kept.append(unit)
        }
        while let last = kept.last, !last.isContent, !SentenceSplitter.terminators.contains(last.character) {
            kept.removeLast()
        }
        if let end = all.last, !end.isContent, SentenceSplitter.terminators.contains(end.character),
           let last = kept.last, last.isContent {
            kept.append(end)
        }
        let characters = kept.filter(\.isContent)
        return SegmentRecognition(text: kept.map(\.text).joined(),
                                  tokens: starts.map { zip(characters, $0).map { .init(text: String($0.character), start: $1) } })
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
