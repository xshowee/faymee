import AppKit
import FaymeeCore
import Observation
import SwiftUI

/// 记一笔的输入框：屏幕上方居中的小浮窗。弹出时记下时刻（笔记的时间取这一刻，不取回车的时刻），
/// 激活 Faymee 接收键盘；回车保存，Esc 或空内容回车取消，之后把焦点还给原来的 App。
///
/// 点到别处时不关，免得打了一半的字丢掉；再按一次 ⌃⌥N 回到输入框。录音停止时有内容就保存再关
@MainActor
final class NoteInputController {
    /// 回车保存时调用：文字（未规整）和弹出的时刻。规整、空内容的判断在 `Meeting.addNote`
    var onSave: ((String, Date) -> Void)?

    private var panel: NoteInputPanel?
    private let draft = NoteDraft()
    private var openedAt: Date?
    private var returnFocusTo: NSRunningApplication?
    /// 最近一个在前台的别的 App。从菜单栏面板点“记一笔”时 Faymee 自己在前台，记完把焦点还给它
    private var lastOtherApp: NSRunningApplication?

    var isOpen: Bool { panel != nil }

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let app, app != .current else { return }
                self?.lastOtherApp = app
            }
        }
    }

    /// 弹出输入框；已经开着时只把它调到前面，时刻和已输入的字不变。
    /// stamp 是显示在输入框里的录音时间（如 12:03）
    func show(stamp: String) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        openedAt = Date()
        returnFocusTo = Self.appToReturnTo(lastOther: lastOtherApp)
        draft.text = ""
        draft.stamp = stamp

        let panel = NoteInputPanel()
        panel.onCancel = { [weak self] in self?.close() }
        let view = NoteInputView(draft: draft, onSubmit: { [weak self] in self?.submit() },
                                 onCancel: { [weak self] in self?.close() })
        panel.contentView = NSHostingView(rootView: view)
        panel.setContentSize(panel.contentView!.fittingSize)
        panel.placeTopCenter()
        self.panel = panel
        // 先摆到当前桌面上再激活，免得激活时切到会议记录窗口所在的桌面
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// 录音停止时调用：开着且有内容就保存，然后关掉
    func saveIfOpen() {
        guard isOpen else { return }
        submit()
    }

    private func submit() {
        if let openedAt, !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onSave?(draft.text, openedAt)
        }
        close()
    }

    private func close() {
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        openedAt = nil
        draft.text = ""
        if let app = returnFocusTo, !app.isTerminated {
            NSApp.yieldActivation(to: app)
            app.activate(from: .current)
        }
        returnFocusTo = nil
    }

    /// 弹出前在前台的 App。Faymee 自己在前台时：开着会议记录等窗口就留在 Faymee，
    /// 否则（从菜单栏面板点的）还给之前在用的 App
    private static func appToReturnTo(lastOther: NSRunningApplication?) -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front != .current { return front }
        let hasWindow = NSApp.windows.contains { !($0 is NSPanel) && $0.canBecomeMain && $0.isVisible }
        return hasWindow ? nil : lastOther
    }
}

@MainActor @Observable
private final class NoteDraft {
    var text = ""
    var stamp = ""
}

/// 无边框浮窗：始终在最前，出现在所有桌面和全屏 App 上面。NSPanel 不算普通窗口，不会让 App 出现 Dock 图标
private final class NoteInputPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 56), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { true }

    /// Esc 没被输入框处理（比如焦点不在输入框上）时也取消，不发系统提示音
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// 有键盘焦点的屏幕上方居中，离顶部约五分之一
    func placeTopCenter() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.maxY - visible.height / 5 - frame.height
        setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}

private struct NoteInputView: View {
    @Bindable var draft: NoteDraft
    var onSubmit: () -> Void
    var onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(.secondary)
            TextField("记一笔，回车保存，Esc 取消", text: $draft.text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                // 回车由输入框的提交动作处理：输入法组字时的回车先上屏，不会误提交
                .onSubmit(onSubmit)
                .onExitCommand(perform: onCancel)
            Text(draft.stamp)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("这条笔记记在录音的这个时间")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { focused = true }
    }
}
