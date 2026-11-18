import Foundation

/// 纠错的范围，按引擎分档（spec「范围（按引擎）」）
public enum CorrectionScope: Sendable {
    /// 本机：只换读音相近的字词，补字、删字、改标点一律不收
    case wordsOnly
    /// 在线：换字词、补漏字、删识别造成的多字、调整句内标点
    case full
}

/// 护栏挡掉一条修改的规则，记进转写稿纠错信息里的分类计数（`TranscriptCorrection.rejections`，键是 rawValue）。
/// 界面不显示，留作以后调整依据。新增规则只加 case，旧文件里没有的键照常读
public enum CorrectionRule: String, Codable, CaseIterable, Sendable {
    /// 规则 1：不在这一段可改的范围里（只读上下文、不认识的 id），或已被手动改过
    case notEditable
    /// 本机：`from` 不在句子里、出现不止一次，或同一句的几条互相重叠
    case source
    /// 超出引擎的范围：本机的补字、删字、改标点
    case scope
    /// 规则 3：换字词读音不近
    case pinyin
    /// 规则 4：补字超过每句合计、连续补 2 字以上却没有来源
    case insertion
    /// 规则 5：删的不是识别残留（口吃、口语词、随意删字）
    case deletion
    /// 规则 6：改动比例超限
    case changeRatio
    /// 规则 7：数字建议读音不近、改后的数字在别处也没出现过，丢弃（只丢这条建议，不连累同一句的其他修改）
    case number
    /// 增删或换掉了否定词（不、没、别、未、无、非）或人称代词（我、你、他……及「们」的形式）：读音再近，
    /// 意思也反了或换了人。spec 之外的保守护栏，同「宁可漏改，不能编造」；识别残留照删
    case negationOrPronoun
    /// 模型输出解析不出（重试后仍不行），这一段没有修改
    case unparseable
}

/// 一条修改提议：把句子 `sentenceID` 里从字符位置 `offset` 起的 `before` 换成 `after`。
/// 本机的一条换字词是 `from` 在句中的位置（见 `reviewWordFixes`）；在线的整句改写是 offset 0、before 为整句
public struct CorrectionChange: Hashable, Sendable {
    public var sentenceID: String
    public var offset: Int
    public var before: String
    public var after: String

    public init(sentenceID: String, offset: Int, before: String, after: String) {
        self.sentenceID = sentenceID
        self.offset = offset
        self.before = before
        self.after = after
    }
}

/// 本机模型输出的一条替换：`{"id": "s412", "from": "对动", "to": "被动"}`
public struct WordFix: Hashable, Sendable {
    public var id: String
    public var from: String
    public var to: String

    public init(id: String, from: String, to: String) {
        self.id = id
        self.from = from
        self.to = to
    }
}

/// 护栏校验用到的这一段的上下文
public struct CorrectionContext: Sendable {
    public var scope: CorrectionScope
    /// 这一段可改的句子 id（不含只读上下文）。手动改过的句子即使在里面也不改
    public var editable: Set<String>
    /// 转写稿快照的全部句子（参考词、数字建议的「别处出现过」都按整份算）
    public var sentences: [TranscriptSentence]
    public var references: ReferenceWords

    public init(scope: CorrectionScope, editable: Set<String>, sentences: [TranscriptSentence],
                references: ReferenceWords) {
        self.scope = scope
        self.editable = editable
        self.sentences = sentences
        self.references = references
    }

    /// 规则 4：`text` 在句子 `sentence` 前后 `CorrectionThreshold.nearbySentences` 句（不含这一句）里原样出现过
    func occursNearby(_ text: String, sentence: String) -> Bool {
        guard !text.isEmpty, let i = sentences.firstIndex(where: { $0.id == sentence }) else { return false }
        let n = CorrectionThreshold.nearbySentences
        return sentences[max(0, i - n)...min(sentences.count - 1, i + n)]
            .contains { $0.id != sentence && $0.text.contains(text) }
    }

    /// 规则 7：`text` 在转写稿别处（不含句子 `sentence`）原样出现过，数字建议「改后的数字在转写稿别处出现过」
    func occursElsewhere(_ text: String, sentence: String) -> Bool {
        !text.isEmpty && sentences.contains { $0.id != sentence && $0.text.contains(text) }
    }
}

/// 护栏的结论
public struct CorrectionReview: Hashable, Sendable {
    /// 过了护栏的句子 → 改后的文字（只含真有变化的句子）
    public var texts: [String: String] = [:]
    /// 数字建议，不应用
    public var suggestions: [NumberSuggestion] = []
    /// 被挡掉的条数，键是 `CorrectionRule.rawValue`。整句丢弃的按第一处不过的规则记一条；
    /// 校验前就对不上的（不可改的句子、`from` 对不上）每条记一条；丢弃的数字建议每条记一条
    public var rejections: [String: Int] = [:]

