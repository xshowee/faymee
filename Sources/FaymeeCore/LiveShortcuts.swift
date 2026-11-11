import Foundation

/// 录音期间的全局快捷键：⌃⌥M 标记重点、⌃⌥N 记一笔。这一阶段固定组合，不能改键，只能在设置里整体关掉。
/// 只在录音期间注册，停止录音即注销（App 层用 Carbon 注册）
public enum LiveShortcut: CaseIterable, Hashable, Sendable {
    case mark
    case note

    /// 组合键的显示，如 `⌃⌥M`
    public var label: String {
        switch self {
        case .mark: "⌃⌥M"
        case .note: "⌃⌥N"
        }
    }

    /// 组合键里的字母（键帽上的），小写
    public var letter: Character {
        switch self {
        case .mark: "m"
        case .note: "n"
        }
    }

    /// 当前键盘布局下输出 `letter` 的键码。translate 给出一个键码不按修饰键时输出的文字（读不出为 nil）。
    /// 先看 preferred（ANSI 布局里这个字母的位置），再从 0 往上找；都不是时为 nil，由调用方退回 ANSI 键码。
    /// 标签写的是 ⌃⌥M、⌃⌥N，在 AZERTY、Dvorak 下也要按键帽上是 M、N 的那个键注册
    public func keyCode(preferring preferred: UInt16, translate: (UInt16) -> String?) -> UInt16? {
        func outputsLetter(_ code: UInt16) -> Bool { translate(code)?.lowercased() == String(letter) }
        if outputsLetter(preferred) { return preferred }
        // 虚拟键码都在 0..<128
        return (0..<128).first(where: outputsLetter)
    }

    /// 菜单栏面板里同一功能的按钮名
    public var buttonTitle: String {
        switch self {
        case .mark: "标记重点"
        case .note: "记一笔"
        }
    }

    /// 菜单栏面板、会中面板里同一功能按钮的提示：全局快捷键开着（enabled）且这个组合键注册上了
    /// （不在 failed 里）才提它，否则为空，免得提一个按了不生效的组合键
    public func buttonHelp(enabled: Bool, failed: [LiveShortcut]) -> String {
        enabled && !failed.contains(self) ? "在任何 App 里也可以按 \(label)" : ""
    }

    /// 菜单栏面板里的说明：哪些组合键没注册上（被其他 App 占用）、改用哪个按钮。都注册上时为 nil。
    /// 顺序固定为标记在前，重复的只说一次
    public static func conflictNotice(failed: [LiveShortcut]) -> String? {
        let failed = allCases.filter(failed.contains)
        guard !failed.isEmpty else { return nil }
        let keys = failed.map(\.label).joined(separator: "、")
        let buttons = failed.map { "“\($0.buttonTitle)”" }.joined()
        return "\(keys) 被其他 App 占用，按了不会生效，可以用上面的\(buttons)按钮"
    }
}

/// 菜单栏图标显示哪一种状态
public enum MenuBarIndicator: Hashable, Sendable {
    /// 不在录音
    case idle
    /// 正常录音中
    case recording
    /// 录音中有告警：长时间没声音、录音出错、合盖断开了内置麦克风
    case warning
    /// 刚标记了重点（约 2 秒），确认标上了。不发声音、不发通知，只靠这个图标
    case markFlag

    /// 旗子盖过告警：它只显示约 2 秒，又是用户刚按下的，要让他看到标上了；之后告警图标照常回来
    public init(isRecording: Bool, hasWarning: Bool, showsMarkFlag: Bool) {
        if !isRecording {
            self = .idle
        } else if showsMarkFlag {
            self = .markFlag
        } else {
            self = hasWarning ? .warning : .recording
        }
    }
}
