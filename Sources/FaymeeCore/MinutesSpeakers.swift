import Foundation

/// 纪要输入里的说话人标签。只在转写稿显示说话人（`showsSpeakers`）时有：
/// 输入行写成 `[s412 31:20 说话人 2] 文本`，已命名的写名字，没有说话人的句子不带标签。
/// 标签就是界面上的显示名（`Speaker.displayName`），输入行、负责人关联、姓名建议的校验都用这一张表
struct SpeakerLabels {
    /// 句子用到的说话人 id → 标签；不显示说话人时为空
    let labels: [String: String]
    /// 句子用到的、还没命名的说话人 id，按列表顺序（第一次开口先后）。只给它们要姓名建议
    let unnamed: [String]

    init(_ transcript: Transcript) {
        guard transcript.showsSpeakers else {
            labels = [:]
            unnamed = []
            return
        }
        let used = Set(transcript.sentences.compactMap(\.speaker))
        let speakers = transcript.speakers.filter { used.contains($0.id) }
        labels = Dictionary(speakers.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        unnamed = speakers.filter { $0.isUnnamed }.map(\.id)
    }

    /// 不显示说话人：输入行、提示词、文法都与没区分过说话人时逐字相同
    var isEmpty: Bool { labels.isEmpty }

    /// 要不要让模型推断说话人身份：输入里还有没命名的说话人
    var wantsNames: Bool { !unnamed.isEmpty }

    /// 未命名说话人的标签，按 `unnamed` 的顺序，写进提示词和文法
    var unnamedLabels: [String] { unnamed.compactMap { labels[$0] } }

    func label(for sentence: TranscriptSentence) -> String? {
        sentence.speaker.flatMap { labels[$0] }
    }

    /// 转写稿的一行，见 `inputLine(_:)`；句子有说话人时在时间后面带上标签
    func line(_ item: TranscriptItem) -> String {
        guard case let .sentence(s) = item, let label = label(for: s) else { return inputLine(item) }
        return "[\(s.id) \(formatDuration(s.start)) \(label)] \(s.text)"
    }

    /// 模型给的负责人对应哪个说话人：与某个标签完全相同（容忍模型丢掉“说话人 2”里的空格）。
    /// 对上不止一个（重名）或一个都对不上时为 nil
    func speakerID(owner: String) -> String? {
        let key = owner.filter { !$0.isWhitespace }
        let matches = labels.filter { $0.value.filter { !$0.isWhitespace } == key }.map(\.key)
        return matches.count == 1 ? matches[0] : nil
    }

    /// 校验一段提取输出里的说话人身份（spec「姓名推断」）：
    /// - 标签必须是这一段输入里出现过的未命名说话人
    /// - 名字去首尾空白后非空
    /// - 出处只留这一段输入里有的句子，去重；至少一句的原文字面包含名字，否则整条丢弃
    func validated(_ guesses: [RawNameGuess], in items: [TranscriptItem]) -> [NameGuess] {
        var sentences: [String: TranscriptSentence] = [:]
        for case let .sentence(s) in items where sentences[s.id] == nil { sentences[s.id] = s }
        let present = Set(sentences.values.compactMap(\.speaker))
        var byLabel: [String: String] = [:]
        for id in unnamed where present.contains(id) {
            if let label = labels[id], byLabel[label] == nil { byLabel[label] = id }
        }
        return guesses.compactMap { guess in
            let name = guess.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let speaker = byLabel[guess.speaker.trimmingCharacters(in: .whitespaces)] else {
                return nil
            }
            var seen = Set<String>()
            let refs = guess.refs.filter { sentences[$0] != nil && seen.insert($0).inserted }
            guard refs.contains(where: { sentences[$0]!.text.contains(name) }) else { return nil }
            return NameGuess(speaker: speaker, name: name, refs: refs)
        }
    }

    /// 各段的推断合成姓名建议：同一说话人按出处数（各段出处合起来去重后的句子数）投票，最多的胜出，平票丢弃。
    /// 不交给模型合并。出处把字面含名字的句子排在前面，最多 `maxRefs` 个。按 `unnamed` 的顺序排列
    func suggestions(_ guesses: [NameGuess], sentences: [String: TranscriptSentence]) -> [NameSuggestion] {
        unnamed.compactMap { speaker in
            var tally: [(name: String, refs: [String])] = []
            for guess in guesses where guess.speaker == speaker {
                if let i = tally.firstIndex(where: { $0.name == guess.name }) {
                    tally[i].refs += guess.refs.filter { !tally[i].refs.contains($0) }
                } else {
                    tally.append((guess.name, guess.refs))
                }
            }
            guard let best = tally.map(\.refs.count).max(),
                  tally.count(where: { $0.refs.count == best }) == 1,
                  let winner = tally.first(where: { $0.refs.count == best }) else { return nil }
            let quoting = winner.refs.filter { sentences[$0]?.text.contains(winner.name) == true }
            let others = winner.refs.filter { !quoting.contains($0) }
            let refs = (quoting + others).prefix(maxRefs).compactMap { id in
                sentences[id].map { MinutesRef(id: id, start: $0.start) }
            }
            return NameSuggestion(speaker: speaker, name: winner.name, refs: refs)
        }
    }
}

/// 模型输出的一条说话人身份，未校验
struct RawNameGuess {
    /// 说话人标签，如“说话人 2”
    var speaker: String
    var name: String
    var refs: [String]
}

/// 校验过的一条说话人身份
struct NameGuess {
    /// 说话人 id
    var speaker: String
    var name: String
    /// 句子 id，都在该段输入里，至少一句字面包含名字
    var refs: [String]
}

/// 取输出里的说话人身份一项（JSON 的截取同 `parseDraft`）。没有这一项、形状不对的条目都忽略，不算解析失败
func parseNameGuesses(_ output: String) -> [RawNameGuess] {
    guard let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"), open < close,
          let object = try? JSONSerialization.jsonObject(with: Data(output[open...close].utf8)) as? [String: Any],
          let entries = object[speakersKey] as? [Any] else { return [] }
    return entries.compactMap { entry in
        guard let entry = entry as? [String: Any], let speaker = entry["speaker"] as? String,
              let name = entry["name"] as? String else { return nil }
        return RawNameGuess(speaker: speaker, name: name,
                            refs: (entry["refs"] as? [Any])?.compactMap { $0 as? String } ?? [])
    }
}

/// 提取输出里说话人身份的键。模板自定义节的 key 不能用它
let speakersKey = "speakers"

extension Speaker {
    /// 没有名字（或名字是空白），显示为“说话人 N”
    var isUnnamed: Bool { name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }
}
