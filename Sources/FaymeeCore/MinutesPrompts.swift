import Foundation

/// 给模型的会议信息：标题、开始日期和星期，用于换算截止时间
struct MeetingInfo {
    var title: String
    var startedAt: Date
    var timeZone: TimeZone

    /// 如 "2026-11-10（星期二）10:00"
    var startDescription: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: startedAt)
        let weekday = Self.weekdayNames[c.weekday! - 1]
        return String(format: "%04d-%02d-%02d（星期%@）%02d:%02d", c.year!, c.month!, c.day!, weekday, c.hour!, c.minute!)
    }

    var header: String { "会议标题：\(title)\n开始时间：\(startDescription)\n\n\(dateTable)" }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// 相对日期的说法与会议之后的日期：今天、明天、后天，本周剩下的几天，下周一到下周日，本月底
    private var relativeDays: [(phrase: String, date: Date)] {
        let calendar = calendar
        let today = calendar.startOfDay(for: startedAt)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        func weekday(_ date: Date) -> String { Self.weekdayNames[calendar.component(.weekday, from: date) - 1] }
        // 一周从星期一开始
        let daysLeftThisWeek = 6 - (calendar.component(.weekday, from: today) + 5) % 7

        var rows = [("今天", today), ("明天", day(1)), ("后天", day(2))]
        rows += stride(from: 1, through: daysLeftThisWeek, by: 1).map { ("本周" + weekday(day($0)), day($0)) }
        rows += (1...7).map { n in day(daysLeftThisWeek + n) }.map { ("下周" + weekday($0), $0) }
        let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1),
                                     to: calendar.dateInterval(of: .month, for: today)!.start)!
        rows.append(("本月底", monthEnd))
        return rows
    }

    /// 给模型查的日期对照表。小模型自己按星期推算常出错（实测总把 dueDate 填成会议当天）
    var dateTable: String {
        let calendar = calendar
        func describe(_ date: Date) -> String {
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            return String(format: "%04d-%02d-%02d（星期%@）", c.year!, c.month!, c.day!, Self.weekdayNames[c.weekday! - 1])
        }
        return "日期对照（以会议日期为准）：\n" + relativeDays.map { "- \($0)：\(describe($1))" }.joined(separator: "\n")
    }

    /// 按会议日期换算截止时间的常见说法（“周五之前”“下星期三”“今天下午”“这周内”“月底前”等），
    /// 规则与给模型的对照表相同：只说“周五”指今天以后最近的周五，“本周内”按本周五。
    /// 不认识的说法返回 nil。模型查表也会抄错行（实测把“周五”“后天”填晚一天），能换算的以这里为准
    func dueDate(for due: String) -> CalendarDate? {
        var phrase = due.filter { !$0.isWhitespace }
        for (from, to) in [("星期", "周"), ("礼拜", "周"), ("下个周", "下周"), ("这个", "本"), ("这周", "本周"),
                           ("周天", "周日"), ("这月", "本月")] {
            phrase = phrase.replacingOccurrences(of: from, with: to)
        }
        let suffixes = ["之前", "以前", "前", "为止", "下班", "上午", "中午", "下午", "晚上", "早上"]
        while let suffix = suffixes.first(where: { phrase.hasSuffix($0) && phrase.count > $0.count }) {
            phrase.removeLast(suffix.count)
        }
        if phrase == "月底" { phrase = "本月底" }
        if phrase == "本周内" || phrase == "本周" { phrase = "本周五" }

        let days = relativeDays
        var date = days.first { $0.phrase == phrase }?.date
        // 只说“周五”：今天以后最近的那一天
        if date == nil, phrase.count == 2, phrase.hasPrefix("周") {
            date = days.dropFirst().first { $0.phrase.hasSuffix(phrase.suffix(1)) && $0.phrase.count == 3 }?.date
        }
        guard let date else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return CalendarDate(year: c.year!, month: c.month!, day: c.day!)
    }

    static let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]
}

