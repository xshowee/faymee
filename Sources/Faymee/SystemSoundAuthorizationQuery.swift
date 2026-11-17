import Darwin
import FaymeeCore
import Foundation
import os

private let log = Logger(subsystem: "com.faymee.app", category: "system-sound")

/// 查“系统录音”授权，每次开始采集系统声音之前、未决定时建好之后调用。
///
/// 用的是 TCC 的私有接口 `TCCAccessPreflight("kTCCServiceAudioCapture")`（Faymee 用 Developer ID 分发，
/// 不上架 App Store）。它的结果在调用它的进程里缓存：进程第一次查到什么，之后一直返回什么，在系统设置里改授权、
/// 在授权框里点按钮，本进程都查不到。所以在子进程里查：用 Faymee 自己的可执行文件带
/// `SystemSoundAuthorization.queryArgument` 起一个短命子进程，子进程只查授权、把结果写到 stdout 就退出
/// （见 `FaymeeMain`），每次查到的都是当前状态。子进程起不来、超时、输出看不懂，都按未决定处理
/// （照常建，不判为不可用）。判断逻辑只看返回的 `SystemSoundAuthorization`
enum SystemSoundAuthorizationQuery {
    /// 子进程多久没退出就杀掉、按未决定处理。要比定时重查的间隔短
    private static let timeout: TimeInterval = 5

    /// 在子进程里查此刻的授权。起进程、等它退出都在后台线程，不占主线程
    static func current() async -> SystemSoundAuthorization {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: queryInChildProcess())
            }
        }
    }

    private static func queryInChildProcess() -> SystemSoundAuthorization {
        guard let executable = Bundle.main.executableURL else { return .undetermined }
        let process = Process()
        process.executableURL = executable
        process.arguments = [SystemSoundAuthorization.queryArgument]
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            log.error("查系统录音授权的子进程起不来：\(error.localizedDescription, privacy: .public)")
            return .undetermined
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            kill(process.processIdentifier, SIGKILL)
            log.error("查系统录音授权的子进程超时")
            return .undetermined
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let authorization = SystemSoundAuthorization(childOutput: String(data: data, encoding: .utf8),
                                                     exitStatus: process.terminationStatus)
        log.info("系统录音授权：\(authorization.childOutput, privacy: .public)")
        return authorization
    }

    // MARK: - 子进程

    /// 子进程模式：只查授权、把结果写到 stdout 就退出。由 `FaymeeMain` 在任何界面和初始化之前调用
    static func runChildQuery() -> Never {
        let line = SystemSoundAuthorization(preflightResult: preflight()).childOutput + "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        exit(0)
    }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32

    /// 运行时 dlopen / dlsym 取私有接口，取不到返回 nil
    private static func preflight() -> Int32? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        let function = unsafeBitCast(symbol, to: Preflight.self)
        return function("kTCCServiceAudioCapture" as CFString, nil)
    }
}
