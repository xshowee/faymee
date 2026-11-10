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

func extractionSystemPrompt(_ template: MinutesTemplate) -> String {
    """
    你是会议纪要助手。根据用户给出的会议转写稿，提取会议纪要。

    转写稿每行一句，格式为“[句子编号 时间] 内容”，例如“[s12 03:15] 我们下周发布”。\
    转写稿由语音识别生成，可能有错别字和口语重复，请按意思理解。
    “[合盖，未录到声音 …]”表示这段时间没有录到声音，没有任何内容，不要据此推断发生了什么。

    要求：
    - 只写转写稿里确实说到的内容，不要编造，不要补充常识或猜测。
    - 每个条目都要给出出处：refs 里列出最直接支撑这条内容的 1–3 个句子编号（如 "s12"），只能用转写稿里出现过的编号。
    - 用简体中文书写，语句简洁，一条只说一件事；同一件事只写一次，不要换个说法重复。
    - 某一节没有内容时给空数组。

    \(sectionGuide(template))

    \(outputFormat(template))
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
    - 去掉重复的条目，把说同一件事的条目合并成一条，合并后的 refs 取这些条目 refs 的并集。
    - 根据全部条目重新写整场会议的概要，3–6 条，refs 取所依据条目的 refs。
    - refs 只能使用输入里出现过的句子编号，不要新增或改写编号。
    - 不要添加输入里没有的内容。前后矛盾时以后面的为准。
    - 用简体中文书写，语句简洁，一条只说一件事。
    - 某一节没有内容时给空数组。

    \(sectionGuide(template))

    \(outputFormat(template))
    """
}

/// 合并的输入只有各段的条目和出处，没有原文
func mergePrompt(_ meeting: MeetingInfo, draft: Draft, template: MinutesTemplate) -> String {
    """
    \(meeting.header)

    各段提取的条目：
    \(draftJSON(draft, template: template))
    """
}

/// 按模板的节顺序写成 JSON，格式与要求模型输出的相同。
/// 字段顺序手写固定（text 在前、refs 在后）：JSONEncoder 不保证键的顺序，提示词要可复现
func draftJSON(_ draft: Draft, template: MinutesTemplate) -> String {
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
    let sections = template.sections.map { kind, _ -> String in
        let key = sectionKey(kind)
        return "\"\(key)\": [" + (draft[key] ?? []).map(item).joined(separator: ", ") + "]"
    }
    return "{" + sections.joined(separator: ",\n") + "}"
}

/// 各节记什么，以及模板的侧重
private func sectionGuide(_ template: MinutesTemplate) -> String {
    var guide = """
    纪要分以下几节（括号里是 JSON 的键）：
    - 概要（overview）：3–6 条，每条一句话，各说一个议题，合起来说清会议讨论了什么；不要把整场会写成一条。
    - 决议（decisions）：会上明确定下来的事。
    - 待办（actions）：要做的事。owner 是负责人，只在转写稿里明确提到时填写，否则为 null；\
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
    if let focus = template.focus {
        guide += "\n\n这是一场\(template.name)，请侧重：\(focus)"
    }
    return guide
}

/// 要求的 JSON 格式：以节的键为字段，每节是条目数组
private func outputFormat(_ template: MinutesTemplate) -> String {
    let fields = template.sections.map { kind, _ -> String in
        let key = sectionKey(kind)
        if kind == .actions {
            return #""actions": [{"text": "把报价单发给客户", "owner": "张三", "due": "下周三", "dueDate": "2026-11-18", "refs": ["s412"]}]"#
        }
        return #""\#(key)": [{"text": "…", "refs": ["s12"]}, {"text": "…", "refs": ["s15", "s16"]}]"#
    }
    return "只输出一个 JSON 对象，不要输出其他文字。格式如下：\n{" + fields.joined(separator: ", ") + "}"
}