    public init(texts: [String: String] = [:], suggestions: [NumberSuggestion] = [],
                rejections: [String: Int] = [:]) {
        self.texts = texts
        self.suggestions = suggestions
        self.rejections = rejections
    }

    mutating func reject(_ rule: CorrectionRule, count: Int = 1) {
        rejections[rule.rawValue, default: 0] += count
    }

    /// 多段的结论合在一起
    mutating func merge(_ other: CorrectionReview) {
        texts.merge(other.texts) { _, new in new }
        suggestions += other.suggestions
        rejections.merge(other.rejections, uniquingKeysWith: +)
    }
}

/// 换字词时读音相近的门槛（拼音编辑距离比）
public enum CorrectionThreshold {
    public static let pinyin = 0.34
    /// 改后是参考词时
    public static let pinyinReference = 0.5
    /// 拼音比按改动处向两边扩到至少这么多个字计算：「对→被」单看一个字差很远，「对动→被动」才是 0.29。
    /// 本机只在模型给的 `from`/`to` 范围里扩，在线在整句里扩
    public static let pinyinUnit = 3
    /// 规则 6：改动不超过原句字数的这个比例
    public static let changeRatio = 0.3
    /// 规则 6：原句不到 `shortSentence` 个字时最多改这么多个字
    public static let shortSentence = 10
    public static let shortSentenceChanges = 3
    /// 规则 4：每句补的字合计不超过这么多个
    public static let insertedCharacters = 6
    /// 规则 4：连续补 2 个字以上的，须在前后这么多句里出现过（或是参考词）
    public static let nearbySentences = 5
}

