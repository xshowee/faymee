import AppKit
import FaymeeCore
import UniformTypeIdentifiers

/// “复制纪要”“导出…”。Markdown 由 `Minutes.markdown` 生成，这里只管剪贴板和保存面板
@MainActor enum MinutesExport {
    /// 以 Markdown 复制到剪贴板，粘贴到飞书、钉钉、Notion 时由它们识别格式。
    /// `transcript` 是当前转写稿，用来显示待办负责人（关联的说话人改名后用新名字），不附全文
    static func copy(_ minutes: Minutes, meeting: Meeting, transcript: Transcript?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(minutes.markdown(meeting: meeting, transcript: transcript), forType: .string)
    }

    /// 弹出保存面板存成 `.md`，面板下方可以勾选“附上转写稿全文”（没有转写稿时不能勾）。
    /// 有窗口时以 sheet 形式挂在当前窗口上
    static func export(_ minutes: Minutes, meeting: Meeting, transcript: Transcript?) {
        let panel = NSSavePanel()
        panel.title = "导出纪要"
        panel.nameFieldStringValue = meeting.minutesFileName
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let includeTranscript = NSButton(checkboxWithTitle: "附上转写稿全文", target: nil, action: nil)
        let hasTranscript = !(transcript?.items.isEmpty ?? true)
        includeTranscript.isEnabled = hasTranscript
        includeTranscript.state = .off
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        includeTranscript.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(includeTranscript)
        NSLayoutConstraint.activate([
            includeTranscript.centerXAnchor.constraint(equalTo: accessory.centerXAnchor),
            includeTranscript.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
        ])
        panel.accessoryView = accessory

        let save = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            let attaching = hasTranscript && includeTranscript.state == .on
            do {
                try minutes.markdown(meeting: meeting, transcript: transcript, attachingTranscript: attaching)
                    .write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = "导出失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            save(panel.runModal())
        }
    }
}
