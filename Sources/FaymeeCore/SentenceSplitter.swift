import Foundation

/// 识别结果中带时间的一小段文字（中文通常是一个字，英文是一个词，也可能是标点）。
/// start / end 是相对录音开头的秒数
struct TimedToken: Hashable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// 把逐字结果切成句子。
///
/// SpeechTranscriber 约 20 秒才出一段结果，中文标点又很稀少（常常整段只有一个句号），
/// 直接按结果分行太长，不便阅读和点击跳转。所以除了句末标点，还在停顿处断句：
/// 引擎把字与字之间的静音并进了后一个字（或标点）的时间里，一个字占得特别久就说明前面有停顿
enum SentenceSplitter {
    /// 超过这个时长就视为停顿。普通语速每个字 0.1–0.3 秒
    static let pause: TimeInterval = 0.4
    /// 由“长字”推断的停顿，只在已有这么多字后才断，避免切出「第二件事」这类碎片
    static let minCharacters = 6

    private static let terminators: Set<Character> = ["。", "！", "？", "；", "!", "?", ";", "…"]

    static func split(_ tokens: [TimedToken]) -> [TranscribedSentence] {
        var sentences: [TranscribedSentence] = []
        var current: [TimedToken] = []

        func close() {
            guard let first = current.first, let last = current.last else { return }
            let text = joined(current)
            if !text.isEmpty {
                sentences.append(TranscribedSentence(start: first.start, end: last.end, text: text))
            }
            current = []
        }
        func characterCount() -> Int {
            current.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace && !$0.isPunctuation }.count }
        }

        for token in tokens {
            let trimmed = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let isPunctuation = trimmed.allSatisfy(\.isPunctuation)
            let isLong = token.end - token.start >= pause

            // 两段之间真正的静音（时间不连续）总是断开
            if let last = current.last, token.start - last.end >= pause { close() }
            // 停顿并在这个字里，停顿在它前面
            if !isPunctuation, isLong, characterCount() >= minCharacters { close() }

            current.append(token)

            if trimmed.contains(where: terminators.contains) {
                close()
            } else if isPunctuation, isLong, characterCount() >= minCharacters {
                // 停顿并在逗号里，停顿在它后面
                close()
            }
        }
        close()
        return sentences
    }

    /// 拼接文字：去掉标点前多余的空格（引擎会输出「好 ，」），保留中英文之间的空格
    private static func joined(_ tokens: [TimedToken]) -> String {
        var text = ""
        for token in tokens {
            let trimmed = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.allSatisfy(\.isPunctuation) {
                text = String(text.reversed().drop(while: \.isWhitespace).reversed())
                text += trimmed
            } else {
                text += token.text
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
