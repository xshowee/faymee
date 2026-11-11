import Foundation

/// “复制纪要”“导出…”用的 Markdown，格式见 spec「复制与导出」

extension Minutes {
    /// 渲染成 Markdown：标题行是会议标题、开始时间和时长，每节一个二级标题，条目后面带出处时间。
    /// 不带“未找到出处”“手动添加”之类的内部标记；已删除的条目不导出；待办用 `- [ ]`
    ///
    /// - Parameters:
    ///   - transcript: 会议当前的转写稿，用来显示待办负责人（`displayedOwner`：关联的说话人改名后用新名字）。
    ///     不附全文（复制纪要）时也要传；nil 时负责人用生成时的文字
    ///   - attachingTranscript: 末尾附上转写稿全文（`transcript` 为 nil 时不附）。用修改后的文字，
    ///     每句一段，合盖空白也单独一段；行格式同“复制全文”，显示说话人时带上说话人
    ///   - timeZone: 标题行的开始时间按这个时区显示，也用来判断截止日期要不要带年份
    public func markdown(meeting: Meeting, transcript: Transcript? = nil, attachingTranscript: Bool = false,
                         timeZone: TimeZone = .current) -> String {
        var blocks = [heading(meeting: meeting, timeZone: timeZone)]
        for section in sections {
            let lines = section.visibleItems.map { item in
                line(item, isAction: section.kind == .actions, owner: displayedOwner(of: item, transcript: transcript),
                     meetingStartedAt: meeting.startedAt, timeZone: timeZone)
            }
            // 空的节（或条目都删了）和界面一样写“无”
            blocks.append((["## \(section.title)"] + (lines.isEmpty ? ["无"] : lines)).joined(separator: "\n"))
        }
        if attachingTranscript, let transcript {
            // 每句一段（格式同“复制全文”）：只用一个换行的话，粘贴后整篇会并成一段
            blocks.append("## 转写稿")
            let paragraphs = transcript.copyLines { $0.singleLine ?? "" }
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

    private func line(_ item: MinutesItem, isAction: Bool, owner: String?, meetingStartedAt: Date,
                      timeZone: TimeZone) -> String {
        var text = item.text.singleLine ?? ""
        if isAction {
            if let owner = owner?.singleLine { text = "\(owner)：\(text)" }
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
