import AppKit
import FaymeeCore
import Observation
import SwiftUI

/// 会中面板：录音期间的浮动窗口，显示实时字幕（标注以旗子、笔记行插在对应时间处）、“标记重点”按钮和笔记输入框。
///
/// - 始终在最前、出现在所有桌面和全屏 App 上面，不抢焦点：点笔记输入框时才接收键盘，也不激活 Faymee
/// - 可拖动、缩放、关掉，位置和大小记住
/// - 只在面板实际看得见时跑实时字幕：关掉、被完全挡住、熄屏（含合盖）时停，恢复时接着跑（字幕里插分隔行）
@MainActor
final class LivePanelController: NSObject, NSWindowDelegate {
    /// 被挡住、熄屏多久后才停字幕。切桌面、窗口刚弹出时可见状态会闪一下，不为这个重启引擎、插分隔行
    static let pauseAfter: Duration = .seconds(2)

    /// 本场录音的实时字幕，跟着 `AppModel.liveCaptions`，录音开始时设、结束时清掉
    var captions: LiveCaptions? {
        didSet {
            oldValue?.stop()
            // 上一场录音停止前排下的暂停不能落到这一场头上
            pendingPause?.cancel()
            pendingPause = nil
            pumpTimer?.invalidate()
            pumpTimer = nil
            if let captions {
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak captions] _ in
                    MainActor.assumeIsolated { captions?.pump() }
                }
                RunLoop.main.add(timer, forMode: .common)
                pumpTimer = timer
            }
            refreshVisibility()
        }
    }

    /// 设置里的“实时字幕”开关。关闭时面板只显示标注和输入框，不跑引擎
    var captionsEnabled = true {
        didSet { refreshVisibility() }
    }

    var isOpen: Bool { panel?.isVisible == true }

    private let model: AppModel
    private var panel: LivePanelWindow?
    private var pumpTimer: Timer?
    private var screensAsleep = false
    private var pendingPause: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = true
                self?.refreshVisibility()
            }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensAsleep = false
                self?.refreshVisibility()
            }
        }
    }

    /// 打开面板（菜单栏面板的“会中面板”、录音开始时自动打开）。不激活 Faymee，不抢键盘
    func show() {
        let panel = panel ?? makePanel()
        panel.orderFrontRegardless()
        refreshVisibility()
    }

    /// 停止录音时调用：面板里没回车的笔记先记下，再关掉
    func saveDraft() {
        draft.submit()
    }

    /// 停止录音时关掉。不经窗口的关闭按钮
    func close() {
        draft.clear()
        panel?.orderOut(nil)
        refreshVisibility()
    }

    /// 按面板现在看不看得见决定字幕跑不跑。可见性通知之外，录音的每秒定时器也调一次，免得漏掉通知
    func refreshVisibility() {
        guard let captions else { return }
        let wanted = captionsEnabled && !screensAsleep && SystemState.hasVisibleScreen
            && panel.map { $0.isVisible && $0.occlusionState.contains(.visible) } == true
        if wanted {
            pendingPause?.cancel()
            pendingPause = nil
            captions.isWanted = true
        } else if !captionsEnabled || !isOpen {
            // 用户关了面板或开关：立即停
            pendingPause?.cancel()
            pendingPause = nil
            captions.isWanted = false
        } else if captions.isWanted, pendingPause == nil {
            pendingPause = Task { [weak self] in
                try? await Task.sleep(for: Self.pauseAfter)
                guard !Task.isCancelled, let self else { return }
                self.pendingPause = nil
                self.captions?.isWanted = false
            }
        }
    }

    // MARK: - 窗口

    private let draft = LivePanelDraft()

    private func makePanel() -> LivePanelWindow {
        let panel = LivePanelWindow()
        panel.delegate = self
        draft.onSave = { [weak self] text, time in self?.model.addNote(text, at: time) }
        panel.contentView = NSHostingView(rootView: LivePanelView(draft: draft).environment(model))
        // 有记住的位置和大小就用它，否则放在屏幕右上角
        if !panel.setFrameUsingName(LivePanelWindow.autosaveName) {
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 20,
                                             y: visible.maxY - panel.frame.height - 20))
            }
        }
        panel.setFrameAutosaveName(LivePanelWindow.autosaveName)
        self.panel = panel
        return panel
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { refreshVisibility() }

    func windowWillClose(_ notification: Notification) {
        // 收到通知时窗口还算可见，下一轮再按关掉后的状态算
        DispatchQueue.main.async { [weak self] in self?.refreshVisibility() }
    }
}

/// 面板底部输入框里的笔记。时间取开始输入的那一刻，不取回车的时刻
@MainActor @Observable
final class LivePanelDraft {
    var text = "" {
        didSet {
            if text.isEmpty {
                startedAt = nil
            } else if startedAt == nil {
                startedAt = Date()
            }
        }
    }

    @ObservationIgnored var onSave: ((String, Date) -> Void)?
    @ObservationIgnored private var startedAt: Date?

    /// 回车：有内容就记下，清空输入框。空内容什么都不做
    func submit() {
        if let startedAt, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onSave?(text, startedAt)
        }
        clear()
    }

    func clear() { text = "" }
}

