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
                .onAppear { AppDelegate.showInDock(true) }
                .onDisappear { AppDelegate.showInDock(false) }
        }
        .defaultSize(width: 760, height: 480)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {
                RecordingCommand(model: model)
            }
        }
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

    static func showInDock(_ visible: Bool) {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        if visible {
            // 刚切成 .regular 时顶部菜单栏不一定立刻换成本 App 的，下一轮再激活一次
            DispatchQueue.main.async { NSApp.activate() }
        }
    }

    /// 有了 Dock 图标就能 ⌘Q 退出，退出前先收尾录音；没整理完的会在下次启动时自动续上
    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}
