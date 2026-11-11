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
