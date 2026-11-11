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

    /// 开引号、开括号这类属于后面的话的标点（Unicode 的 Ps、Pi 类：“ ‘ （ 《 「 【 ( [ 等）
    private static func isOpening(_ c: Character) -> Bool {
        c.unicodeScalars.contains {
            $0.properties.generalCategory == .openPunctuation || $0.properties.generalCategory == .initialPunctuation
        }
    }

    static func split(_ tokens: [TimedToken]) -> [TranscribedSentence] {
        let (closed, open) = splitKeepingOpen(tokens)
        return closed + (sentence(open).map { [$0] } ?? [])
    }

    /// 同 `split`，但最后一句没遇到句末标点或停顿时不算断完，原样留下它的字（open），
    /// 实时字幕把它和下一段定稿结果的字拼起来再断。对整段 tokens 断句与分几次断的结果相同
    static func splitKeepingOpen(_ tokens: [TimedToken]) -> (closed: [TranscribedSentence], open: [TimedToken]) {
        var sentences: [TranscribedSentence] = []
        var current: [TimedToken] = []

        func close() {
            if let s = sentence(current) { sentences.append(s) }
            current = []
        }
        /// 在 token 前面断开。末尾的开引号、开括号属于后面的话，留给下一句：没有逐字时间的标点紧接在
        /// 前一个字后面，停顿落在它后面。它们的时间挪到 token 开头，下一句不从静音里开始
        func close(before token: TimedToken) {
            var opening: [TimedToken] = []
            while let last = current.last, isOpeningToken(last) {
                opening.insert(TimedToken(text: last.text, start: token.start, end: token.start), at: 0)
                current.removeLast()
            }
            close()
            current = opening
        }
        func characterCount() -> Int {
            current.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace && !$0.isPunctuation }.count }
        }

        for token in tokens {
            let trimmed = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // 收尾类的标点（句号、逗号、问号、闭引号、闭括号等）属于前面的话；开引号、开括号属于后面的话，
            // 停顿的处理同普通的字
            let closesBefore = trimmed.allSatisfy(\.isPunctuation) && !trimmed.contains(where: isOpening)
            let isLong = token.end - token.start >= pause

            // 两段之间真正的静音（时间不连续）总是断开。静音后紧跟的收尾标点属于前面的话，接上再断：
            // 流式识别时上一段定稿结果没带句号、句号出现在下一段开头，就是这样。
            // 接上时不拉长前一句：它的时间在静音之后（没有逐字时间的标点放在下一段结果的开头），
            // 记成紧接前一个字、长度为 0
            if let last = current.last, token.start - last.end >= pause {
                if closesBefore {
                    current.append(TimedToken(text: token.text, start: last.end, end: last.end))
                    close()
                    continue
                }
                close(before: token)
            }
            // 停顿并在这个字里，停顿在它前面
            if !closesBefore, isLong, characterCount() >= minCharacters { close(before: token) }

            current.append(token)

            if trimmed.contains(where: terminators.contains) {
                close()
            } else if closesBefore, isLong, characterCount() >= minCharacters {
                // 停顿并在逗号里，停顿在它后面
                close()
            }
        }
        return (sentences, current)
    }

    /// 只有开引号、开括号的一小段
    private static func isOpeningToken(_ token: TimedToken) -> Bool {
        let trimmed = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.allSatisfy(\.isPunctuation) && trimmed.contains(where: isOpening)
    }

    /// 一串字拼成的一句；全是空白时为 nil
    static func sentence(_ tokens: [TimedToken]) -> TranscribedSentence? {
        guard let first = tokens.first, let last = tokens.last else { return nil }
        let text = joined(tokens)
        return text.isEmpty ? nil : TranscribedSentence(start: first.start, end: last.end, text: text)
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
