import Foundation

/// “复制纪要”“导出…”用的 Markdown，格式见 spec「复制与导出」

extension Minutes {
    /// 渲染成 Markdown：标题行是会议标题、开始时间和时长，每节一个二级标题，条目后面带出处时间。
    /// 不带“未找到出处”“手动添加”之类的内部标记；已删除的条目不导出；待办用 `- [ ]`
    ///
    /// - Parameters:
    ///   - transcript: 要附上的转写稿全文，nil 时只有纪要。用修改后的文字，每句一段，合盖空白也单独一段
    ///   - timeZone: 标题行的开始时间按这个时区显示，也用来判断截止日期要不要带年份
    public func markdown(meeting: Meeting, transcript: Transcript? = nil, timeZone: TimeZone = .current) -> String {
        var blocks = [heading(meeting: meeting, timeZone: timeZone)]
        for section in sections {
            let lines = section.visibleItems.map { item in
                line(item, isAction: section.kind == .actions, meetingStartedAt: meeting.startedAt,
                     timeZone: timeZone)
            }
            // 空的节（或条目都删了）和界面一样写“无”
            blocks.append((["## \(section.title)"] + (lines.isEmpty ? ["无"] : lines)).joined(separator: "\n"))
        }
        if let transcript {
            // 每句一段（格式同“复制全文”）：只用一个换行的话，粘贴后整篇会并成一段
            blocks.append("## 转写稿")
            let paragraphs = transcript.items.map { item in
                let text = switch item {
                case let .sentence(s): s.text
                case let .gap(g): g.label
                }
                return "[\(formatDuration(item.start))] \(text.singleLine ?? "")"
            }
            blocks += paragraphs.isEmpty ? ["无"] : paragraphs
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private func heading(meeting: Meeting, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: meeting.startedAt)
        let time = String(format: "%04d-%02d-%02d %02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
        var parts = [time]
        if let duration = meeting.duration {
            parts.append(durationText(duration))
        }
        return "# \(meeting.title)（\(parts.joined(separator: "，"))）"
    }

    /// 按分钟四舍五入：“52 分钟”“1 小时”“1 小时 13 分钟”，不到半分钟写“不到 1 分钟”
    private func durationText(_ duration: TimeInterval) -> String {
        let minutes = Int((duration / 60).rounded())
        let h = minutes / 60, m = minutes % 60
        return switch (h, m) {
        case (0, 0): "不到 1 分钟"
        case (0, _): "\(m) 分钟"
        case (_, 0): "\(h) 小时"
        default: "\(h) 小时 \(m) 分钟"
        }
    }

    private func line(_ item: MinutesItem, isAction: Bool, meetingStartedAt: Date, timeZone: TimeZone) -> String {
        var text = item.text.singleLine ?? ""
        if isAction {
            if let owner = item.owner?.singleLine { text = "\(owner)：\(text)" }
            // 换算出日期时只写日期（spec 示例），换算不出来才写会上的原话
            if let dueDate = item.dueDate {
                text += "，截止 \(dueDate.displayText(meetingStartedAt: meetingStartedAt, timeZone: timeZone))"
            } else if let due = item.due?.singleLine {
                // 中文和数字、字母之间留空格，和“截止 11 月 18 日”一致
                let space = due.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
                text += "，截止\(space ? " " : "")\(due)"
            }
        }
        let refs = item.refs.map { formatDuration($0.start) }
        if !refs.isEmpty { text += "（\(refs.joined(separator: "、"))）" }
        return (isAction ? "- [ ] " : "- ") + text
    }
}

extension Meeting {
    /// “导出…”时默认的文件名：会议标题加 `.md`。`/` 是路径分隔符，`:` 在 Finder 里显示成 `/`，
    /// 都换成横线；标题为空（或只有点）时用“会议纪要”
    public var minutesFileName: String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return (name.allSatisfy { $0 == "." } ? "会议纪要" : name) + ".md"
    }
}

private extension String {
    /// 换行换成空格（一个条目、一句话要留在同一行或同一段里），去掉两边空白；空白串当作没有
    var singleLine: String? {
        let s = components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return s.isEmpty ? nil : s
    }
}
