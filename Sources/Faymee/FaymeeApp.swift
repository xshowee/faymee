import SwiftUI

/// 混合形态：平时只在菜单栏（LSUIElement），打开“会议记录”窗口时临时变成普通程序，
/// 有 Dock 图标、能 ⌘Tab 切换、有顶部菜单；窗口关掉后退回菜单栏
@main
struct FaymeeApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        let model = appDelegate.model

        MenuBarExtra {
            MenuContent()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("会议记录", id: "meetings") {
            MeetingsView()
                .environment(model)
                .onAppear(perform: AppDelegate.windowAppeared)
        }
        .defaultSize(width: 760, height: 480)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {
                RecordingCommand(model: model)
            }
        }

        Window("热词表", id: "hotwords") {
            HotwordsView()
                .environment(model)
                .onAppear(perform: AppDelegate.windowAppeared)
        }
        .defaultSize(width: 380, height: 440)
        .defaultLaunchBehavior(.suppressed)
    }
}

private struct RecordingCommand: View {
    var model: AppModel

    var body: some View {
        Button(model.isRecording ? "停止录音" : "开始录音") {
            if model.isRecording {
                model.stop()
            } else {
                Task { await model.start() }
            }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    /// 窗口出现时切成普通程序。窗口关掉时由 applicationDidFinishLaunching 里登记的通知
    /// 按实际还开着的窗口决定是否退回菜单栏，不自己计数
    static func windowAppeared() {
        NSApp.setActivationPolicy(.regular)
        // 刚切成 .regular 时顶部菜单栏不一定立刻换成本 App 的，下一轮再激活一次
        DispatchQueue.main.async { NSApp.activate() }
    }

    /// 还有可见或最小化的普通窗口（会议记录、热词表）就保留 Dock 图标，否则退回菜单栏。
    /// 菜单栏面板是 NSPanel，不算；最小化的窗口要算，否则退回菜单栏后就点不回来了
    private static func updateDockVisibility(closing: NSWindow) {
        let hasWindow = NSApp.windows.contains {
            $0 !== closing && !($0 is NSPanel) && $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized)
        }
        if !hasWindow { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 收到通知时关闭中的窗口还算可见，所以把它排除在外
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                               queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { Self.updateDockVisibility(closing: window) }
        }
    }

    /// 有了 Dock 图标就能 ⌘Q 退出，退出前先收尾录音；没整理完的会在下次启动时自动续上
    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        model.saveHotwords()
    }
}
