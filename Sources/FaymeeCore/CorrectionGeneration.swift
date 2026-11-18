import Foundation

/// 纠错怎么向模型要修改，随纪要引擎定（spec「范围（按引擎）」「输入与输出」）。
/// 分段、上下文、参考词、护栏都共用，只有提示词、输出形状、解析按方式分开（见 `correctTranscript`）
public enum CorrectionMethod: Hashable, Sendable {
    /// 本机：只输出替换 `{"fixes": [{"id", "from", "to"}]}`，GBNF 文法限定 id 范围和条数
    case wordFixes
    /// 在线：输出改后的整句 `{"edits": [{"id", "text"}]}`，只列改了的句子，由代码比对出改了什么。
    /// 没有文法，靠各协议的 JSON 模式（Anthropic 没有，同纪要只靠截取）
    case sentenceRewrite

    public var scope: CorrectionScope {
        switch self {
        case .wordFixes: .wordsOnly
        case .sentenceRewrite: .full
        }
    }

    /// 纪要引擎对应的纠错方式。为 nil 时纠错不跑、不报错，直接走纪要（现在每种引擎都支持）
    public static func forMinutesEngine(isOnline: Bool) -> CorrectionMethod? {
        isOnline ? .sentenceRewrite : .wordFixes
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
        case .sentenceRewrite:
            var edits: [SentenceEdit]?
            for _ in 0..<2 where edits == nil {
                try Task.checkCancellation()
                edits = parseSentenceEdits(try await generator.generate(system: system, prompt: prompt,
                                                                        maxTokens: budget.outputTokens, grammar: nil))
            }
            guard let edits else {
                review.reject(.unparseable)
                continue
            }
            let texts = Dictionary(sentences.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
            // 不认识的 id 原样交给护栏，按规则 1 记一条；没改的句子不算修改
            let changes = edits.compactMap { edit -> CorrectionChange? in
                let before = texts[edit.id] ?? ""
                guard edit.text != before else { return nil }
                return CorrectionChange(sentenceID: edit.id, offset: 0, before: before, after: edit.text)
            }
            review.merge(reviewCorrections(changes, context: correction))
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
    case .sentenceRewrite:
        return """
        你是会议转写稿的校对助手。转写稿由语音识别生成，常有这几类错误：
        - 读音相近的错字词，例如“被动”识别成“对动”、“工位上”识别成“工会上”、“端到端”识别成“端道的”；
        - 漏掉的字；
        - 识别残留：同一个字或词失控地连续重复很多遍（“吧吧吧吧吧吧”），与上一句完全相同的整句重复，\
        [breath]、/sil 这类标记。
        \(format)
        任务：根据上下文改正这些错误，输出改后的整句。
        - 可以换读音相近的字词、补漏掉的字、删识别残留、调整句内标点。
        - 口语词（嗯、那个、就是）和口吃（我我我觉得、就是就是）都保留，不算错误。不润色、不改说法、不调语序。
        - 不合并、不拆分句子，不在句子之间挪动文字。与上一句完全相同的重复句，text 输出空字符串 "" 表示删掉。
        - 拿不准就不改。只列出改了的句子，没改的不要列；没有要改的就输出空列表。
        - text 是这一句改后的完整内容，不带句子编号和说话人。
        - 标着“只读”的上文只供理解，不要改。
        \(referenceLine)
        只输出 JSON：{"edits": [{"id": "s12", "text": "我们要避免被动的局面"}]}
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

/// 取输出里第一个 `{` 到最后一个 `}` 当 JSON（同 `parseDraft`），截断时救回写完的条目（见 `jsonEntries`）。
/// 没有 `fixes` 列表时为 nil（解析失败）；单条形状不对只丢掉那一条。`from` 与 `to` 相同的条目（模型把没改的字
/// 也列出来）和重复列出的同一条不算修改，直接去掉，免得护栏按 `from` 对不上把同一句的其他修改也丢掉
func parseWordFixes(_ output: String) -> [WordFix]? {
    guard let entries = jsonEntries(output, key: "fixes") else { return nil }
    var seen = Set<WordFix>()
    return entries.compactMap { entry in
        guard let entry = entry as? [String: Any], let id = entry["id"] as? String,
              let from = entry["from"] as? String, let to = entry["to"] as? String, from != to,
              seen.insert(WordFix(id: id, from: from, to: to)).inserted else { return nil }
        return WordFix(id: id, from: from, to: to)
    }
}

/// 输出 `{"<key>": [...]}` 里的列表：取第一个 `{` 到最后一个 `}` 当 JSON（同 `parseDraft`）。
/// 输出被截断（改得多时会碰到输出上限）时，退到最后一个写完的条目，补上 `]}` 收尾，救回前面的
func jsonEntries(_ output: String, key: String) -> [Any]? {
    guard let open = output.firstIndex(of: "{") else { return nil }
    func entries(_ json: String) -> [Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?[key] as? [Any]
    }
    var found: [Any]?
    if let close = output.lastIndex(of: "}"), open < close {
        found = entries(String(output[open...close]))
    }
    if found == nil, output.contains("\"\(key)\"") {
        // 截断：从后往前试每个 `}`，补上 `]}` 收尾
        var end = output.endIndex
        while found == nil, let close = output[open..<end].lastIndex(of: "}") {
            found = entries(output[open...close] + "]}")
            end = close
        }
    }
    return found
}

/// 在线输出的一条整句改写：`{"id": "s12", "text": "…"}`。`text` 为空表示整句删掉（与上一句重复）
public struct SentenceEdit: Hashable, Sendable {
    public var id: String
    public var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// 取输出里第一个 `{` 到最后一个 `}` 当 JSON（同 `parseDraft`）。没有 `edits` 列表时为 nil（解析失败）；
/// 单条形状不对只丢掉那一条，同一句只认第一条，`text` 开头抄了行首的「[s12 说话人 2] 」时去掉。
/// 输出被截断（常规会议一次整场，改得多时会碰到输出上限）时，退到最后一个写完的条目，救回前面的
func parseSentenceEdits(_ output: String) -> [SentenceEdit]? {
    guard let found = jsonEntries(output, key: "edits") else { return nil }
    var seen = Set<String>()
    return found.compactMap { entry in
        guard let entry = entry as? [String: Any], let id = entry["id"] as? String, var text = entry["text"] as? String,
              seen.insert(id).inserted else { return nil }
        let tag = "[\(id)"
        if text.hasPrefix(tag + "]") || text.hasPrefix(tag + " "), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        return SentenceEdit(id: id, text: text)
    }
}
