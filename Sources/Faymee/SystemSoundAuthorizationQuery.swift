import Darwin
import FaymeeCore
import Foundation

/// 查“系统录音”授权，每次开始采集系统声音之前调用。
///
/// 用的是 TCC 的私有接口 `TCCAccessPreflight("kTCCServiceAudioCapture")`（Faymee 用 Developer ID 分发，
/// 不上架 App Store）：0 = 已授权，1 = 拒绝，2 = 未决定。运行时 dlopen / dlsym 取，取不到或返回别的值
/// 都按未决定处理（照常建，不判为不可用）。判断逻辑只看返回的 `SystemSoundAuthorization`，换查询方式只改这里
enum SystemSoundAuthorizationQuery {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32

    private static let preflight: Preflight? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Preflight.self)
    }()

    static func current() -> SystemSoundAuthorization {
        switch preflight?("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: .authorized
        case 1: .denied
        default: .undetermined
        }
    }
}
