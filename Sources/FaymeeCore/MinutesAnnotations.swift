import Foundation

/// 纪要生成用的会中标注：标注区间和标注哈希，由纪要管线开始生成时从会议和转写稿快照算出（见 `generateMinutes`）
public struct MinutesAnnotations: Hashable, Sendable {
    /// 按时间排序，见 `Meeting.annotationSpans(in:)`。没有分片（换算不了）时为空
    public var spans: [AnnotationSpan]
    /// 写进 `MinutesSource.annotationsHash`，见 `Meeting.annotationsHash`
    public var hash: String

    public init(spans: [AnnotationSpan], hash: String) {
        self.spans = spans
        self.hash = hash
    }
}

extension Meeting {
    /// 会议没有会中标注时为 nil：纪要与 v0.4 逐字相同
    public func minutesAnnotations(in transcript: Transcript) -> MinutesAnnotations? {
        guard let hash = annotationsHash else { return nil }
        return MinutesAnnotations(spans: annotationSpans(in: transcript), hash: hash)
    }
}

/// 一个区间展开的结果，还没编号
struct ExpandedAnnotation {
    var text: String
    /// 句子 id，都在给模型的输入里，1–3 个；笔记原话为空
    var refs: [String]
    var origin: MinutesItem.Origin
}

/// 展开一个区间（spec「纪要生成 › 每个区间单独展开一次」）。返回 nil 表示这条不进纪要。
/// - 区间里没有句子：标记不进纪要；笔记不调用模型，退回原话
/// - 一次放不下时，从区间两端（离标注时刻较远的一端）去掉句子直到放下；一句都放不下同没有句子
/// - 输出的出处只留给模型的句子，去重后取前 `maxRefs` 个；一个不剩，或同一段输入重试一次后仍解析不出，
///   标记丢掉、笔记退回原话，不让整份纪要失败。引擎自己抛的错（含取消）照常抛出
func expand(_ span: AnnotationSpan, title: String, sentences: [String: TranscriptSentence], labels: SpeakerLabels,
            generator: TextGenerator) async throws -> ExpandedAnnotation? {
    let fallback = span.kind == .note ? span.noteText.map { ExpandedAnnotation(text: $0, refs: [], origin: .note) }
        : nil
    let system = expansionSystemPrompt(span.kind, speakers: labels)
    let budget = Budget(generator, system: system, outputTokens: generator.contextTokens * 2 / 5)
    func prompt(_ given: ArraySlice<TranscriptSentence>) -> String {
        expansionPrompt(title: title, kind: span.kind, note: span.noteText,
                        lines: given.map { labels.line(.sentence($0)) })
    }

    var given = ArraySlice(span.sentenceIDs.compactMap { sentences[$0] })
    while let first = given.first, let last = given.last, !budget.fits(prompt(given)) {
        if span.at - first.start >= last.end - span.at { given.removeFirst() } else { given.removeLast() }
    }
    guard !given.isEmpty else { return fallback }

    let allowed = Set(given.map(\.id))
    let input = prompt(given)
    for _ in 0..<2 {
        try Task.checkCancellation()
        let output = try await generator.generate(system: system, prompt: input, maxTokens: budget.outputTokens,
                                                  grammar: expansionGrammar)
        guard let (text, refs) = parseExpansion(output) else { continue }
        var seen = Set<String>()
        let valid = Array(refs.filter { allowed.contains($0) && seen.insert($0).inserted }.prefix(maxRefs))
        return valid.isEmpty ? fallback : ExpandedAnnotation(text: text, refs: valid, origin: .model)
    }
    return fallback
}

/// 取输出里的 `{text, refs}`（JSON 的截取同 `parseDraft`）。不是对象、没有文字时为 nil
private func parseExpansion(_ output: String) -> (text: String, refs: [String])? {
    guard let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"), open < close,
          let object = try? JSONSerialization.jsonObject(with: Data(output[open...close].utf8)) as? [String: Any],
          let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
    else { return nil }
    let refs = (object["refs"] as? [Any])?.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) } ?? []
    return (text, refs)
}

/// 「会中标注」一节：条目按区间的时间顺序编号 n1、n2……，关联区间所含的标注 id，笔记带上原话
func annotationsSection(_ expanded: [(AnnotationSpan, ExpandedAnnotation)],
                        sentences: [String: TranscriptSentence]) -> MinutesSection {
    MinutesSection(kind: .annotations, title: "会中标注", items: expanded.enumerated().map { n, pair in
        let (span, item) = pair
        return MinutesItem(id: "n\(n + 1)", text: item.text,
                           refs: item.refs.compactMap { id in sentences[id].map { MinutesRef(id: id, start: $0.start) } },
                           origin: item.origin, annotationIDs: span.annotationIDs,
                           note: span.kind == .note ? span.noteText : nil)
    })
}
