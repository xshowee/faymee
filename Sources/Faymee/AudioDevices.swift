import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    enum Kind: Int, Comparable {
        // 数值即自动选择时的优先级，越小越优先
        /// USB、雷雳、显示器自带麦克风等有线设备，例如会议全向麦
        case wired = 0
        case builtIn = 1
        /// 通过连续互通使用的 iPhone 麦克风
        case continuity = 2
        /// 蓝牙耳机作为麦克风时会降为通话音质，且只收佩戴者的声音
        case bluetooth = 3
        /// 虚拟声卡、聚合设备（会议软件、录屏工具装的），不是真实麦克风
        case virtual = 4

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .wired: "外接"
            case .builtIn: "内置"
            case .continuity: "iPhone"
            case .bluetooth: "蓝牙"
            case .virtual: "虚拟"
            }
        }
    }

    let id: AudioDeviceID
    /// CoreAudio 设备 UID，重新插拔后保持不变，用来记住用户的选择
    let uid: String
    let name: String
    let transport: UInt32
    let kind: Kind
}

enum AudioDevices {
    /// 所有带输入通道的设备
    static func inputs() -> [AudioInputDevice] {
        deviceIDs().compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName)
            else { return nil }
            let transport = uint32(id, kAudioDevicePropertyTransportType) ?? kAudioDeviceTransportTypeUnknown
            return AudioInputDevice(id: id, uid: uid, name: name, transport: transport,
                                    kind: kind(transport: transport, uid: uid))
        }
    }

    static func defaultInput() -> AudioInputDevice? {
        guard let id = uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        else { return nil }
        return inputs().first { $0.id == id }
    }

    /// 设备插拔、系统默认输入变化时在主线程回调。在 App 生命周期内一直有效
    static func observeChanges(_ handler: @escaping @MainActor () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                MainActor.assumeIsolated { handler() }
            }
        }
    }

    // MARK: - 分类

    private static func kind(transport: UInt32, uid: String) -> AudioInputDevice.Kind {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return .continuity
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate, kAudioDeviceTransportTypeUnknown:
            // 未知类型多半是第三方虚拟声卡，不参与自动选择，但仍可手动选
            return .virtual
        default:
            return .wired
        }
    }

    // MARK: - CoreAudio 属性读取

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// 用户选择的麦克风
enum InputSelection: Hashable {
    /// 优先外接有线麦克风，其次内置（合盖时跳过），再次 iPhone。蓝牙和虚拟设备不参与自动选择
    case automatic
    /// 跟随“系统设置 › 声音 › 输入”
    case systemDefault
    /// 指定设备；未连接时按自动规则临时替代，连上后自动切回
    case device(uid: String)

    init(storage: String?) {
        switch storage {
        case nil, "auto": self = .automatic
        case "system": self = .systemDefault
        case let uid?: self = .device(uid: uid)
        }
    }

    var storage: String {
        switch self {
        case .automatic: "auto"
        case .systemDefault: "system"
        case let .device(uid): uid
        }
    }

    /// 返回 nil 表示跟随系统默认输入
    func resolve(in devices: [AudioInputDevice], lidClosed: Bool) -> AudioInputDevice? {
        switch self {
        case .systemDefault:
            return nil
        case let .device(uid):
            return devices.first { $0.uid == uid } ?? InputSelection.automatic.resolve(in: devices, lidClosed: lidClosed)
        case .automatic:
            let candidates = devices.filter {
                $0.kind == .wired || $0.kind == .continuity || ($0.kind == .builtIn && !lidClosed)
            }
            // 合盖又没有其他麦克风时仍用内置：录不到声音，但会被记成一段合盖空白
            return candidates.min { $0.kind < $1.kind } ?? devices.first { $0.kind == .builtIn }
        }
    }
}
