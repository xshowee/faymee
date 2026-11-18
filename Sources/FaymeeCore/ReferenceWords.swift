import Foundation
import NaturalLanguage

/// 纠错的参考词（spec「护栏」规则 2）：改后命中参考词时，换字词的拼音校验放宽（规则 3）；
/// 在线补 2 个字以上时补进去的须是参考词（规则 4）。
///
/// 参考词有四种来源：热词表、这场会议已命名的说话人名字、会议标题里的词，
/// 以及在这份转写稿**其他句子**里作为整词出现过至少 2 次的词（「智能体」别处转对过，就能把个别的「自然体」改过来）。
/// 标题和转写稿里的词都是分词后的整词（见 `wholeWords(in:)`）：「我们」「这个」「不说」到处都有，
/// 词中间切出来的片段也不是词，算作参考词等于放开校验。
/// 都至少 2 个字：单字（的、了）到处都有
public struct ReferenceWords: Sendable {
    /// 热词与说话人名字，整个词命中才算
    public let words: [String]
    /// 会议标题按空白、标点切开的各段，列进提示词
    let titlePieces: [String]
    /// 会议标题里的整词
    let titleWords: Set<String>
    /// 转写稿各句里的整词出现几次：全部句子合计，和每句自己的。相减就是「别处」
    let wordCounts: [String: Int]
    let wordCountsBySentence: [String: [String: Int]]
    /// 以上各种参考词里最长的有几个字，`match` 最长试到这么长
    let longestWord: Int

    public static let minimumLength = 2
    /// 在转写稿别处至少出现这么多次才算参考词
    public static let minimumOccurrences = 2
    /// 标题、转写稿里几个词连起来的参考词最长几个字（单个词再长也算，如 LangChain）
    static let maximumCandidateLength = 8

    public init(hotwords: [String], speakerNames: [String], title: String, sentences: [TranscriptSentence]) {
        var seen = Set<String>()
        words = (hotwords + speakerNames)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= Self.minimumLength && seen.insert($0).inserted }
        titlePieces = title.components(separatedBy: CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters).union(.symbols))
            .filter { $0.count >= Self.minimumLength && !$0.allSatisfy(\.isNumber) }
        titleWords = Set(Self.wholeWords(in: title))
        var total: [String: Int] = [:]
        var bySentence: [String: [String: Int]] = [:]
        for s in sentences {
            for word in Self.wholeWords(in: s.text) {
                total[word, default: 0] += 1
                bySentence[s.id, default: [:]][word, default: 0] += 1
            }
        }
        wordCounts = total
        wordCountsBySentence = bySentence
        longestWord = (words + titleWords + total.keys).map(\.count).max() ?? 0
    }

    /// 参考词提示词里列出的词：热词、说话人名字、标题各段
    public var promptWords: [String] { words + titlePieces.filter { !words.contains($0) } }

    /// `text`（句子 `sentence` 改后的文字）里覆盖 `range`（字符位置）的最长参考词出现的位置；没有时为 nil。
    /// `range` 为空（补字）时，覆盖插入点即可
    public func match(in text: String, covering range: Range<Int>, sentence: String) -> Range<Int>? {
        let chars = Array(text)
        let shortest = max(Self.minimumLength, range.count)
        guard shortest <= min(longestWord, chars.count) else { return nil }
        for length in stride(from: min(longestWord, chars.count), through: shortest, by: -1) {
            let first = max(0, range.upperBound - length)
            let last = min(range.lowerBound, chars.count - length)
            guard first <= last else { continue }
            for start in first...last {
                let candidate = String(chars[start..<start + length])
                if isReference(candidate, sentence: sentence) { return start..<start + length }
            }
        }
        return nil
    }

    private func isReference(_ candidate: String, sentence: String) -> Bool {
        if words.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) { return true }
        if titleWords.contains(candidate) { return true }
        let elsewhere = (wordCounts[candidate] ?? 0) - (wordCountsBySentence[sentence]?[candidate] ?? 0)
        return elsewhere >= Self.minimumOccurrences
    }

    /// `text` 里的整词：系统分词（`NLTagger`）后，连续的实词连起来的各段，`minimumLength`–`maximumCandidateLength`
    /// 个字，单个词不限长（有重复，按出现次数）。分词常把一个词切开（智能|体、端|到|端），所以连续几个实词连起来也算。
    /// 实词是名词、动词、形容词、成语，以及不含数字的 2 字以上其他词（分词器认不出类别的「模型」「差不多」）；
    /// 代词（含人称代词的字，分词器偶尔标错）、副词（「不」）、助词、介词、连词、数字、标点处断开
    static func wholeWords(in text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var tokens: [(range: Range<String.Index>, isContent: Bool)] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace]) { tag, range in
            tokens.append((range, isContentWord(text[range], tag: tag)))
            return true
        }
        var words: [String] = []
        for first in tokens.indices where tokens[first].isContent {
            for last in first..<tokens.count {
                guard tokens[last].isContent else { break }
                let word = text[tokens[first].range.lowerBound..<tokens[last].range.upperBound]
                guard word.count <= maximumCandidateLength || first == last else { break }
                if word.count >= minimumLength { words.append(String(word)) }
            }
        }
        return words
    }

    private static func isContentWord(_ token: Substring, tag: NLTag?) -> Bool {
        guard let tag, !token.contains(where: personalPronounCharacters.contains) else { return false }
        switch tag {
        case .noun, .verb, .adjective, .idiom: return true
        case .otherWord: return token.count >= minimumLength && !containsNumber(String(token))
        default: return false
        }
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
