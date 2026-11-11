import Foundation
import Testing
@testable import FaymeeCore

@Suite struct LiveShortcutConflictTests {
    @Test func 都注册上时不说明() {
        #expect(LiveShortcut.conflictNotice(failed: []) == nil)
    }

    @Test func 说明哪个组合键被占用并指向按钮() {
        #expect(LiveShortcut.conflictNotice(failed: [.mark])
            == "⌃⌥M 被其他 App 占用，按了不会生效，可以用上面的“标记重点”按钮")
        #expect(LiveShortcut.conflictNotice(failed: [.note])
            == "⌃⌥N 被其他 App 占用，按了不会生效，可以用上面的“记一笔”按钮")
    }

    @Test func 两个都被占用时合成一句按固定顺序() {
        let expected = "⌃⌥M、⌃⌥N 被其他 App 占用，按了不会生效，可以用上面的“标记重点”“记一笔”按钮"
        #expect(LiveShortcut.conflictNotice(failed: [.note, .mark]) == expected)
        #expect(LiveShortcut.conflictNotice(failed: [.mark, .note, .mark]) == expected)
    }

    /// 菜单栏面板和会中面板的按钮提示同一套规则：快捷键开着且这个组合键注册上了才提
    @Test func 按钮提示只在快捷键开着且没被占用时提组合键() {
        #expect(LiveShortcut.mark.buttonHelp(enabled: true, failed: []) == "在任何 App 里也可以按 ⌃⌥M")
        #expect(LiveShortcut.note.buttonHelp(enabled: true, failed: [.mark]) == "在任何 App 里也可以按 ⌃⌥N")
        #expect(LiveShortcut.mark.buttonHelp(enabled: true, failed: [.mark]) == "")
        #expect(LiveShortcut.mark.buttonHelp(enabled: false, failed: []) == "")
    }
}

/// 组合键按键帽上的字母注册：非 QWERTY 布局（AZERTY、Dvorak）下 M、N 不在 ANSI 的位置上
@Suite struct LiveShortcutKeyCodeTests {
    /// ANSI 布局里 M、N 的键码
    private let ansiM: UInt16 = 46, ansiN: UInt16 = 45

    @Test func QWERTY下就是ANSI的位置() {
        let qwerty: [UInt16: String] = [45: "n", 46: "m", 41: ";"]
        #expect(LiveShortcut.mark.keyCode(preferring: ansiM) { qwerty[$0] } == ansiM)
        #expect(LiveShortcut.note.keyCode(preferring: ansiN) { qwerty[$0] } == ansiN)
    }

    /// AZERTY 的 M 在 QWERTY 分号的位置，ANSI 的 M 位置是逗号；Dvorak 的 M 在 ANSI 的 M 位置，N 在 L 的位置
    @Test func 别的布局下找输出这个字母的键() {
        let azerty: [UInt16: String] = [45: "n", 46: ",", 41: "m"]
        #expect(LiveShortcut.mark.keyCode(preferring: ansiM) { azerty[$0] } == 41)
        let dvorak: [UInt16: String] = [45: "b", 46: "m", 37: "n"]
        #expect(LiveShortcut.note.keyCode(preferring: ansiN) { dvorak[$0] } == 37)
    }

    @Test func 大小写都算() {
        #expect(LiveShortcut.mark.keyCode(preferring: ansiM) { $0 == 7 ? "M" : nil } == 7)
    }

    /// 读不出布局、或布局里没有这个字母（如纯俄文布局）时为 nil，由调用方退回 ANSI 键码
    @Test func 找不到时为nil() {
        #expect(LiveShortcut.mark.keyCode(preferring: ansiM) { _ in nil } == nil)
        #expect(LiveShortcut.mark.keyCode(preferring: ansiM) { _ in "ь" } == nil)
    }
}

@Suite struct MenuBarIndicatorTests {
    @Test func 不在录音时是常态图标() {
        #expect(MenuBarIndicator(isRecording: false, hasWarning: false, showsMarkFlag: false) == .idle)
        // 停止录音的瞬间旗子还没收起，也不再显示
        #expect(MenuBarIndicator(isRecording: false, hasWarning: true, showsMarkFlag: true) == .idle)
    }

    @Test func 录音中有告警时显示告警() {
        #expect(MenuBarIndicator(isRecording: true, hasWarning: false, showsMarkFlag: false) == .recording)
        #expect(MenuBarIndicator(isRecording: true, hasWarning: true, showsMarkFlag: false) == .warning)
    }

    @Test func 刚标记时旗子盖过告警() {
        #expect(MenuBarIndicator(isRecording: true, hasWarning: false, showsMarkFlag: true) == .markFlag)
        #expect(MenuBarIndicator(isRecording: true, hasWarning: true, showsMarkFlag: true) == .markFlag)
    }
}
