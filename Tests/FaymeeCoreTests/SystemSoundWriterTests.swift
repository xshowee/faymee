import AVFoundation
import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-17T02:00:00Z", strategy: .iso8601)
/// 测试用的 host time：每秒 1_000_000 个 tick（故意不是纳秒），t0 对应 tick 5_000_000
private let clock = HostClock(ticksPerSecond: 1_000_000, referenceHostTime: 5_000_000, referenceDate: t0)
private let stereo = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 2)!

/// t0 之后 seconds 秒的 host time
private func host(_ seconds: Double) -> UInt64 { UInt64(5_000_000 + (seconds * 1_000_000).rounded()) }

/// 一块音频，每个样本都是 value（取 16 位能精确表示的值，读回来可以直接比较）
private func chunk(_ value: Float, format: AVAudioFormat = stereo, seconds: Double = 0.1) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount((format.sampleRate * seconds).rounded())
    let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    b.frameLength = frames
    if format.isInterleaved {
        for i in 0..<Int(frames * format.channelCount) { b.floatChannelData![0][i] = value }
    } else {
        for c in 0..<Int(format.channelCount) {
            for i in 0..<Int(frames) { b.floatChannelData![c][i] = value }
        }
    }
    return b
}

/// 每次测试一个临时的系统声音分片目录，收集写盘模块交出来的分片和错误
private final class Harness: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SystemSoundWriterTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("system", isDirectory: true)
    private let lock = NSLock()
    private var _segments: [SystemSoundWriter.Segment] = []
    private var _errors: [String] = []
    var segments: [SystemSoundWriter.Segment] { lock.withLock { _segments } }
    var errors: [String] { lock.withLock { _errors } }

    func writer(directory: URL? = nil, segmentSeconds: TimeInterval = 60) -> SystemSoundWriter {
        SystemSoundWriter(directory: directory ?? self.directory, clock: clock, segmentSeconds: segmentSeconds,
                          onSegment: { [self] s in lock.withLock { _segments.append(s) } },
                          onError: { [self] e in lock.withLock { _errors.append(e) } })
    }

    /// 读回一个分片：第一个声道的全部样本
    func samples(_ file: String) throws -> [Float] {
        let f = try AVAudioFile(forReading: directory.appendingPathComponent(file))
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: b)
        return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
}

