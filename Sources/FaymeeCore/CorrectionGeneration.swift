import Foundation

/// 纠错怎么向模型要修改，随纪要引擎定（spec「范围（按引擎）」「输入与输出」）。
/// 分段、上下文、参考词、护栏都共用，只有提示词、输出形状、解析按方式分开（见 `correctTranscript`）
public enum CorrectionMethod: Hashable, Sendable {
    /// 本机：只输出替换 `{"fixes": [{"id", "from", "to"}]}`，GBNF 文法限定 id 范围和条数
    case wordFixes
    // ticket 03：case sentenceRewrite —— 在线输出改后的整句 `{"edits": [{"id", "text"}]}`，范围 `.full`

    public var scope: CorrectionScope {
        switch self {
        case .wordFixes: .wordsOnly
        }
    }

    /// 纪要引擎对应的纠错方式；还不支持的引擎为 nil（这一张里在线还不支持，03 接上），
    /// 这时纠错不跑、不报错，直接走纪要
    public static func forMinutesEngine(isOnline: Bool) -> CorrectionMethod? {
        isOnline ? nil : .wordFixes
    }
}

/// 每段前面带上一段的最后几句作只读上下文
let correctionContextSentences = 3

/// 用纪要的模型纠错一份转写稿快照。纯函数：不读写文件、不加载或释放模型，只调 `generator` 的
/// `contextTokens`、`countTokens`、`generate`。返回过了护栏的结论，由调用方包成 `CorrectionResult` 写盘。
///
/// 按 token 预算分段（同纪要的 `segment`），每段前面带上一段最后 3 句作只读上下文；手动改过的句子也给，
/// 都当上下文，对它们的修改丢弃。一段的输出重试一次仍解析不出时这一段不改（记一条 `unparseable`），
/// 不让整场失败；引擎自己抛的错（含取消）原样抛出
///
/// - Parameters:
///   - title: 会议标题，参考词之一
///   - hotwords: 当前的热词表，参考词之一
///   - progress: 0...1，每完成一段报一次
public func correctTranscript(
    _ transcript: Transcript, title: String, hotwords: [String], method: CorrectionMethod,
    generator: TextGenerator, progress: (Double) -> Void = { _ in }
) async throws -> CorrectionReview {
    let sentences = transcript.sentences
    let names = transcript.speakers.filter { !$0.isUnnamed }.compactMap(\.name)
    let references = ReferenceWords(hotwords: hotwords, speakerNames: names, title: title, sentences: sentences)
    let labels = SpeakerLabels(transcript)
    let line = { (item: TranscriptItem) -> String in
        guard case let .sentence(s) = item else { return "" }
        let tags = [s.id, labels.label(for: s)].compactMap { $0 }
        return "[\(tags.joined(separator: " "))] \(s.text)"
    }
    let system = correctionSystemPrompt(method, references: references.promptWords, speakers: !labels.isEmpty)
    let budget = Budget(generator, system: system,
                        outputTokens: min(generator.maxOutputTokens, generator.contextTokens / 4))
    let items = sentences.map { TranscriptItem.sentence($0) }
    // 只读上下文按最长的几句预留
    let longest = Array(items.map(line).sorted { generator.countTokens($0) > generator.countTokens($1) }
        .prefix(correctionContextSentences))
    let lineBudget = budget.promptTokens
        - generator.countTokens(correctionPrompt(title: title, context: longest, lines: []))
    let segments = items.isEmpty ? [] : try segment(items, lineBudget: lineBudget, countTokens: generator.countTokens,
                                                    line: line) {
        budget.fits(correctionPrompt(title: title, context: longest, lines: $0.map(line)))
    }

    var review = CorrectionReview()
    var previous: [TranscriptItem] = []
    for (n, items) in segments.enumerated() {
        defer {
            previous = items
            progress(Double(n + 1) / Double(segments.count))
        }
        let editable = items.compactMap { item -> String? in
            guard case let .sentence(s) = item, s.original == nil else { return nil }
            return s.id
        }
        guard !editable.isEmpty else { continue }
        let context = Array(previous.suffix(correctionContextSentences)).map(line)
        let prompt = correctionPrompt(title: title, context: context, lines: items.map(line))
        let correction = CorrectionContext(scope: method.scope, editable: Set(editable), sentences: sentences,
                                           references: references)
        switch method {
        case .wordFixes:
            let grammar = wordFixGrammar(ids: editable)
            var fixes: [WordFix]?
            for _ in 0..<2 where fixes == nil {
                try Task.checkCancellation()
                fixes = parseWordFixes(try await generator.generate(system: system, prompt: prompt,
                                                                    maxTokens: budget.outputTokens, grammar: grammar))
            }
            guard let fixes else {
                review.reject(.unparseable)
                continue
            }
            review.merge(reviewWordFixes(fixes, context: correction))
        }
    }
    if segments.isEmpty { progress(1) }
    return review
}

