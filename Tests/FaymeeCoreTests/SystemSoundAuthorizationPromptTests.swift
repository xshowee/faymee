import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-17T13:00:00Z", strategy: .iso8601)

/// 相对 t0 的墙钟时间
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

@Suite struct SystemSoundAuthorizationPromptTests {
    /// 弹框用的采集建好后，子进程查到仍是未决定：用户还没点，保留着，过一会儿再查
    @Test func 仍是未决定时保留并定时再查() {
        var p = SystemSoundAuthorizationPrompt()
        p.begin()
        p.held(at: at(0))
        #expect(p.checked(.undetermined, at: at(0.2)) == .recheck(after: SystemSoundAuthorizationPrompt.recheckInterval))
        #expect(p.isPending)
    }

    /// 用户点了按钮（子进程查到已授权或拒绝）：拆掉弹框用的采集，按回答更新提示
    @Test(arguments: [SystemSoundAuthorization.authorized, .denied])
    func 查到回答后拆掉(answer: SystemSoundAuthorization) {
        var p = SystemSoundAuthorizationPrompt()
        p.begin()
        p.held(at: at(0))
        #expect(p.checked(.undetermined, at: at(1)) == .recheck(after: SystemSoundAuthorizationPrompt.recheckInterval))
        #expect(p.checked(answer, at: at(2)) == .release(answer))
        #expect(!p.isPending)
    }

    /// 一直没回答（或子进程一直查不到）：从建好起最多保留 120 秒，到时拆掉，按未决定处理（不提示没有授权）。
    /// 建立本身可能卡在授权框上很久，那段不算
    @Test func 一直未决定时建好120秒后拆掉() {
        var p = SystemSoundAuthorizationPrompt()
        p.begin()
        p.held(at: at(30))
        #expect(p.checked(.undetermined, at: at(30 + 119)) == .recheck(after: SystemSoundAuthorizationPrompt.recheckInterval))
        #expect(p.checked(.undetermined, at: at(30 + 120)) == .release(.undetermined))
        #expect(!p.isPending)
    }

    /// 开始录音（或录音中重试、重建）时授权框还在等：采集尝试等它有结果，不另建一次去弹第二个授权框。
    /// 还在建（可能卡在授权框上）时也一样
    @Test func 授权框还在等时采集尝试等它_不另建() {
        var p = SystemSoundAuthorizationPrompt()
        #expect(!p.capturesWait)
        p.begin()
        #expect(p.capturesWait)
        p.held(at: at(0))
        #expect(p.capturesWait)
        _ = p.checked(.authorized, at: at(3))
        #expect(!p.capturesWait)
    }

    /// 关掉开关：不再等，之后的采集尝试照常自己查授权
    @Test func 关掉开关后不再等() {
        var p = SystemSoundAuthorizationPrompt()
        p.begin()
        p.held(at: at(0))
        p.cancel()
        #expect(!p.isPending)
        #expect(!p.capturesWait)
    }

    /// 弹框用的采集建不起来：没有在等的授权框，采集尝试照常自己查、自己建
    @Test func 建不起来时不再等() {
        var p = SystemSoundAuthorizationPrompt()
        p.begin()
        p.holdFailed()
        #expect(!p.isPending)
        #expect(!p.capturesWait)
    }
}
