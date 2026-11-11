import AVFoundation
import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-11T02:00:00Z", strategy: .iso8601)
private let mic = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

private func chunk() -> AVAudioPCMBuffer {
    let b = AVAudioPCMBuffer(pcmFormat: mic, frameCapacity: 4800)!
    b.frameLength = 4800
    return b
}

@MainActor
private final class Fixture {
    let engine = FakeStreamingTranscriber()
    let captions: LiveCaptions
    private let clock = Clock()

    final class Clock: @unchecked Sendable {
        var now = t0
    }

    init(hotwords: [String] = []) {
        let clock = clock
        captions = LiveCaptions(engine: engine, recordingStartedAt: t0, hotwords: hotwords, now: { clock.now })
    }

    func advance(to seconds: TimeInterval) { clock.now = t0.addingTimeInterval(seconds) }

    /// 采集线程送来几块音频，然后主线程取走
    func capture(count: Int = 1) {
        for _ in 0..<count { captions.tap.push(chunk(), at: self.clock.now) }
        captions.pump()
    }

    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}

@MainActor @Suite struct LiveCaptionsTests {
    /// 投屏时默认不开面板，没人看就不该去准备（首次可能要下载）模型
    @Test func 面板没显示过就不准备模型_也不复制音频() async throws {
        let f = Fixture()
        f.capture()
        try await Task.sleep(for: .milliseconds(50))

        #expect(f.captions.session == nil)
        #expect(f.engine.prepareCalls == 0)
        #expect(!f.captions.tap.isEnabled)
    }

    @Test func 面板显示后准备模型_准备好后分路的音频送进引擎() async throws {
        let f = Fixture(hotwords: ["老王"])
        f.captions.isWanted = true
        let session = try #require(f.captions.session)
        try await f.until { session.status == .running }
        #expect(f.engine.prepareCalls == 1)

        f.captions.pump()
        #expect(f.captions.tap.isEnabled)
        f.capture(count: 3)

        #expect(f.engine.sessions.count == 1)
        #expect(f.engine.last.appended == 3)
        #expect(f.engine.last.hotwords == ["老王"])
        // 第一次显示不算“恢复”，没有分隔行
        #expect(session.lines.isEmpty)
    }

    @Test func 面板被挡住或关掉时暂停并停止复制_再显示时插分隔行() async throws {
        let f = Fixture()
        f.captions.isWanted = true
        let session = try #require(f.captions.session)
        try await f.until { session.status == .running }
        f.capture()
        f.capture()
        let before = f.engine.last

        f.advance(to: 60)
        f.captions.isWanted = false
        #expect(before.cancelled)
        #expect(session.status == .paused)
        #expect(!f.captions.tap.isEnabled)
        f.capture(count: 2)
        #expect(f.engine.sessions.count == 1)

        f.advance(to: 60 + 3 * 60)
        f.captions.isWanted = true
        #expect(f.captions.session === session)
        f.capture()
        f.capture()

        #expect(f.engine.sessions.count == 2)
        #expect(f.engine.last.appended == 1)
        guard case .gap(let gap) = session.lines.last else {
            Issue.record("没有分隔行：\(session.lines)")
            return
        }
        #expect(gap.text == "中间约 3 分钟没有字幕")
    }

    /// 准备模型期间会话本来就丢掉音频，分路也不必复制
    @Test func 准备模型期间不复制音频() async throws {
        let f = Fixture()
        f.engine.blocksPrepare = true
        f.captions.isWanted = true
        try await f.until { f.engine.prepareGate != nil }

        f.capture()
        #expect(!f.captions.tap.isEnabled)
        #expect(f.engine.sessions.isEmpty)

        f.engine.prepareGate?.resume()
        let session = try #require(f.captions.session)
        try await f.until { session.status == .running }
        f.capture()
        f.capture()
        #expect(f.engine.last.appended == 1)
    }

    @Test func 录音结束后停掉会话_之后再显示面板也不跑() async throws {
        let f = Fixture()
        f.captions.isWanted = true
        let session = try #require(f.captions.session)
        try await f.until { session.status == .running }
        f.capture()
        f.capture()
        let transcription = f.engine.last

        f.captions.stop()
        #expect(transcription.cancelled)
        #expect(!f.captions.tap.isEnabled)

        f.captions.isWanted = false
        f.captions.isWanted = true
        f.capture()
        f.capture()
        #expect(f.engine.sessions.count == 1)
        #expect(!f.captions.tap.isEnabled)
    }

    /// App 的 0.1 秒取音频定时器只在需要字幕时跑：面板没开、关了字幕、录音结束后都不跑
    @Test func 只在需要字幕时要定时取音频() async throws {
        let f = Fixture()
        #expect(!f.captions.needsPumping)

        f.captions.isWanted = true
        // 准备模型期间也要取：准备好后靠 pump 打开分路
        #expect(f.captions.needsPumping)
        let session = try #require(f.captions.session)
        try await f.until { session.status == .running }
        #expect(f.captions.needsPumping)

        f.captions.isWanted = false
        #expect(!f.captions.needsPumping)

        f.captions.isWanted = true
        f.captions.stop()
        #expect(!f.captions.needsPumping)
    }

    /// 录音时面板一直没开，停止录音后也不该凭空创建会话
    @Test func 没显示过面板就结束录音_不创建会话() {
        let f = Fixture()
        f.captions.stop()
        f.captions.isWanted = true
        #expect(f.captions.session == nil)
    }
}