/// 转写稿的一行：句子写成 `[s412 31:20] 文本`（用修改后的文字），合盖空白写成 `[合盖，未录到声音 10:00–13:00]`
func inputLine(_ item: TranscriptItem) -> String {
    switch item {
    case let .sentence(s): "[\(s.id) \(formatDuration(s.start))] \(s.text)"
    case let .gap(g): "[合盖，未录到声音 \(formatDuration(g.start))–\(formatDuration(g.end))]"
    }
}

/// 说明转写稿每行的格式。`speakers` 为 nil 时不带说话人
private func lineFormat(_ speakers: SpeakerLabels?) -> String {
    speakers == nil
        ? "转写稿每行一句，格式为“[句子编号 时间] 内容”，例如“[s12 03:15] 我们下周发布”。"
        : "转写稿每行一句，格式为“[句子编号 时间 说话人] 内容”，例如“[s12 03:15 说话人 2] 我们下周发布”。"
            + "说话人由机器按声音区分，“说话人 N”是还不知道名字的人；没标说话人的句子不知道是谁说的。"
}

/// `speakers` 不为空（转写稿显示说话人）时说明行里的说话人标签，负责人可以填说话人；
/// 还有未命名的说话人时多要一项“说话人身份”。没有说话人时与 v0.3 逐字相同。
/// `starred`（输入里有句子带 `★`）时说明 `★` 是会上标的重点；没有时与 v0.4 逐字相同
func extractionSystemPrompt(_ template: MinutesTemplate, speakers: SpeakerLabels? = nil,
                            starred: Bool = false) -> String {
    let speakers = speakers?.isEmpty == false ? speakers : nil
    let star = starred
        ? "\n标签末尾带“★”的句子（如“[s12 03:15 ★]”）落在用户会上标记的重点或记了笔记的地方，"
            + "与它们相关的决议、待办、未决问题不要漏掉。"
        : ""
    return """
    你是会议纪要助手。根据用户给出的会议转写稿，提取会议纪要。

    \(lineFormat(speakers))\
    转写稿由语音识别生成，可能有错别字和口语重复，请按意思理解。
    “[合盖，未录到声音 …]”表示这段时间没有录到声音，没有任何内容，不要据此推断发生了什么。\(star)

    要求：
    - 只写转写稿里确实说到的内容，不要编造，不要补充常识或猜测。
    - 每个条目都要给出出处：refs 里列出最直接支撑这条内容的 1–3 个句子编号（如 "s12"），只能用转写稿里出现过的编号。
    - 用简体中文书写，语句简洁，一条只说一件事；同一件事只写一次，不要换个说法重复。
    - 某一节没有内容时给空数组。

    \(sectionGuide(template, speakers: speakers))

    \(outputFormat(template, speakers: speakers))
    """
}

/// `partial` 为 true 时说明这只是会议的一段（长会议分段提取）
func extractionPrompt(_ meeting: MeetingInfo, lines: [String], partial: Bool = false) -> String {
    """
    \(meeting.header)

    转写稿\(partial ? "（会议较长，以下只是其中一段）" : "")：
    \(lines.joined(separator: "\n"))
    """
}

func mergeSystemPrompt(_ template: MinutesTemplate) -> String {
    """
    你是会议纪要助手。一场较长的会议被分成几段分别提取了纪要条目，现在请把这些条目合并成整场会议的纪要。

    要求：
    - 去掉重复的条目，把说同一件事的条目合并成一条，合并后的 refs 从这些条目的 refs 里选最直接的 1–3 个，最多 3 个。
    - 根据全部条目重新写整场会议的概要，3–6 条，refs 从所依据条目的 refs 里选最直接的 1–3 个，最多 3 个。
    - refs 只能使用输入里出现过的句子编号，不要新增或改写编号。
    - 不要添加输入里没有的内容。前后矛盾时以后面的为准。
    - 用简体中文书写，语句简洁，一条只说一件事。
    - 某一节没有内容时给空数组。

    \(sectionGuide(template))

    \(outputFormat(template))
    """
}