/// 浮动、始终在最前、不成为主窗口。nonactivatingPanel + becomesKeyOnlyIfNeeded：
/// 点字幕、按钮都不抢焦点，点笔记输入框时才接收键盘，也不激活 Faymee（前台 App 不变）
private final class LivePanelWindow: NSPanel {
    static let autosaveName = "LivePanel"

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "会中面板"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 260, height: 220)
    }

    override var canBecomeMain: Bool { false }
}

// MARK: - 内容

private struct LivePanelView: View {
    @Bindable var draft: LivePanelDraft
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.liveCaptions?.session
        VStack(spacing: 0) {
            if model.liveCaptionsEnabled, let session {
                LiveCaptionStatusBar(session: session)
            }
            LivePanelTranscript(session: model.liveCaptionsEnabled ? session : nil,
                                annotations: model.current?.annotationList ?? [],
                                recordingStartedAt: model.current?.startedAt ?? Date(),
                                placeholder: placeholder(session))
            Divider()
            VStack(spacing: 8) {
                Button {
                    model.addMark()
                } label: {
                    Label(LiveShortcut.mark.buttonTitle, systemImage: model.showsMarkFlag ? "flag.fill" : "flag")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .help(model.globalShortcutsEnabled ? "在任何 App 里也可以按 \(LiveShortcut.mark.label)" : "")

                TextField("记一笔，回车保存", text: $draft.text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { draft.submit() }
                    .onExitCommand { draft.clear() }
            }
            .padding(10)
        }
        .frame(minWidth: 260, minHeight: 220)
    }

    private func placeholder(_ session: LiveCaptionSession?) -> String {
        guard model.liveCaptionsEnabled else { return "实时字幕已在设置里关闭。在这里可以标记重点、记笔记" }
        if case .running = session?.status { return "说话后几秒内会出现字幕" }
        return ""
    }
}

/// 字幕的状态：准备模型、出错。正常在跑时不显示
private struct LiveCaptionStatusBar: View {
    let session: LiveCaptionSession

    var body: some View {
        switch session.status {
        case .preparing(let progress):
            VStack(alignment: .leading, spacing: 4) {
                Text("正在准备实时字幕")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: progress)
            }
            .padding(10)
            Divider()
        case .failed(let reason):
            HStack(alignment: .firstTextBaseline) {
                Label("实时字幕出错：\(reason)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("重试") { session.retry() }
            }
            .padding(10)
            Divider()
        case .running, .paused:
            EmptyView()
        }
    }
}

/// 字幕和标注，自动滚到最新；往上翻看时停止自动滚动，回到底部再恢复
private struct LivePanelTranscript: View {
    let session: LiveCaptionSession?
    let annotations: [Annotation]
    let recordingStartedAt: Date
    let placeholder: String
    @State private var followsBottom = true

    private struct ScrollState: Equatable {
        var atBottom: Bool
        var contentHeight: CGFloat
    }

    private static let bottomID = "bottom"

    var body: some View {
        let rows = LivePanelRow.rows(lines: session?.lines ?? [], annotations: annotations,
                                     recordingStartedAt: recordingStartedAt)
        let volatile = session?.volatile
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if rows.isEmpty, volatile == nil, !placeholder.isEmpty {
                        Text(placeholder)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                    ForEach(rows) { row in
                        LivePanelRowView(row: row)
                    }
                    if let volatile {
                        CaptionLine(time: volatile.start, text: volatile.text)
                            .foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(10)
                .textSelection(.enabled)
            }
            // 只管刚打开时停在底部；内容变长时不自动挪，免得往上翻看时内容在眼前跑
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: ScrollState.self) { geo in
                ScrollState(atBottom: geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 24,
                            contentHeight: geo.contentSize.height)
            } action: { old, new in
                // 回到底部就恢复跟随；只有内容高度没变（是用户在翻）时离开底部才停止跟随，
                // 新来一句较长的字幕撑高内容、还没滚下去的那一下不算
                if new.atBottom {
                    followsBottom = true
                } else if old.contentHeight == new.contentHeight {
                    followsBottom = false
                }
            }
            .onChange(of: rows.last?.id) { scrollIfFollowing(proxy) }
            .onChange(of: volatile?.text) { scrollIfFollowing(proxy) }
        }
    }

    private func scrollIfFollowing(_ proxy: ScrollViewProxy) {
        guard followsBottom else { return }
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }
}

private struct LivePanelRowView: View {
    let row: LivePanelRow

    var body: some View {
        switch row.content {
        case .caption(let c):
            CaptionLine(time: c.start, text: c.text)
        case .gap(let g):
            Text(g.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        case .mark:
            HStack(spacing: 6) {
                Stamp(time: row.time)
                Label("标记重点", systemImage: "flag.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        case .note(let a):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Stamp(time: row.time)
                Text("笔记：\(a.text ?? "")")
                    .font(.callout)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

private struct CaptionLine: View {
    let time: TimeInterval
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Stamp(time: time)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 录音里的时间（如 12:03），会后在转写稿里找同一处
private struct Stamp: View {
    let time: TimeInterval

    var body: some View {
        Text(formatDuration(time))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
    }
}
