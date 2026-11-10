import Foundation

extension Transcript {
    /// 重新区分（或重新转写）之后，让新说话人沿用旧转写稿里的名字，不用全部重新改名。
    ///
    /// 新旧说话人按句子重合数配对：一句新句子与一句旧句子时间上有重合，就给（旧说话人, 新说话人）记一次。
    /// 重新区分时句子没变，就是“同一句原来归谁、现在归谁”；重新转写时句子 id 全部重编，只能按时间比。
    /// 重合数从多到少贪心分配，每个旧名字最多给一个新说话人，每个新说话人最多拿一个名字；
    /// 一样多时先给编号小的新说话人，再按旧说话人的编号。名字的来源、声纹库关联一起带过来。
    /// 没有名字的旧说话人不参与；没配上的新说话人保持“说话人 N”
    public func carryingSpeakerNames(from old: Transcript) -> Transcript {
        let named = Dictionary(old.speakers.filter { $0.name != nil }.map { ($0.id, $0) }) { a, _ in a }
        guard !named.isEmpty, diarization != nil else { return self }
        let oldOrder = Dictionary(old.speakers.enumerated().map { ($1.id, $0) }) { a, _ in a }
        let newOrder = Dictionary(speakers.enumerated().map { ($1.id, $0) }) { a, _ in a }

        let oldSentences = old.sentences.filter { $0.speaker.map { named[$0] != nil } ?? false }
        var counts: [Pair: Int] = [:]
        for s in sentences {
            guard let new = s.speaker, newOrder[new] != nil else { continue }
            for o in oldSentences where overlaps(o, s) {
                counts[Pair(old: o.speaker!, new: new), default: 0] += 1
            }
        }

        let ranked = counts.sorted {
            ($1.value, newOrder[$0.key.new]!, oldOrder[$0.key.old]!)
                < ($0.value, newOrder[$1.key.new]!, oldOrder[$1.key.old]!)
        }
        var usedOld: Set<String> = [], usedNew: Set<String> = []
        var out = self
        for (pair, _) in ranked where !usedOld.contains(pair.old) && !usedNew.contains(pair.new) {
            usedOld.insert(pair.old)
            usedNew.insert(pair.new)
            let source = named[pair.old]!
            let i = newOrder[pair.new]!
            out.diarization!.speakers[i].name = source.name
            out.diarization!.speakers[i].nameSource = source.nameSource
            out.diarization!.speakers[i].personID = source.personID
        }
        return out
    }
}

private struct Pair: Hashable {
    var old: String
    var new: String
}

/// 时间上有重合。同一句（重新区分时）即使长度为 0 也算
private func overlaps(_ a: TranscriptSentence, _ b: TranscriptSentence) -> Bool {
    max(a.start, b.start) < min(a.end, b.end) || (a.start == b.start && a.end == b.end)
}
