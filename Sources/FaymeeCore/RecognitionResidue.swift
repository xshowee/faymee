import Foundation

/// 在线纠错能删的识别残留（spec「护栏」规则 5）。只有这三种删字能过，其他删字一律不过：
/// - 紧挨着的同一单元连续重复 `minimumRepeats` 次以上，至少留 1 次（口吃「我我我」「就是就是」到不了这个次数；
///   全是数字的单元不算）；
/// - 与上一句（同一个说话人）完全相同的整句重复，删成空句（只认上一句，相同的两句不会都被删掉；
///   两个人各说一句「好的」是真的对话，不删）；
/// - `[breath]`、`/sil` 这类标记（同 `ASROutputGuard.clean` 认的那些）。
///
/// 复读按“字”算，标点、空白不算（「好的，好的，……」的单元是「好的」），同 `ASROutputGuard`；
/// 次数门槛按 spec 取 5，不用 ASR 输出检查的门槛
struct RecognitionResidue {
    /// 同一单元连续重复至少这么多次才算复读残留
    static let minimumRepeats = 5
    /// 单元最长几个字
    static let maximumUnit = 20

    /// 原文里一段连续重复：字符位置 `range`，单元 `unit` 个字，重复 `count` 次
    struct Run: Hashable {
        var range: Range<Int>
        var unit: Int
        var count: Int
    }

    private let markers: [Range<Int>]
    private let runs: [Run]
    /// 整句都是残留：改后没有字，且与上一句的字完全相同
    private let wholeSentence: Bool
    /// 这一句的所有删字（原文字符位置 → 删掉几个字）
    private let deletions: [(range: Range<Int>, count: Int)]

    init(_ diff: TextDiff, sentence: TranscriptSentence, sentences: [TranscriptSentence]) {
        markers = ASROutputGuard.markerRanges(in: diff.before)
        runs = Self.runs(in: diff.before)
        deletions = diff.segments.filter { $0.kind == .delete }
            .map { ($0.beforeRange, characterCount($0.before)) }
        let previous = sentences.firstIndex { $0.id == sentence.id }.flatMap { $0 > 0 ? sentences[$0 - 1] : nil }
        wholeSentence = characterCount(diff.after) == 0
            && previous.map { $0.speaker == sentence.speaker && Self.content($0.text) == Self.content(diff.before) } == true
    }

    /// 这一处删字是不是识别残留
    func isResidue(_ segment: TextDiff.Segment) -> Bool {
        let range = segment.beforeRange
        if wholeSentence { return true }
        if markers.contains(where: { $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound }) {
            return true
        }
        // 落在某段复读里，且这段复读里删掉的字合起来正好只留下 1 个单元
        return runs.contains { run in
            guard run.range.lowerBound <= range.lowerBound, range.upperBound <= run.range.upperBound else { return false }
            let deleted = deletions.filter { run.range.lowerBound <= $0.range.lowerBound && $0.range.upperBound <= run.range.upperBound }
                .reduce(0) { $0 + $1.count }
            return deleted == run.unit * (run.count - 1)
        }
    }

    private static func content(_ text: String) -> String {
        String(text.filter(ASROutputGuard.isContent))
    }

    /// 原文里所有至少重复 `minimumRepeats` 次的连续段（同一起点的各种单元都列出）
    static func runs(in text: String) -> [Run] {
        // 字及其在原文里的字符位置
        let content = Array(text).enumerated().filter { ASROutputGuard.isContent($0.element) }
        let chars = content.map(\.element)
        var runs: [Run] = []
        for i in chars.indices {
            for unit in 1...maximumUnit where i + unit * minimumRepeats <= chars.count {
                let pattern = chars[i..<i + unit]
                // 全是数字的不算（「五五五五五」可能是真的编号），同 `ASROutputGuard`
                guard !pattern.allSatisfy({ containsNumber(String($0)) }) else { continue }
                var count = 1
                while i + unit * (count + 1) <= chars.count,
                      chars[(i + unit * count)..<(i + unit * (count + 1))] == pattern {
                    count += 1
                }
                guard count >= minimumRepeats else { continue }
                let last = i + unit * count - 1
                runs.append(Run(range: content[i].offset..<content[last].offset + 1, unit: unit, count: count))
            }
        }
        return runs
    }
}
