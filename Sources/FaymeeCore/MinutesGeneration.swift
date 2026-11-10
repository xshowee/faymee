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
    let budget = Budget(generator)
    let system = extractionSystemPrompt(template)

    let lineBudget = generator.contextTokens - budget.outputTokens - generator.countTokens(system)
        - generator.countTokens(extractionPrompt(meeting, lines: [], partial: true))
    let segments = try segment(transcript.items, lineBudget: lineBudget, countTokens: generator.countTokens) {
        budget.fits(system: system, prompt: extractionPrompt(meeting, lines: $0.map(inputLine), partial: true))
    }
    var drafts: [Draft] = []
    for (n, items) in segments.enumerated() {
        let prompt = extractionPrompt(meeting, lines: items.map(inputLine), partial: segments.count > 1)
        let draft = try await generateDraft(generator, system: system, prompt: prompt,
                                            maxTokens: budget.outputTokens, template: template)
        drafts.append(draft.validated(against: sentenceIDs))
        if segments.count > 1 { progress(Double(n + 1) / Double(segments.count + 1)) }
    }
    let draft = drafts.count > 1
        ? try await merge(drafts, meeting: meeting, template: template, generator: generator, budget: budget)
        : drafts.first ?? [:]
    progress(1)

    let sections = makeSections(draft, template: template, sentences: sentences)
    return Minutes(model: model, template: template.key, createdAt: createdAt,
                   source: MinutesSource(transcriptCreatedAt: transcript.createdAt, textHash: transcript.textHash),
                   sections: sections)
}

/// 一次调用的 token 预算：系统提示 + 提示词 + 输出 ≤ contextTokens
struct Budget {
    let generator: TextGenerator
    /// 留给输出的 token 数，作为 generate 的 maxTokens
    let outputTokens: Int

    init(_ generator: TextGenerator) {
        self.generator = generator
        outputTokens = generator.contextTokens / 4
    }

    /// 按拼好的完整字符串计算，不靠逐行估算
    func fits(system: String, prompt: String) -> Bool {
        generator.countTokens(system) + generator.countTokens(prompt) + outputTokens <= generator.contextTokens
    }
}

/// 把转写稿在条目（句子或合盖空白）边界切成若干段，每段都满足 `fits`。
/// 先按逐行 token 数估算尽量装满，装不下时在后半段里找切点：优先在合盖空白之后，
/// 其次在最长的停顿处（至少 `longPause` 秒），都没有就切在装满的位置；
/// 最后用 `fits` 按完整提示词核对，超了就把末尾的条目挪到下一段
func segment(_ items: [TranscriptItem], lineBudget available: Int, countTokens: (String) -> Int,
             fits: (ArraySlice<TranscriptItem>) -> Bool) throws -> [[TranscriptItem]] {
    let longPause: TimeInterval = 5
    let costs = items.map { countTokens(inputLine($0)) + 1 }

    var segments: [[TranscriptItem]] = []
    var start = 0
    while start < items.count {
        var end = start
        var used = 0
        while end < items.count, used + costs[end] <= available {
            used += costs[end]
            end += 1
        }
        while end > start, !fits(items[start..<end]) { end -= 1 }
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
/// 再合并各批的结果，直到只剩一份；某一轮一批都凑不成时抛 `contextTooSmall`
private func merge(_ drafts: [Draft], meeting: MeetingInfo, template: MinutesTemplate,
                   generator: TextGenerator, budget: Budget) async throws -> Draft {
    let system = mergeSystemPrompt(template)
    func prompt(_ group: ArraySlice<Draft>) -> String {
        mergePrompt(meeting, draft: combine(group), template: template)
    }

    var level = drafts
    while level.count > 1 {
        var next: [Draft] = []
        var start = 0
        while start < level.count {
            var end = start + 1
            while end < level.count, budget.fits(system: system, prompt: prompt(level[start...end])) { end += 1 }
            let group = level[start..<end]
            if group.count == 1 {
                next.append(group[start])
            } else {
                let combined = combine(group)
                let allowed = Set(combined.values.flatMap { $0.flatMap(\.refs) })
                let merged = try await generateDraft(generator, system: system, prompt: prompt(group),
                                                     maxTokens: budget.outputTokens, template: template)
                next.append(merged.validated(against: allowed))
            }
            start = end
        }
        guard next.count < level.count else { throw MinutesGenerationError.contextTooSmall }
        level = next
    }
    return level[0]
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

extension Dictionary where Key == String, Value == [DraftItem] {
    /// 只留下 `allowed` 里的出处，去掉重复。条目即使一个出处都不剩也保留
    func validated(against allowed: Set<String>) -> Draft {
        mapValues { items in
            items.map { item in
                var seen = Set<String>()
                var item = item
                item.refs = item.refs.filter { allowed.contains($0) && seen.insert($0).inserted }
                return item
            }
        }
    }
}

/// 按模板的节排好，给条目编号（概要 o1、决议 d1、待办 a1、未决问题 q1、额外的节 <key>-1），
/// 出处记上快照里该句的 start。模型漏掉的节保留为空
private func makeSections(_ draft: Draft, template: MinutesTemplate,
                          sentences: [String: TranscriptSentence]) -> [MinutesSection] {
    template.sections.map { kind, title in
        let items = (draft[sectionKey(kind)] ?? []).enumerated().map { n, item in
            MinutesItem(id: itemIDPrefix(kind) + String(n + 1), text: item.text, owner: item.owner, due: item.due,
                        dueDate: item.dueDate.flatMap { CalendarDate($0) },
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
/// 引擎自己抛的错（含取消）原样抛出，不重试
private func generateDraft(_ generator: TextGenerator, system: String, prompt: String, maxTokens: Int,
                           template: MinutesTemplate) async throws -> Draft {
    for _ in 0..<2 {
        try Task.checkCancellation()
        let output = try await generator.generate(system: system, prompt: prompt, maxTokens: maxTokens)
        if let draft = parseDraft(output, template: template) { return draft }
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
    /// 模型一次能处理的长度（contextTokens）连提示词加一句转写稿都放不下，或者合并时没法再分批
    case contextTooSmall

    public var errorDescription: String? {
        switch self {
        case .unparseableOutput: "模型输出无法解析"
        case .contextTooSmall: "模型一次能处理的内容太短，无法生成纪要"
        }
    }
}