/// 本机：先把每条 `from` 定位到句子里（必须恰好出现一次、同一句的几条不重叠），再过 `reviewCorrections`
public func reviewWordFixes(_ fixes: [WordFix], context: CorrectionContext) -> CorrectionReview {
    var review = CorrectionReview()
    let sentences = Dictionary(context.sentences.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var changes: [CorrectionChange] = []
    var located: [String: [Range<Int>]] = [:]
    var broken = Set<String>()
    for fix in fixes {
        guard let s = sentences[fix.id], context.editable.contains(fix.id), s.original == nil else {
            review.reject(.notEditable)
            continue
        }
        guard !fix.from.isEmpty, fix.from != fix.to, s.text.occurrences(of: fix.from) == 1,
              let found = s.text.range(of: fix.from) else {
            review.reject(.source)
            broken.insert(fix.id)
            continue
        }
        let offset = s.text.distance(from: s.text.startIndex, to: found.lowerBound)
        let range = offset..<offset + fix.from.count
        if located[fix.id, default: []].contains(where: { $0.overlaps(range) }) {
            review.reject(.source)
            broken.insert(fix.id)
            continue
        }
        located[fix.id, default: []].append(range)
        changes.append(CorrectionChange(sentenceID: fix.id, offset: offset, before: fix.from, after: fix.to))
    }
    // 一句里有一条对不上，这一句的修改整条丢弃
    review.merge(reviewCorrections(changes.filter { !broken.contains($0.sentenceID) }, context: context))
    return review
}

/// 护栏（spec「护栏」，本机、在线共用）：把每句的修改与原文做字符级比对，逐处校验。
/// 一句里有任何一处不过，这一句的修改整条丢弃，不截断；涉及数字的那几处不应用，转为数字建议，
/// 同一句的其他修改照常应用
public func reviewCorrections(_ changes: [CorrectionChange], context: CorrectionContext) -> CorrectionReview {
    var review = CorrectionReview()
    let sentences = Dictionary(context.sentences.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var order: [String] = []
    var bySentence: [String: [CorrectionChange]] = [:]
    for change in changes {
        if bySentence[change.sentenceID] == nil { order.append(change.sentenceID) }
        bySentence[change.sentenceID, default: []].append(change)
    }
    for id in order {
        let changes = bySentence[id]!.sorted { $0.offset < $1.offset }
        // 规则 1
        guard let sentence = sentences[id], context.editable.contains(id), sentence.original == nil else {
            review.reject(.notEditable, count: changes.count)
            continue
        }
        guard let corrected = apply(changes, to: sentence.text) else {
            review.reject(.source, count: changes.count)
            continue
        }
        review.merge(reviewSentence(sentence, corrected: corrected, changes: changes, context: context))
    }
    return review
}

/// 一句改前改后，逐处校验
private func reviewSentence(_ sentence: TranscriptSentence, corrected: String, changes: [CorrectionChange],
                            context: CorrectionContext) -> CorrectionReview {
    var review = CorrectionReview()
    let diff = TextDiff(from: sentence.text, to: corrected)
    let residue = RecognitionResidue(diff, sentence: sentence, sentences: context.sentences)
    var applied: [TextDiff.Segment] = []
    var suggestions: [NumberSuggestion] = []
    var discardedNumbers = 0
    // 规则 6 计入的字数：补字、删字和没过拼音校验的替换（过了拼音校验的替换、识别残留的删除不计入）
    var counted = 0
    // 规则 4：这一句补的字合计
    var inserted = 0
    var failure: CorrectionRule?

    for segment in diff.segments {
        // 改动处属于哪一条修改：拼音只在那一条的范围里扩
        let bounds = changes.map { $0.offset..<$0.offset + $0.before.count }
            .first { $0.contains(segment.beforeRange.lowerBound) || $0.upperBound == segment.beforeRange.lowerBound }
            ?? 0..<sentence.text.count
        switch check(segment, in: diff, bounds: bounds, residue: residue, sentence: sentence, context: context) {
        case .apply(let counts):
            applied.append(segment)
            counted += counts
            if segment.kind == .insert { inserted += counts }
        case .suggest(let unit):
            suggestions.append(NumberSuggestion(sentence: sentence.id, from: unit.before, to: unit.after))
        case .discardSuggestion:
            discardedNumbers += 1
        case .skip:
            break
        case .reject(let rule):
            failure = failure ?? rule
        }
    }
    if failure == nil, inserted > CorrectionThreshold.insertedCharacters {
        failure = .insertion
    }
    if failure == nil, exceedsChangeRatio(changed: counted, sentence: sentence.text) {
        failure = .changeRatio
    }
    if let failure {
        review.reject(failure)
        return review
    }
    if discardedNumbers > 0 { review.reject(.number, count: discardedNumbers) }
    review.suggestions = suggestions
    let text = diff.applying(applied)
    if text != sentence.text { review.texts[sentence.id] = text }
    return review
}

private enum Verdict {
    /// 应用；规则 6 计入多少个字
    case apply(counts: Int)
    /// 不应用，转为数字建议
    case suggest((before: String, after: String))
    /// 数字建议不成立，丢弃这一条（不连累同一句）
    case discardSuggestion
    /// 整句丢弃
    case reject(CorrectionRule)
    /// 不应用、不记挡掉（只加减空白：润色，不是纠错）
    case skip
}

private func check(_ segment: TextDiff.Segment, in diff: TextDiff, bounds: Range<Int>, residue: RecognitionResidue,
                   sentence: TranscriptSentence, context: CorrectionContext) -> Verdict {
    // 只加减空白（中英文之间加空格之类）是润色，不应用；同一句的其他修改照常
    if isWhitespaceOnly(segment) { return .skip }
    switch (segment.kind, context.scope) {
    case (_, .wordsOnly) where segment.kind != .replace:
        return .reject(.scope)
    case (.punctuation, .full):
        return .apply(counts: 0)
    default:
        break
    }
    // 识别残留照删，即使含数字字符（「看一下」整句重复、「等一下」复读）：留下的那份里数字还在。
    // 全是数字的复读不算残留（见 `RecognitionResidue`），往下按数字处理
    if segment.kind == .delete, residue.isResidue(segment) {
        return .apply(counts: 0)
    }
    let verdict = checkContent(segment, in: diff, bounds: bounds, sentence: sentence, context: context)
    // 否定词、人称代词：其他规则都过了也不改。按最小改动处看，拼音按扩开的范围比也藏不住
    switch verdict {
    case .apply, .suggest:
        if changesNegationOrPronoun(segment, in: diff) { return .reject(.negationOrPronoun) }
    default:
        break
    }
    return verdict
}

/// 替换、补字、删字（不是识别残留的）逐条过规则 3、4、5、7
private func checkContent(_ segment: TextDiff.Segment, in diff: TextDiff, bounds: Range<Int>,
                          sentence: TranscriptSentence, context: CorrectionContext) -> Verdict {
    // 规则 7：任一边含数字的一处（替换、补字、删字都算）不应用，转为数字建议
    if containsNumber(segment.before) || containsNumber(segment.after) {
        let near = pinyinCheck(segment, in: diff, bounds: bounds, sentence: sentence, context: context)
        guard let unit = diff.suggestionUnit(segment, within: bounds, attach: isNumberPart),
              near || context.occursElsewhere(unit.after, sentence: sentence.id) else {
            return .discardSuggestion
        }
        return .suggest(unit)
    }
    switch segment.kind {
    case .insert:
        // 规则 4：连续补 2 个字以上的须是参考词，或在前后几句里出现过；补的字计入规则 6
        let inserted = characterCount(segment.after)
        if inserted >= 2,
           context.references.match(in: diff.after, covering: segment.afterRange, sentence: sentence.id) == nil,
           !context.occursNearby(segment.after, sentence: sentence.id) {
            return .reject(.insertion)
        }
        return .apply(counts: inserted)
    case .delete:
        // 规则 5：只删识别残留（上面已放过），其他删字一律不过
        return .reject(.deletion)
    default:
        break
    }
    // 换字词：规则 3
    let near = pinyinCheck(segment, in: diff, bounds: bounds, sentence: sentence, context: context)
    // 读音不近的替换一律不收（本机只换读音相近的字词；在线也按 spec「改成读音不近的词」应挡）
    return near ? .apply(counts: 0) : .reject(.pinyin)
}

/// 规则 3：读音是否相近。改后命中参考词时按整个参考词与对应原文比，门槛 0.5；否则按改动处在 `bounds` 里扩到
/// `CorrectionThreshold.pinyinUnit` 个字比，门槛 0.34
private func pinyinCheck(_ segment: TextDiff.Segment, in diff: TextDiff, bounds: Range<Int>,
                         sentence: TranscriptSentence, context: CorrectionContext) -> Bool {
    if let reference = context.references.match(in: diff.after, covering: segment.afterRange, sentence: sentence.id) {
        let unit = diff.span(coveringAfter: reference)
        if Pinyin.distanceRatio(unit.before, unit.after) <= CorrectionThreshold.pinyinReference { return true }
    }
    let widened = diff.widened(segment, minimum: CorrectionThreshold.pinyinUnit, within: bounds)
    return Pinyin.distanceRatio(widened.before, widened.after) <= CorrectionThreshold.pinyin
}

/// 一处改动两边的否定词、人称代词（按出现先后）是否不同：增、删、换都算。
/// 「们」并到前面的代词上，「我→我们」「他们→我们」都算换了人，即使改动处只是「们」或「他→我」
private func changesNegationOrPronoun(_ segment: TextDiff.Segment, in diff: TextDiff) -> Bool {
    func words(_ text: String, _ range: Range<Int>) -> [String] {
        let chars = Array(text)
        var found: [String] = []
        for i in range {
            let c = chars[i]
            if negationCharacters.contains(c) {
                found.append(String(c))
            } else if personalPronounCharacters.contains(c) {
                found.append(i + 1 < chars.count && chars[i + 1] == "们" ? "\(c)们" : String(c))
            } else if c == "们", i == range.lowerBound, i > 0, personalPronounCharacters.contains(chars[i - 1]) {
                // 前面的代词不在改动处里（在里面的话上面已经带上「们」了）
                found.append("\(chars[i - 1])们")
            }
        }
        return found
    }
    return words(diff.before, segment.beforeRange) != words(diff.after, segment.afterRange)
}

/// 改动的两边去掉空白后相同
private func isWhitespaceOnly(_ segment: TextDiff.Segment) -> Bool {
    segment.before.filter { !$0.isWhitespace } == segment.after.filter { !$0.isWhitespace }
}

/// 规则 6：`changed` 个字是否超过这句允许的改动量。原句字数不算标点、空白
func exceedsChangeRatio(changed: Int, sentence: String) -> Bool {
    let length = characterCount(sentence)
    let limit = length < CorrectionThreshold.shortSentence
        ? CorrectionThreshold.shortSentenceChanges
        : Int((Double(length) * CorrectionThreshold.changeRatio).rounded(.down))
    return changed > limit
}

/// 字数：不算标点、空白
func characterCount(_ text: String) -> Int {
    text.count { !TextDiff.isPunctuation(String($0)) }
}

/// 否定词的字
let negationCharacters: Set<Character> = ["不", "没", "别", "未", "无", "非"]

/// 人称代词的字（「我们」「他们」随前一个字算）。参考词不收含这些字的词（`ReferenceWords.wholeWords(in:)`）
let personalPronounCharacters: Set<Character> = ["我", "你", "您", "他", "她", "它", "咱"]

/// 规则 7：含阿拉伯数字或汉字数字字符
func containsNumber(_ text: String) -> Bool {
    text.contains { $0.isASCII && $0.isNumber || "〇零一二三四五六七八九十百千万亿两".contains($0) }
}

/// 数字建议的单元向两边并上的字：数字，以及跟在数字后面的单位
private func isNumberPart(_ token: String) -> Bool {
    containsNumber(token) || (token.count == 1 && "年月日号点时分秒周天个元块角毛万亿倍度岁%％".contains(token))
}

/// 把几条（按 offset 排好、不重叠的）修改应用到句子上；某条的 before 与句子对不上时为 nil
private func apply(_ changes: [CorrectionChange], to text: String) -> String? {
    var chars = Array(text)
    for change in changes.reversed() {
        let range = change.offset..<change.offset + change.before.count
        guard range.lowerBound >= 0, range.upperBound <= chars.count,
              String(chars[range]) == change.before else { return nil }
        chars.replaceSubrange(range, with: Array(change.after))
    }
    return String(chars)
}