/// 合并的输入只有各段的条目和出处，没有原文。`sections` 给了就只写这几节
func mergePrompt(_ meeting: MeetingInfo, draft: Draft, template: MinutesTemplate,
                 sections: [MinutesSectionKind]? = nil) -> String {
    """
    \(meeting.header)

    各段提取的条目：
    \(draftJSON(draft, sections: sections ?? template.sections.map(\.kind)))
    """
}

/// 合并放不下、直接拼接各段条目时，只把各段的概要合并成整场的概要
func overviewMergeSystemPrompt(_ template: MinutesTemplate) -> String {
    """
    你是会议纪要助手。一场较长的会议被分成几段分别写了概要，现在请把这些概要合并成整场会议的概要。

    要求：
    - 3–6 条，每条一句话，各说一个议题，合起来说清会议讨论了什么；不要把整场会写成一条。
    - 说同一个议题的几条合并成一条，refs 从这些条目的 refs 里选最直接的 1–3 个，最多 3 个。
    - refs 只能使用输入里出现过的句子编号，不要新增或改写编号。
    - 不要添加输入里没有的内容。
    - 用简体中文书写，语句简洁。
    \(template.focus.map { "\n这是一场\(template.name)，请侧重：\($0)\n" } ?? "")
    只输出一个 JSON 对象，不要输出其他文字。格式如下：
    {"overview": [{"text": "…", "refs": ["s12"]}, {"text": "…", "refs": ["s15", "s16"]}]}
    """
}

/// 按模板的节顺序写成 JSON，格式与要求模型输出的相同。
/// 字段顺序手写固定（text 在前、refs 在后）：JSONEncoder 不保证键的顺序，提示词要可复现
func draftJSON(_ draft: Draft, sections kinds: [MinutesSectionKind]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    func json(_ value: some Encodable) -> String { String(decoding: try! encoder.encode(value), as: UTF8.self) }
    func item(_ item: DraftItem) -> String {
        let fields: [(String, String?)] = [
            ("text", json(item.text)), ("owner", item.owner.map(json)), ("due", item.due.map(json)),
            ("dueDate", item.dueDate.map(json)), ("refs", json(item.refs)),
        ]
        return "{" + fields.compactMap { k, v in v.map { "\"\(k)\":\($0)" } }.joined(separator: ",") + "}"
    }
    let sections = kinds.map { kind -> String in
        let key = sectionKey(kind)
        return "\"\(key)\": [" + (draft[key] ?? []).map(item).joined(separator: ", ") + "]"
    }
    return "{" + sections.joined(separator: ",\n") + "}"
}

/// 各节记什么，以及模板的侧重。`speakers` 见 `extractionSystemPrompt`，合并时不给
private func sectionGuide(_ template: MinutesTemplate, speakers: SpeakerLabels? = nil) -> String {
    let owner = speakers == nil
        ? "owner 是负责人，只在转写稿里明确提到时填写，否则为 null；"
        : "owner 是负责人，只在转写稿里明确提到、或某位说话人自己答应去做（如“我来跟进”）时填写，"
            + "负责人是转写稿里的某位说话人时照抄他的说话人标签（如“说话人 2”或名字），否则为 null；"
    var guide = """
    纪要分以下几节（括号里是 JSON 的键）：
    - 概要（overview）：3–6 条，每条一句话，各说一个议题，合起来说清会议讨论了什么；不要把整场会写成一条。
    - 决议（decisions）：会上明确定下来的事。
    - 待办（actions）：要做的事。\(owner)\
    due 是截止时间的原话（如“下周三”），照抄转写稿里的说法，不要改写，没提到时为 null；\
    dueDate 是 due 对应的日期，格式 YYYY-MM-DD：到“日期对照”里找 due 的说法，抄那一行的日期\
    （“这周五”同“本周五”；只说“周五”时指今天以后最近的周五；“本周内”按本周五）；\
    对照里没有、也换算不出来时为 null。不要用会议当天的日期代替，除非 due 就是今天。
    - 未决问题（questions）：会上讨论了、但明确说了还没定或以后再议的事。\
    已经定下来的、已经安排了人去做的，不要写进来；不要自己提出“是否需要进一步确认”之类的问题。
    """
    for section in template.customSections {
        guide += "\n- \(section.title)（\(section.key)）：\(section.hint)"
    }
    if let speakers, speakers.wantsNames {
        guide += "\n- 说话人身份（\(speakersKey)）：标为“说话人 N”的人如果被别人叫了名字或称呼"
            + "（如有人问“王总你怎么看”，接着由说话人 2 回答），写出他是谁：speaker 是说话人标签（如“说话人 2”），"
            + "name 照抄转写稿里的称呼（如“王总”），refs 是含这个称呼的句子编号。"
            + "只写有把握的，每个说话人最多一条；已经写了名字的说话人不用写；没有时给空数组。"
    }
    if let focus = template.focus {
        guide += "\n\n这是一场\(template.name)，请侧重：\(focus)"
    }
    return guide
}