/// 系统提示：范围、保留口语不润色、参考词、输出形状
func correctionSystemPrompt(_ method: CorrectionMethod, references: [String], speakers: Bool) -> String {
    let format = speakers
        ? "转写稿每行一句，格式为“[句子编号 说话人] 内容”，例如“[s12 说话人 2] 我们下周发布”。"
        : "转写稿每行一句，格式为“[句子编号] 内容”，例如“[s12] 我们下周发布”。"
    let referenceLine = references.isEmpty ? ""
        : "\n参考词（这些写法是对的，转写稿里读音相近的错写可以改成它们）：\(references.joined(separator: "、"))\n"
    switch method {
    case .wordFixes:
        return """
        你是会议转写稿的校对助手。转写稿由语音识别生成，常把词识别成读音相近的别的字词，\
        例如“被动”识别成“对动”、“工位上”识别成“工会上”、“端到端”识别成“端道的”。
        \(format)
        任务：根据上下文找出这类听错的字词，给出替换。
        - 只换读音相近的字词。不补字、不删字、不改标点、不改说法、不润色。
        - 口语词（嗯、那个、就是）和口吃（我我我觉得）都保留，不算错误。
        - 拿不准就不改。没有要改的就输出空列表。
        - from 原样抄自那一句，只包含要换的字词，在那一句里只出现一次；to 是换成的字词。
        - 标着“只读”的上文只供理解，不要改。
        \(referenceLine)
        只输出 JSON：{"fixes": [{"id": "s12", "from": "对动", "to": "被动"}]}
        """
    }
}

/// 一段的提示词：标题、只读上文、要校对的转写稿
func correctionPrompt(title: String, context: [String], lines: [String]) -> String {
    var parts = ["会议标题：\(title)"]
    if !context.isEmpty { parts.append("上文（只读，不要改）：\n" + context.joined(separator: "\n")) }
    parts.append("要校对的转写稿：\n" + lines.joined(separator: "\n"))
    return parts.joined(separator: "\n\n")
}

/// 本机输出的 GBNF 文法：`id` 只能是这一段可改的句子 id 之一，条数不超过可改的句数。
/// 字段间最多一个空白字符，免得模型一直输出空白
func wordFixGrammar(ids: [String]) -> String {
    func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    let alternatives = ids.map { "\"\\\"" + escaped(escaped($0)) + "\\\"\"" }.joined(separator: " | ")
    let more = ids.count > 1 ? #" ( "," ws fix ){0,\#(ids.count - 1)}"# : ""
    return #"""
    root ::= "{" ws "\"fixes\":" ws "[" ws ( fix\#(more) )? ws "]" ws "}"
    fix ::= "{" ws "\"id\":" ws id "," ws "\"from\":" ws string "," ws "\"to\":" ws string ws "}"
    id ::= \#(alternatives)
    string ::= "\"" ( [^"\\\x00-\x1f] | "\\" ( ["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] ) )* "\""
    ws ::= [ \n]?
    """#
}

/// 取输出里第一个 `{` 到最后一个 `}` 当 JSON（同 `parseDraft`）。没有 `fixes` 列表时为 nil（解析失败）；
/// 单条形状不对只丢掉那一条
func parseWordFixes(_ output: String) -> [WordFix]? {
    guard let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"), open < close,
          let object = try? JSONSerialization.jsonObject(with: Data(output[open...close].utf8)) as? [String: Any],
          let entries = object["fixes"] as? [Any]
    else { return nil }
    return entries.compactMap { entry in
        guard let entry = entry as? [String: Any], let id = entry["id"] as? String,
              let from = entry["from"] as? String, let to = entry["to"] as? String else { return nil }
        return WordFix(id: id, from: from, to: to)
    }
}
