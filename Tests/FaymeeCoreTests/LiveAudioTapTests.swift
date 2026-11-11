import AVFoundation
import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-11T02:00:00Z", strategy: .iso8601)
private let mic = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

/// 一块 0.1 秒的音频，每个样本都是 value
private func chunk(_ value: Float, format: AVAudioFormat = mic, seconds: Double = 0.1) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount(format.sampleRate * seconds)
    let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    b.frameLength = frames
    for c in 0..<Int(format.channelCount) {
        for i in 0..<Int(frames) { b.floatChannelData![c][i] = value }
    }
    return b
}

private func firstSample(_ b: AVAudioPCMBuffer) -> Float { b.floatChannelData![0][0] }

@Suite struct LiveAudioTapTests {
    @Test func 打开时按先后取出_带收到的时刻() {
        let tap = LiveAudioTap()
        tap.isEnabled = true
        tap.push(chunk(0.1), at: t0)
        tap.push(chunk(0.2), at: t0.addingTimeInterval(0.1))

        let drained = tap.drain()
        #expect(drained.map { firstSample($0.buffer) } == [0.1, 0.2])
        #expect(drained.map(\.time) == [t0, t0.addingTimeInterval(0.1)])
        #expect(tap.drain().isEmpty)
    }

    @Test func 只保留最新约十秒_满了丢最旧的() {
        let tap = LiveAudioTap(capacity: 1)
        tap.isEnabled = true
        for i in 0..<15 { tap.push(chunk(Float(i)), at: t0.addingTimeInterval(Double(i) / 10)) }

        let drained = tap.drain()
        #expect(drained.map { firstSample($0.buffer) } == (5..<15).map(Float.init))
    }

    @Test func 不跑字幕时不复制_关掉时丢掉已缓存的() {
        let tap = LiveAudioTap()
        tap.push(chunk(0.1), at: t0)
        #expect(tap.drain().isEmpty)

        tap.isEnabled = true
        tap.push(chunk(0.2), at: t0)
        tap.isEnabled = false
        tap.isEnabled = true
        #expect(tap.drain().isEmpty)
    }

    /// 采集的缓冲在回调返回后会被复用，缓存里必须是拷贝
    @Test func 缓存的是拷贝_采集缓冲之后被改写不影响() {
        let tap = LiveAudioTap()
        tap.isEnabled = true
        let source = chunk(0.5)
        tap.push(source, at: t0)
        source.floatChannelData![0][0] = 0.9

        #expect(tap.drain().map { firstSample($0.buffer) } == [0.5])
    }

    /// 切换麦克风后格式会变，实时字幕会话据此开新转写，分路原样交过去
    @Test func 换了格式的音频原样交出_时长按各自的采样率算() {
        let usb = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let tap = LiveAudioTap(capacity: 1)
        tap.isEnabled = true
        for i in 0..<5 { tap.push(chunk(Float(i)), at: t0) }
        for i in 5..<12 { tap.push(chunk(Float(i), format: usb), at: t0) }

        let drained = tap.drain()
        #expect(drained.map { firstSample($0.buffer) } == (2..<12).map(Float.init))
        #expect(drained.last?.buffer.format == usb)
        #expect(drained.last?.buffer.floatChannelData![1][0] == 11)
    }
}
