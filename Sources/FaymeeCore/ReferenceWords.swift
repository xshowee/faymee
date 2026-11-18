import Foundation

/// 纠错的参考词（spec「护栏」规则 2）：改后命中参考词时，换字词的拼音校验放宽（规则 3）；
/// 在线补 2 个字以上时补进去的须是参考词（规则 4）。
///
/// 参考词有四种来源：热词表、这场会议已命名的说话人名字、会议标题里的词，
/// 以及在这份转写稿**其他句子**里原样出现过至少 2 次的词（「智能体」别处转对过，就能把个别的「自然体」改过来）。
/// 都至少 2 个字：单字（的、了）到处都有，算作参考词等于放开校验
public struct ReferenceWords: Sendable {
    /// 热词与说话人名字，整个词命中才算
    public let words: [String]
    /// 会议标题按空白、标点切开的各段：标题没有分词，命中其中任意连续 2 个字以上就算
    let titlePieces: [String]
    /// 转写稿快照的各句，算「别处出现过至少 2 次」
    let sentences: [TranscriptSentence]

    public static let minimumLength = 2
    /// 在转写稿别处至少出现这么多次才算参考词
    public static let minimumOccurrences = 2
    /// 从转写稿别处找参考词时，候选最长几个字
    static let maximumCandidateLength = 8

    public init(hotwords: [String], speakerNames: [String], title: String, sentences: [TranscriptSentence]) {
        var seen = Set<String>()
        words = (hotwords + speakerNames)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= Self.minimumLength && seen.insert($0).inserted }
        titlePieces = title.components(separatedBy: CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters).union(.symbols))
            .filter { $0.count >= Self.minimumLength && !$0.allSatisfy(\.isNumber) }
        self.sentences = sentences
    }

    /// 参考词提示词里列出的词：热词、说话人名字、标题各段
    public var promptWords: [String] { words + titlePieces.filter { !words.contains($0) } }

    /// `text`（句子 `sentence` 改后的文字）里覆盖 `range`（字符位置）的最长参考词出现的位置；没有时为 nil。
    /// `range` 为空（补字）时，覆盖插入点即可
    public func match(in text: String, covering range: Range<Int>, sentence: String) -> Range<Int>? {
        let chars = Array(text)
        let longest = max(Self.maximumCandidateLength, words.map(\.count).max() ?? 0)
        let shortest = max(Self.minimumLength, range.count)
        guard shortest <= min(longest, chars.count) else { return nil }
        let others = sentences.filter { $0.id != sentence }.map(\.text)
        for length in stride(from: min(longest, chars.count), through: shortest, by: -1) {
            let first = max(0, range.upperBound - length)
            let last = min(range.lowerBound, chars.count - length)
            guard first <= last else { continue }
            for start in first...last {
                let candidate = String(chars[start..<start + length])
                if isReference(candidate, elsewhere: others) { return start..<start + length }
            }
        }
        return nil
    }

    /// 转写稿别处（不含这一句）是否原样出现过 `text`，用于数字建议「改后的数字在转写稿别处出现过」
    public func occursElsewhere(_ text: String, sentence: String) -> Bool {
        !text.isEmpty && sentences.contains { $0.id != sentence && $0.text.contains(text) }
    }

    private func isReference(_ candidate: String, elsewhere others: [String]) -> Bool {
        if words.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) { return true }
        if titlePieces.contains(where: { $0.contains(candidate) }) { return true }
        var count = 0
        for text in others {
            count += text.occurrences(of: candidate)
            if count >= Self.minimumOccurrences { return true }
        }
        return false
    }
}

extension String {
    /// 不重叠地出现了几次
    func occurrences(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = startIndex..<endIndex
        while let found = range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<endIndex
        }
        return count
    }
}
