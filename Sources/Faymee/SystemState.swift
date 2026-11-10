import AppKit
import IOKit
import IOKit.ps

/// 读取跟录音、后台任务有关的系统状态：合盖、屏幕、休眠设置、电源
enum SystemState {
    /// 是否合盖。没有盖子的 Mac（台式机）返回 nil
    static var isLidClosed: Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Bool
    }

    /// 有没有亮着的屏幕可以看到提示（合盖时只有接了外接显示器才有）
    static var hasVisibleScreen: Bool { !NSScreen.screens.isEmpty }

    /// 是否接着外部电源。只有用电池时为 false；没有电池的 Mac（台式机）、UPS 都算接着电源
    static var isOnPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) != kIOPMBatteryPowerKey
    }

    /// 电源信息变化时调用（主线程），包括接上和拔掉电源，也包括电量变化，调用方自己比较 isOnPower 是否变了。
    /// 不用 IOPSCreateLimitedPowerNotification：它只在接电切到电池时通知，接上电源时不通知。只注册一次
    @MainActor static func observePowerChanges(_ handler: @escaping @MainActor () -> Void) {
        powerHandler = handler
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { SystemState.powerHandler?() }
        }, nil)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    @MainActor private static var powerHandler: (@MainActor () -> Void)?

    /// 系统级休眠是否被关闭（Caffy 开启时为 true）
    static func sleepDisabled() async -> Bool {
        let output = await run("/usr/bin/pmset", ["-g"])
        return output.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count == 2 && fields[0] == "SleepDisabled" && fields[1] == "1"
        }
    }

    /// 只关屏幕，不让系统休眠。盖子开着时内置麦克风照常收音
    static func sleepDisplay() {
        Task { _ = await run("/usr/bin/pmset", ["displaysleepnow"]) }
    }

    private static func run(_ path: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: "")
            }
        }
    }
}