@Suite struct SystemSoundWriterTests {
    @Test func 连续的音频写进一个分片_记下第一帧的墙钟起点和格式() throws {
        let h = Harness()
        defer { h.cleanUp() }
        let writer = h.writer()
        writer.push(chunk(0.5), hostTime: host(2))
        writer.push(chunk(0.25), hostTime: host(2.1))
        writer.finish()

        #expect(h.segments == [SystemSoundWriter.Segment(file: "0001.caf", startedAt: t0.addingTimeInterval(2),
                                                         sampleRate: 8000, channels: 2)])
        #expect(try h.samples("0001.caf") == Array(repeating: 0.5, count: 800) + Array(repeating: 0.25, count: 800))
        #expect(h.errors.isEmpty)
    }

    /// 没有声音播放时可能整段没有回调，分片里按 host time 补上静音，片内位置才和墙钟对得上
    @Test func 块之间的空洞按host_time补静音() throws {
        let h = Harness()
        defer { h.cleanUp() }
        let writer = h.writer()
        writer.push(chunk(0.5), hostTime: host(0))
        writer.push(chunk(0.25), hostTime: host(0.3))
        writer.finish()

        #expect(h.segments.map(\.file) == ["0001.caf"])
        #expect(try h.samples("0001.caf") == Array(repeating: 0.5, count: 800) + Array(repeating: 0, count: 1600)
            + Array(repeating: 0.25, count: 800))
    }

    /// 回调的 host time 前后有几毫秒的抖动，早到晚到都照原样接着写，不补零、不丢
    @Test func 回调间隔的小抖动在容差内不补() throws {
        let h = Harness()
        defer { h.cleanUp() }
        let writer = h.writer()
        writer.push(chunk(0.5), hostTime: host(0))
        writer.push(chunk(0.25), hostTime: host(0.105))
        writer.push(chunk(0.125), hostTime: host(0.196))
        writer.finish()

        #expect(try h.samples("0001.caf") == Array(repeating: 0.5, count: 800) + Array(repeating: 0.25, count: 800)
            + Array(repeating: 0.125, count: 800))
    }

    @Test func 每片约60秒_下一片从接着的那一块记起点() throws {
        let h = Harness()
        defer { h.cleanUp() }
        let writer = h.writer()
        for i in 0..<260 { writer.push(chunk(0.5, seconds: 0.5), hostTime: host(10 + Double(i) * 0.5)) }
        writer.finish()

        #expect(h.segments.map(\.file) == ["0001.caf", "0002.caf", "0003.caf"])
        #expect(h.segments.map(\.startedAt) == [10, 70, 130].map { t0.addingTimeInterval($0) })
        #expect(try ["0001.caf", "0002.caf", "0003.caf"].map { try h.samples($0).count } == [480_000, 480_000, 80_000])
    }

    /// 很久没有声音（比如一直没有回调）时不写长串的零，等声音回来时开新分片
    @Test func 长空洞时关掉当前分片_声音回来开新分片并记新的起点() throws {
        let h = Harness()
        defer { h.cleanUp() }
        let writer = h.writer()
        writer.push(chunk(0.5), hostTime: host(0))
        writer.push(chunk(0.25), hostTime: host(100))
        writer.push(chunk(0.125), hostTime: host(100.1))
        writer.finish()

        #expect(h.segments == [
            SystemSoundWriter.Segment(file: "0001.caf", startedAt: t0, sampleRate: 8000, channels: 2),
            SystemSoundWriter.Segment(file: "0002.caf", startedAt: t0.addingTimeInterval(100), sampleRate: 8000,
                                      channels: 2),
        ])
        #expect(try h.samples("0001.caf") == Array(repeating: 0.5, count: 800))
        #expect(try h.samples("0002.caf") == Array(repeating: 0.25, count: 800) + Array(repeating: 0.125, count: 800))
    }

    /// 切换输出设备后采样率、声道数可能变，一个分片只有一种格式
    @Test func 格式变了开新分片_记下新的采样率和声道数() throws {
        let h = Harness()
        defer { h.cleanUp() }
        let mono = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let writer = h.writer()
        writer.push(chunk(0.5), hostTime: host(0))
        writer.push(chunk(0.25, format: mono), hostTime: host(0.1))
        writer.finish()

        #expect(h.segments == [
            SystemSoundWriter.Segment(file: "0001.caf", startedAt: t0, sampleRate: 8000, channels: 2),
            SystemSoundWriter.Segment(file: "0002.caf", startedAt: t0.addingTimeInterval(0.1), sampleRate: 16000,
                                      channels: 1),
        ])
        #expect(try h.samples("0002.caf") == Array(repeating: 0.25, count: 1600))
    }

    /// process tap 交来的通常是交错的 32 位浮点，照样写进同一个分片
    @Test func 交错格式的音频照常写进同一个分片() throws {
        let h = Harness()
        defer { h.cleanUp() }
        let interleaved = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 2, interleaved: true)!
        let writer = h.writer()
        writer.push(chunk(0.5, format: interleaved), hostTime: host(0))
        writer.push(chunk(0.25, format: interleaved), hostTime: host(0.3))
        writer.finish()

        #expect(h.segments == [SystemSoundWriter.Segment(file: "0001.caf", startedAt: t0, sampleRate: 8000, channels: 2)])
        #expect(try h.samples("0001.caf") == Array(repeating: 0.5, count: 800) + Array(repeating: 0, count: 1600)
            + Array(repeating: 0.25, count: 800))
        #expect(h.errors.isEmpty)
    }

    /// 写不进去（比如目录被占成了普通文件）时只报一次，不刷屏、不崩
    @Test func 写盘失败只报一次() throws {
        let h = Harness()
        defer { h.cleanUp() }
        let blocker = h.directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data().write(to: h.directory)
        let writer = h.writer()
        for i in 0..<5 { writer.push(chunk(0.5), hostTime: host(Double(i) * 0.1)) }
        writer.finish()

        #expect(h.errors.count == 1)
        #expect(h.segments.isEmpty)
    }

    /// 录音中途关了再开、崩溃后恢复，都会在同一个目录上重新开始写，不能覆盖已有的分片
    @Test func 目录里已有分片时接着编号_不覆盖() throws {
        let h = Harness()
        defer { h.cleanUp() }
        let first = h.writer()
        first.push(chunk(0.5), hostTime: host(0))
        first.finish()
        let second = h.writer()
        second.push(chunk(0.25), hostTime: host(30))
        second.finish()

        #expect(h.segments.map(\.file) == ["0001.caf", "0002.caf"])
        #expect(try h.samples("0001.caf") == Array(repeating: 0.5, count: 800))
    }

    /// 采集的缓冲在回调返回后会被复用，入队的必须是拷贝
    @Test func 入队的是拷贝_采集缓冲之后被改写不影响() throws {
        let h = Harness()
        defer { h.cleanUp() }
        let writer = h.writer()
        let source = chunk(0.5)
        writer.push(source, hostTime: host(0))
        for i in 0..<800 { source.floatChannelData![0][i] = 0.9 }
        writer.finish()

        #expect(try h.samples("0001.caf") == Array(repeating: 0.5, count: 800))
    }

    @Test func 系统时钟的host_time换算成墙钟() {
        let clock = HostClock.system()
        let later = Date().addingTimeInterval(0.2)
        while Date() < later {}
        let converted = clock.date(forHostTime: mach_absolute_time())
        #expect(abs(converted.timeIntervalSinceNow) < 0.05)
        #expect(converted.timeIntervalSince(clock.referenceDate) > 0.15)
    }
}
