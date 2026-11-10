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
        let weekday = ["日", "一", "二", "三", "四", "五", "六"][c.weekday! - 1]
        return String(format: "%04d-%02d-%02d（星期%@）%02d:%02d", c.year!, c.month!, c.day!, weekday, c.hour!, c.minute!)
    }

    var header: String { "会议标题：\(title)\n开始时间：\(startDescription)" }
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
    - 每个条目都要给出出处：refs 里列出支撑这条内容的句子编号（如 "s12"），只能用转写稿里出现过的编号，可以有多个。
    - 用简体中文书写，语句简洁，一条只说一件事。
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
    - 概要（overview）：3–6 条，说清会议讨论了什么。
    - 决议（decisions）：会上明确定下来的事。
    - 待办（actions）：要做的事。owner 是负责人，只在转写稿里明确提到时填写，否则为 null；\
    due 是截止时间的原话（如“下周三”），没提到时为 null；\
    dueDate 是按会议开始日期换算出的日期，格式 YYYY-MM-DD，换算不出来时为 null。
    - 未决问题（questions）：讨论了但没有结论、需要后续跟进的事。
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
        return #""\#(key)": [{"text": "…", "refs": ["s12", "s15"]}]"#
    }
    return "只输出一个 JSON 对象，不要输出其他文字。格式如下：\n{" + fields.joined(separator: ", ") + "}"
}
