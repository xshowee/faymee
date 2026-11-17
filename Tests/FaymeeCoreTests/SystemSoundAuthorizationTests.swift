import Testing
@testable import FaymeeCore

/// 授权在 Faymee 自己起的子进程里查（本进程的查询结果会缓存）：子进程把 TCC 的返回值写成一行输出，
/// 主进程解析。只有明确的结果才算数，其余一律当未决定（照常建，不判为不可用）
@Suite struct SystemSoundAuthorizationTests {
    @Test func 子进程按TCC返回值输出_主进程解析回同一个结果() {
        // TCCAccessPreflight：0 = 已授权，1 = 拒绝，2 = 未决定
        let cases: [(Int32, SystemSoundAuthorization)] = [(0, .authorized), (1, .denied), (2, .undetermined)]
        for (preflight, expected) in cases {
            let output = SystemSoundAuthorization(preflightResult: preflight).childOutput
            #expect(SystemSoundAuthorization(childOutput: output + "\n", exitStatus: 0) == expected)
        }
    }

    @Test func 子进程取不到接口或返回别的值时输出未决定() {
        #expect(SystemSoundAuthorization(preflightResult: nil) == .undetermined)
        #expect(SystemSoundAuthorization(preflightResult: 7) == .undetermined)
    }

    @Test func 子进程失败_超时_输出看不懂都当未决定() {
        let denied = SystemSoundAuthorization.denied.childOutput
        // 没跑起来、超时被杀：没有输出
        #expect(SystemSoundAuthorization(childOutput: nil, exitStatus: nil) == .undetermined)
        // 输出了但退出码不是 0
        #expect(SystemSoundAuthorization(childOutput: denied, exitStatus: 1) == .undetermined)
        #expect(SystemSoundAuthorization(childOutput: "", exitStatus: 0) == .undetermined)
        #expect(SystemSoundAuthorization(childOutput: "denied?", exitStatus: 0) == .undetermined)
        // 子进程没有按查询模式退出、启动成了整个 App 之类：多出别的输出也不认
        #expect(SystemSoundAuthorization(childOutput: "starting\n" + denied, exitStatus: 0) == .undetermined)
    }
}