/// 要求的 JSON 格式：以节的键为字段，每节是条目数组；要推断说话人身份时最后再加一项
private func outputFormat(_ template: MinutesTemplate, speakers: SpeakerLabels? = nil) -> String {
    var fields = template.sections.map { kind, _ -> String in
        let key = sectionKey(kind)
        if kind == .actions {
            return #""actions": [{"text": "把报价单发给客户", "owner": "张三", "due": "下周三", "dueDate": "2026-11-18", "refs": ["s412"]}]"#
        }
        return #""\#(key)": [{"text": "…", "refs": ["s12"]}, {"text": "…", "refs": ["s15", "s16"]}]"#
    }
    if let speakers, speakers.wantsNames {
        fields.append(#""\#(speakersKey)": [{"speaker": "说话人 2", "name": "…", "refs": ["s30"]}]"#)
    }
    return "只输出一个 JSON 对象，不要输出其他文字。格式如下：\n{" + fields.joined(separator: ", ") + "}"
}

/// 约束输出形状的 GBNF 文法：一个 JSON 对象，`kinds` 的键按顺序各出现一次，每节是条目数组；
/// 待办的条目依次是 text、owner、due、dueDate、refs（后三个可以是 null），其余节是 text、refs；
/// refs 是 0–3 个句子编号。实测模型会在 refs 里一直往下列编号直到输出上限（ticket 04、11），
/// 提示词管不住，所以用文法硬性限制。字段间最多一个空白字符，免得模型一直输出空白。
/// 最后允许再跟至多两个值为空数组的键：模型习惯在末尾多写一个 `"questions": []`、`"notes": []`，
/// 不让写的话它会接着往最后一节里加条目，实测因此陷入重复直到输出上限。解析时多出的键被忽略，
/// 重复的键取第一次出现的值。
///
/// `speakers`（未命名说话人的标签）不为空时，各节之后再跟一项说话人身份：每条依次是 speaker、name、refs，
/// speaker 只能是给出的标签之一，条数不超过标签数（每个说话人最多一条，也免得一直列下去）
func outputGrammar(_ kinds: [MinutesSectionKind], speakers: [String] = []) -> String {
    var fields = kinds.map { kind in
        #""\"\#(sectionKey(kind))\":" ws \#(kind == .actions ? "actions" : "items")"#
    }
    var speakerRules = ""
    if !speakers.isEmpty {
        fields.append(#""\"\#(speakersKey)\":" ws guesses"#)
        // guess ( "," ws guess ( "," ws guess )? )?：最多 speakers.count 条
        let list = speakers.dropFirst().reduce("guess") { inner, _ in #"guess ( "," ws \#(inner) )?"# }
        // 标签写成 GBNF 字面量 "\"说话人 2\""：标签里的 \ 和 " 先按 JSON 转义，再按 GBNF 转义
        func escaped(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let labels = speakers.map { "\"\\\"" + escaped(escaped($0)) + "\\\"\"" }
        speakerRules = #"""

        guesses ::= "[" ws ( \#(list) )? ws "]"
        guess ::= "{" ws "\"speaker\":" ws label "," ws "\"name\":" ws string "," ws "\"refs\":" ws refs ws "}"
        label ::= \#(labels.joined(separator: " | "))
        """#
    }
    return #"""
    root ::= "{" ws \#(fields.joined(separator: #" "," ws "#)) ( "," ws extra ( "," ws extra )? )? ws "}"
    extra ::= string ":" ws "[" ws "]"
    items ::= "[" ws ( item ( "," ws item )* )? ws "]"
    actions ::= "[" ws ( action ( "," ws action )* )? ws "]"
    item ::= "{" ws "\"text\":" ws string "," ws "\"refs\":" ws refs ws "}"
    action ::= "{" ws "\"text\":" ws string "," ws "\"owner\":" ws nullable "," ws "\"due\":" ws nullable "," ws "\"dueDate\":" ws nullable "," ws "\"refs\":" ws refs ws "}"
    refs ::= "[" ws ( ref ( "," ws ref ( "," ws ref )? )? )? ws "]"
    ref ::= "\"" [A-Za-z0-9_-]+ "\""
    nullable ::= string | "null"
    string ::= "\"" ( [^"\\\x00-\x1f] | "\\" ( ["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] ) )* "\""
    ws ::= [ \n]?
    """# + speakerRules
}

/// 展开一个会中标注区间的系统提示：标记详细说明这段讲了什么、结论是什么，笔记结合附近的对话扩写成一句完整的话
func expansionSystemPrompt(_ kind: AnnotationKind, speakers: SpeakerLabels? = nil) -> String {
    let speakers = speakers?.isEmpty == false ? speakers : nil
    let (task, rules) = switch kind {
    case .mark:
        ("用户在会上标记了一段重点，下面给出标记前后这段时间的会议转写稿。请把这段写成一条纪要。",
         "- 详细说明这段讲了什么、结论是什么：提出了什么、讨论了哪些要点、最后怎么定的；没有定下来的写明还没定。"
            + "比普通的纪要条目写得详细，但只写一段话。")
    case .note:
        ("用户在会上随手记了一条笔记，下面给出笔记原话和记笔记前后这段时间的会议转写稿。"
            + "请结合附近的对话，把这条笔记扩写成一句完整的话。",
         "- 保留笔记的原意，用附近的对话补全笔记省略的人、事和结论；笔记里的箭头、缩写按对话的意思理解。"
            + "只写一句话。")
    }
    return """
    你是会议纪要助手。\(task)

    \(lineFormat(speakers))\
    转写稿由语音识别生成，可能有错别字和口语重复，请按意思理解。

    要求：
    \(rules)
    - 只写转写稿里确实说到的内容，不要编造，不要补充常识或猜测。
    - refs 里列出最直接支撑这条内容的 1–3 个句子编号（如 "s12"），只能用转写稿里出现过的编号。
    - 用简体中文书写。

    只输出一个 JSON 对象，不要输出其他文字。格式如下：
    {"text": "…", "refs": ["s12", "s15"]}
    """
}

/// 展开一个区间的提示词：会议标题、笔记原话（只有笔记有）、区间里的句子
func expansionPrompt(title: String, kind: AnnotationKind, note: String?, lines: [String]) -> String {
    let noteLine = note.map { "笔记原话：\($0)\n\n" } ?? ""
    return """
    会议标题：\(title)

    \(noteLine)转写稿（\(kind == .mark ? "标记" : "笔记")前后的一段）：
    \(lines.joined(separator: "\n"))
    """
}

/// 展开的输出文法：一个对象，依次是 text、refs，refs 是 1–3 个句子编号。
/// 规则的写法同 `outputGrammar`
let expansionGrammar = #"""
root ::= "{" ws "\"text\":" ws string "," ws "\"refs\":" ws refs ws "}"
refs ::= "[" ws ref ( "," ws ref ( "," ws ref )? )? ws "]"
ref ::= "\"" [A-Za-z0-9_-]+ "\""
string ::= "\"" ( [^"\\\x00-\x1f] | "\\" ( ["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] ) )* "\""
ws ::= [ \n]?
"""#
