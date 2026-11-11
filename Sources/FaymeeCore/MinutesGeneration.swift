import Foundation

/// 由转写稿快照生成纪要。纯函数：不读写文件、不加载或释放模型（那是管线的事），只调用
/// `generator` 的 `contextTokens`、`countTokens`、`generate`。
///
/// - Parameters:
///   - transcript: 开始生成时读的快照，输入、出处校验、`source` 都用它
///   - title: 会议标题
///   - startedAt: 会议开始时间，按 `timeZone` 换算出日期和星期，供模型换算截止时间
///   - model: 写进 `Minutes.model` 的引擎标识，如 "llama/qwen3-4b-q4km"
///   - createdAt: 写进 `Minutes.createdAt`
public func generateMinutes(
    transcript: Transcript, title: String, startedAt: Date, template: MinutesTemplate,
    generator: TextGenerator, model: String, createdAt: Date = Date(), timeZone: TimeZone = .current,
    progress: (Double) -> Void = { _ in }
) async throws -> Minutes {
    let sentences = Dictionary(transcript.sentences.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let sentenceIDs = Set(sentences.keys)
    let meeting = MeetingInfo(title: title, startedAt: startedAt, timeZone: timeZone)
    let labels = SpeakerLabels(transcript)
    let system = extractionSystemPrompt(template, speakers: labels)
    let grammar = outputGrammar(template.sections.map(\.kind), speakers: labels.unnamedLabels)
    let budget = Budget(generator, system: system, outputTokens: generator.contextTokens * 2 / 5)

    let lineBudget = budget.promptTokens - generator.countTokens(extractionPrompt(meeting, lines: [], partial: true))
    let segments = try segment(transcript.items, lineBudget: lineBudget, countTokens: generator.countTokens,
                               line: labels.line) {
        budget.fits(extractionPrompt(meeting, lines: $0.map(labels.line), partial: true))
    }
    var drafts: [Draft] = []
    var guesses: [NameGuess] = []
    for (n, items) in segments.enumerated() {
        let prompt = extractionPrompt(meeting, lines: items.map(labels.line), partial: segments.count > 1)
        let (draft, output) = try await generateOutput(generator, system: system, prompt: prompt,
                                                       maxTokens: budget.outputTokens, template: template,
                                                       grammar: grammar)
        drafts.append(draft.validated(against: sentenceIDs))
        // 说话人身份只在提取时要，各段的结果由代码投票，不交给合并
        if labels.wantsNames { guesses += labels.validated(parseNameGuesses(output), in: items) }
        if segments.count > 1 { progress(Double(n + 1) / Double(segments.count + 1)) }
    }
    let draft = drafts.count > 1
        ? try await merge(drafts, meeting: meeting, template: template, generator: generator,
                          outputTokens: generator.contextTokens / 2)
        : drafts.first ?? [:]
    progress(1)

    let sections = makeSections(draft, template: template, sentences: sentences, meeting: meeting, labels: labels)
    return Minutes(model: model, template: template.key, createdAt: createdAt,
                   source: MinutesSource(transcriptCreatedAt: transcript.createdAt, textHash: transcript.textHash,
                                         speakersCreatedAt: transcript.speakersCreatedAt),
                   sections: sections, nameSuggestions: labels.suggestions(guesses, sentences: sentences))
}

/// 一次调用的 token 预算：系统提示 + 提示词 + 输出 ≤ contextTokens。
/// 留给输出的比例按 Qwen3 4B 实测定（ticket 04）：
/// - 提取 2/5：内容密集的转写稿，输出可达转写稿行的 0.6–0.7 倍（37 句周会 970 token 出约 650；
///   合成的密集转写稿 4.1k 出 2.5k–2.7k+），原来的 1/4、试过的 1/3 都会截断
/// - 合并 1/2：输出和输入的条目差不多长，留一半才装得下
struct Budget {
    let generator: TextGenerator
    /// 留给输出的 token 数，作为 generate 的 maxTokens
    let outputTokens: Int
    /// 留给提示词的 token 数。同一种调用的系统提示不变，它的 token 数只算一次
    let promptTokens: Int

    init(_ generator: TextGenerator, system: String, outputTokens: Int) {
        self.generator = generator
        self.outputTokens = outputTokens
        promptTokens = generator.contextTokens - outputTokens - generator.countTokens(system)
    }

    /// 按拼好的完整提示词计算，不靠逐行估算
    func fits(_ prompt: String) -> Bool {
        generator.countTokens(prompt) <= promptTokens
    }
}

/// `lower...upper` 里使 `fits` 成立的最大值，没有时为 nil。`fits` 须单调：对某个值不成立，对更大的也不成立。
/// 先试 `upper`（通常都放得下，只算一次），不行再二分，不逐个递减：每试一次都要拼整份提示词再分词
func largestFitting(_ lower: Int, _ upper: Int, _ fits: (Int) -> Bool) -> Int? {
    guard lower <= upper else { return nil }
    if fits(upper) { return upper }
    var lo = lower, hi = upper - 1
    var found: Int?
    while lo <= hi {
        let mid = (lo + hi) / 2
        if fits(mid) {
            found = mid
            lo = mid + 1
        } else {
            hi = mid - 1
        }
    }
    return found
}

/// 同 `largestFitting`，但从 `lower` 起倍增试探，第一次放不下后再在两次之间二分。
/// 结果通常远小于 `upper` 时用（如分批合并，一批常常只凑得下几份）：不必先拼一遍剩下的全部
func largestFittingGrowing(_ lower: Int, _ upper: Int, _ fits: (Int) -> Bool) -> Int? {
    guard lower <= upper, fits(lower) else { return nil }
    var good = lower
    var step = 1
    while good < upper {
        let next = min(good + step, upper)
        guard fits(next) else { return largestFitting(good + 1, next - 1, fits) ?? good }
        good = next
        step *= 2
    }
    return good
}

/// 把转写稿在条目（句子或合盖空白）边界切成若干段，每段都满足 `fits`。`line` 是条目写进提示词的那一行。
/// 先按逐行 token 数估算尽量装满，再用 `fits` 按完整提示词核对，超了就把末尾的条目挪到下一段
/// （二分找能放下的最多条目）；装不下时在后半段里找切点：优先在合盖空白之后，
/// 其次在最长的停顿处（至少 `longPause` 秒），都没有就切在装满的位置
func segment(_ items: [TranscriptItem], lineBudget available: Int, countTokens: (String) -> Int,
             line: (TranscriptItem) -> String = inputLine,
             fits: (ArraySlice<TranscriptItem>) -> Bool) throws -> [[TranscriptItem]] {
    let longPause: TimeInterval = 5
    let costs = items.map { countTokens(line($0)) + 1 }

    var segments: [[TranscriptItem]] = []
    var start = 0
    while start < items.count {
        var end = start
        var used = 0
        while end < items.count, used + costs[end] <= available {
            used += costs[end]
            end += 1
        }
        if end > start {
            end = largestFitting(start + 1, end) { fits(items[start..<$0]) } ?? start
        }
        guard end > start else { throw MinutesGenerationError.contextTooSmall }
        if end < items.count {
            let candidates = (start + (end - start + 1) / 2)...end
            if let afterGap = candidates.last(where: { if case .gap = items[$0 - 1] { true } else { false } }) {
                end = afterGap
            } else if let pause = candidates.filter({ $0 < items.count })
                .max(by: { items[$0].start - items[$0 - 1].end < items[$1].start - items[$1 - 1].end }),
                items[pause].start - items[pause - 1].end >= longPause {
                end = pause
            }
        }
        segments.append(Array(items[start..<end]))
        start = end
    }
    return segments
}

/// 合并各段的条目：只给条目和出处，不再给原文。每次合并输出里没在该次输入中出现过的出处丢弃。
/// 所有条目一次放不下时，按顺序把相邻的几段凑成一批（放得下的最多段数）分别合并，
/// 再合并各批的结果，直到只剩一份。某一轮一批都凑不成、或某批合并重试后仍解析不出时，
/// 不让整场失败，把这一轮的各份交给 `concatenate`
private func merge(_ drafts: [Draft], meeting: MeetingInfo, template: MinutesTemplate,
                   generator: TextGenerator, outputTokens: Int) async throws -> Draft {
    let system = mergeSystemPrompt(template)
    let budget = Budget(generator, system: system, outputTokens: outputTokens)
    func prompt(_ group: ArraySlice<Draft>) -> String {
        mergePrompt(meeting, draft: combine(group), template: template)
    }

    var level = drafts
    while level.count > 1 {
        var next: [Draft] = []
        var start = 0
        while start < level.count {
            let end = largestFittingGrowing(start + 2, level.count) { budget.fits(prompt(level[start..<$0])) }
                ?? start + 1
            let group = level[start..<end]
            if group.count == 1 {
                next.append(group[start])
            } else {
                let merged: Draft
                do {
                    merged = try await generateDraft(generator, system: system, prompt: prompt(group),
                                                     maxTokens: budget.outputTokens, template: template)
                } catch MinutesGenerationError.unparseableOutput {
                    // 多半是输出到上限被截断，也是放不下；各段条目已经有了，不让整场失败
                    return try await concatenate(level, meeting: meeting, template: template,
                                                 generator: generator, outputTokens: outputTokens)
                }
                next.append(merged.validated(against: allowedRefs(group)))
            }
            start = end
        }
        guard next.count < level.count else {
            return try await concatenate(level, meeting: meeting, template: template, generator: generator,
                                         outputTokens: outputTokens)
        }
        level = next
    }
    return level[0]
}

/// 合并的兜底：模型一次装不下时，各节直接按顺序拼接各份的条目，不让模型去重。
/// 文字、负责人、截止时间都相同的才算重复，只留第一条，出处取并集（再截到 `maxRefs` 个）。
/// 各段的概要拼起来太多太碎，单独做一次只有概要的小合并；放不下、或重试后仍解析不出，就用拼接的。
/// 两种情况概要都只留前 `maxFallbackOverviews` 条（拼接的就只剩前几段的概要）
private func concatenate(_ drafts: [Draft], meeting: MeetingInfo, template: MinutesTemplate,
                         generator: TextGenerator, outputTokens: Int) async throws -> Draft {
    var result = Draft()
    for (kind, _) in template.sections {
        let key = sectionKey(kind)
        var items: [DraftItem] = []
        for item in drafts.flatMap({ $0[key] ?? [] }) {
            if let n = items.firstIndex(where: { $0.text == item.text && $0.owner == item.owner && $0.due == item.due }) {
                items[n].refs = Array((items[n].refs + item.refs.filter { !items[n].refs.contains($0) }).prefix(maxRefs))
            } else {
                items.append(item)
            }
        }
        if !items.isEmpty { result[key] = items }
    }

    let overviewKey = sectionKey(.overview)
    let overviews = drafts.map { [overviewKey: $0[overviewKey] ?? []] }
    let system = overviewMergeSystemPrompt(template)
    let budget = Budget(generator, system: system, outputTokens: outputTokens)
    let prompt = mergePrompt(meeting, draft: combine(overviews[...]), template: template, sections: [.overview])
    if overviews.count(where: { !$0[overviewKey]!.isEmpty }) > 1, budget.fits(prompt) {
        do {
            let merged = try await generateDraft(generator, system: system, prompt: prompt,
                                                 maxTokens: budget.outputTokens, template: template,
                                                 sections: [.overview])
                .validated(against: allowedRefs(overviews[...]))
            if let items = merged[overviewKey], !items.isEmpty { result[overviewKey] = items }
        } catch MinutesGenerationError.unparseableOutput {}
    }
    if let items = result[overviewKey] { result[overviewKey] = Array(items.prefix(maxFallbackOverviews)) }
    return result
}

/// 合并兜底时概要最多留的条数（spec「输出格式与校验」）。小合并的提示词要求 3–6 条，
/// 实测模型不守（ticket 11 给了 12 条）；各段概要直接拼接时也可能很多
let maxFallbackOverviews = 6

/// 一次合并的输出里允许出现的出处：该次输入里出现过的
private func allowedRefs(_ drafts: ArraySlice<Draft>) -> Set<String> {
    Set(drafts.flatMap { $0.values.flatMap { $0.flatMap(\.refs) } })
}

/// 按顺序把几份条目拼在一起
private func combine(_ drafts: ArraySlice<Draft>) -> Draft {
    var combined = Draft()
    for draft in drafts {
        for (key, items) in draft { combined[key, default: []] += items }
    }
    return combined
}

/// 模型输出的一条。`owner`、`due`、`dueDate` 只有待办节的条目有，`dueDate` 是模型给的原样字符串
struct DraftItem {
    var text: String
    var owner: String?
    var due: String?
    var dueDate: String?
    /// 句子 id，校验前可能有不存在的
    var refs: [String]
}

/// 按节的 key（overview/decisions/actions/questions 或 custom 的 key）分组的条目
typealias Draft = [String: [DraftItem]]

/// 每个条目最多保留的出处数。实测模型会在 refs 里一直往下列编号（ticket 04），提示词也要求最多 3 个
let maxRefs = 3

extension Dictionary where Key == String, Value == [DraftItem] {
    /// 只留下 `allowed` 里的出处，去掉重复，再按模型给的顺序取前 `maxRefs` 个。
    /// 先校验再截断，免得不存在的编号占了名额。条目即使一个出处都不剩也保留
    func validated(against allowed: Set<String>) -> Draft {
        mapValues { items in
            items.map { item in
                var seen = Set<String>()
                var item = item
                item.refs = Array(item.refs.filter { allowed.contains($0) && seen.insert($0).inserted }.prefix(maxRefs))
                return item
            }
        }
    }
}

/// 按模板的节排好，给条目编号（概要 o1、决议 d1、待办 a1、未决问题 q1、额外的节 <key>-1），
/// 出处记上快照里该句的 start。截止时间是常见说法时由代码按会议日期换算，否则用模型给的 dueDate。
/// 负责人对得上输入里的说话人时记下说话人 id。模型漏掉的节保留为空
private func makeSections(_ draft: Draft, template: MinutesTemplate, sentences: [String: TranscriptSentence],
                          meeting: MeetingInfo, labels: SpeakerLabels) -> [MinutesSection] {
    template.sections.map { kind, title in
        let items = (draft[sectionKey(kind)] ?? []).enumerated().map { n, item in
            MinutesItem(id: itemIDPrefix(kind) + String(n + 1), text: item.text, owner: item.owner, due: item.due,
                        dueDate: item.due.flatMap(meeting.dueDate(for:)) ?? item.dueDate.flatMap { CalendarDate($0) },
                        ownerSpeaker: item.owner.flatMap(labels.speakerID(owner:)),
                        refs: item.refs.compactMap { id in sentences[id].map { MinutesRef(id: id, start: $0.start) } })
        }
        return MinutesSection(kind: kind, title: title, items: items)
    }
}

private func itemIDPrefix(_ kind: MinutesSectionKind) -> String {
    switch kind {
    case .overview: "o"
    case .decisions: "d"
    case .actions: "a"
    case .questions: "q"
    case let .custom(key): key + "-"
    }
}

func sectionKey(_ kind: MinutesSectionKind) -> String {
    switch kind {
    case .overview: "overview"
    case .decisions: "decisions"
    case .actions: "actions"
    case .questions: "questions"
    case let .custom(key): key
    }
}

/// 调用一次模型并解析；解析失败时用同一段输入重试一次，还失败就抛 `unparseableOutput`。
/// 输出用文法约束成 `sections`（默认模板的全部节）的形状。
/// 引擎自己抛的错（含取消）原样抛出，不重试
private func generateDraft(_ generator: TextGenerator, system: String, prompt: String, maxTokens: Int,
                           template: MinutesTemplate, sections: [MinutesSectionKind]? = nil) async throws -> Draft {
    try await generateOutput(generator, system: system, prompt: prompt, maxTokens: maxTokens, template: template,
                             grammar: outputGrammar(sections ?? template.sections.map(\.kind))).draft
}

/// 同 `generateDraft`，文法由调用方给；连同解析成功的那次原始输出一起返回（提取时还要从中取说话人身份）
private func generateOutput(_ generator: TextGenerator, system: String, prompt: String, maxTokens: Int,
                            template: MinutesTemplate, grammar: String) async throws -> (draft: Draft, output: String) {
    for _ in 0..<2 {
        try Task.checkCancellation()
        let output = try await generator.generate(system: system, prompt: prompt, maxTokens: maxTokens, grammar: grammar)
        if let draft = parseDraft(output, template: template) { return (draft, output) }
    }
    throw MinutesGenerationError.unparseableOutput
}

/// 取输出里第一个 `{` 到最后一个 `}` 之间的文字当 JSON，容忍代码块包裹和前后的多余文字。
/// 一个预期的节都没有（如多包了一层、返回了错误信息）也算解析失败，免得悄悄产出空纪要；
/// 单个条目形状不对只丢掉那一条
func parseDraft(_ output: String, template: MinutesTemplate) -> Draft? {
    guard let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"), open < close,
          let object = try? JSONSerialization.jsonObject(with: Data(output[open...close].utf8)) as? [String: Any]
    else { return nil }
    var draft = Draft()
    for (kind, _) in template.sections {
        let key = sectionKey(kind)
        guard let entries = object[key] as? [Any] else { continue }
        draft[key] = entries.compactMap { entry in
            guard let entry = entry as? [String: Any], let text = nonEmpty(entry["text"]) else { return nil }
            let isAction = kind == .actions
            return DraftItem(text: text,
                             owner: isAction ? nonEmpty(entry["owner"]) : nil,
                             due: isAction ? nonEmpty(entry["due"]) : nil,
                             dueDate: isAction ? nonEmpty(entry["dueDate"]) : nil,
                             refs: (entry["refs"] as? [Any])?.compactMap { nonEmpty($0) } ?? [])
        }
    }
    return draft.isEmpty ? nil : draft
}

/// 去掉首尾空白后非空的字符串，其余（null、数字、空串）为 nil
private func nonEmpty(_ value: Any?) -> String? {
    guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    return s
}

public enum MinutesGenerationError: LocalizedError, Equatable {
    /// 同一段输入重试一次后，模型的输出仍然解析不出纪要
    case unparseableOutput
    /// 模型一次能处理的长度（contextTokens）连提示词加一句转写稿都放不下。
    /// 合并放不下时不抛这个，退回直接拼接各段条目
    case contextTooSmall

    public var errorDescription: String? {
        switch self {
        case .unparseableOutput: "模型输出无法解析"
        case .contextTooSmall: "模型一次能处理的内容太短，无法生成纪要"
        }
    }
}
