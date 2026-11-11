import Carbon
import FaymeeCore

/// 录音期间的全局快捷键（⌃⌥M 标记重点、⌃⌥N 记一笔）。用 Carbon 的 RegisterEventHotKey，
/// 不需要辅助功能权限。由 AppModel 在录音开始时注册、停止时注销，不录音时不占用这两个组合键。
///
/// 以独占方式注册（kEventHotKeyExclusive）：注册期间别的 App 非独占注册的同一组合键收不到，
/// 注销后自动还给它们。只有别的 App 也独占注册了同一组合键时才会注册失败（eventHotKeyExistsErr），
/// 这就是菜单栏面板里说的“被占用”。系统快捷键、用事件监听实现的快捷键查不出来
@MainActor
final class GlobalHotkeys {
    /// 按下快捷键时调用（主线程）
    var onPress: ((LiveShortcut) -> Void)?
    private(set) var isRegistered = false

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// 注册两个快捷键，返回没注册上的。已经注册过时不重复注册，返回空
    func register() -> [LiveShortcut] {
        guard !isRegistered else { return [] }
        installHandler()
        isRegistered = true
        var failed: [LiveShortcut] = []
        for shortcut in LiveShortcut.allCases {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, UInt32(controlKey | optionKey),
                                             EventHotKeyID(signature: Self.signature, id: shortcut.hotKeyID),
                                             GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                failed.append(shortcut)
            }
        }
        return failed
    }

    func unregister() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        isRegistered = false
    }

    /// 事件处理只装一次，App 退出时由系统收回
    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotkeys.signature,
                  let shortcut = LiveShortcut.allCases.first(where: { $0.hotKeyID == id.id })
            else { return OSStatus(eventNotHandledErr) }
            // 热键事件在主线程的事件循环里派发
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotkeys>.fromOpaque(userData).takeUnretainedValue().onPress?(shortcut)
            }
            return noErr
        }, 1, &type, me, &handler)
    }

    /// 'FYME'
    nonisolated private static let signature: OSType = 0x4659_4D45
}

private extension LiveShortcut {
    /// 物理键位（ANSI 布局的 M、N 键）
    var keyCode: UInt32 {
        switch self {
        case .mark: UInt32(kVK_ANSI_M)
        case .note: UInt32(kVK_ANSI_N)
        }
    }

    var hotKeyID: UInt32 {
        switch self {
        case .mark: 1
        case .note: 2
        }
    }
}
