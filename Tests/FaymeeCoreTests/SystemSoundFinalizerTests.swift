import AVFoundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-10T02:00:00Z", strategy: .iso8601)

/// 相对 t0 的墙钟时间
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// 一段有声的信号：相对分片起点的起止（秒）
private typealias Burst = (start: Double, end: Double)

/// 写一个 CAF 分片：除了 bursts 标出的时段是 0.3 振幅的 440 Hz 正弦，其余是全零。
/// 多声道时每个声道内容相同
private func writeCAF(_ url: URL, seconds: Double, channels: AVAudioChannelCount = 1,
                      sampleRate: Double = 48000, bursts: [Burst] = []) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(seconds * sampleRate)
    guard frames > 0 else { return }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for i in 0..<Int(frames) {
        let t = Double(i) / sampleRate
        let loud = bursts.contains { t >= $0.start && t < $0.end }
        let v: Float = loud ? 0.3 * sin(Float(t * 2 * .pi * 440)) : 0
        for c in 0..<Int(channels) { buffer.floatChannelData![c][i] = v }
    }
    try file.write(from: buffer)
}

/// 解码后的录音
private struct Decoded {
    var channels: Int
    var duration: TimeInterval
    /// 有声的时段（秒），按 10 毫秒窗口的 RMS 判定，相邻的窗口合并
    var loud: [Burst]
}

private func decode(_ url: URL) throws -> Decoded {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let rate = format.sampleRate
    let window = Int(rate / 100)
    let frames = Int(buffer.frameLength)
    var loud: [Burst] = []
    var start = 0
    while start < frames {
        let end = min(start + window, frames)
        var sum: Float = 0
        for c in 0..<Int(format.channelCount) {
            let p = buffer.floatChannelData![c]
            for i in start..<end { sum += p[i] * p[i] }
        }
        let rms = (sum / Float((end - start) * Int(format.channelCount))).squareRoot()
        if rms > 0.02 {
            let (s, e) = (Double(start) / rate, Double(end) / rate)
            if let last = loud.last, abs(last.end - s) < 0.001 {
                loud[loud.count - 1].end = e
            } else {
                loud.append((s, e))
            }
        }
        start = end
    }
    return Decoded(channels: Int(format.channelCount), duration: Double(file.length) / rate, loud: loud)
}

/// 有声时段与预期一致，起止误差在 tolerance 秒内
private func expectLoud(_ actual: [Burst], _ expected: [Burst], tolerance: Double = 0.03,
                        sourceLocation: SourceLocation = #_sourceLocation) {
    let description = actual.map { String(format: "%.3f–%.3f", $0.start, $0.end) }.joined(separator: ", ")
    #expect(actual.count == expected.count, "有声时段：\(description)", sourceLocation: sourceLocation)
    for (a, e) in zip(actual, expected) {
        #expect(abs(a.start - e.start) < tolerance && abs(a.end - e.end) < tolerance,
                "有声时段：\(description)", sourceLocation: sourceLocation)
    }
}

/// 每个用例一个独立的存储根目录和一场会议
private struct Fixture {
    let store = MeetingStore(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("SystemSoundFinalizerTests-\(UUID().uuidString)", isDirectory: true))
    var meeting: Meeting

    init() throws {
        meeting = try store.create(startedAt: t0)
        try FileManager.default.createDirectory(at: store.systemSoundSegmentsDirectory(meeting.id),
                                                withIntermediateDirectories: true)
    }

    /// 麦克风分片：写盘并记进会议
    mutating func mic(_ file: String, at seconds: TimeInterval, length: Double,
                      channels: AVAudioChannelCount = 1, bursts: [Burst] = []) throws {
        try writeCAF(store.segmentsDirectory(meeting.id).appendingPathComponent(file),
                     seconds: length, channels: channels, bursts: bursts)
        meeting.segments.append(Segment(file: file, startedAt: at(seconds), sampleRate: 48000,
                                        channels: Int(channels), device: "MacBook Pro 麦克风", deviceUID: "BuiltIn"))
    }

    /// 系统声音分片（立体声）：写盘，recorded 为 false 时不记进会议（崩溃时还没来得及写 meeting.json）
    mutating func system(_ file: String, at seconds: TimeInterval, length: Double,
                         bursts: [Burst] = [], recorded: Bool = true) throws {
        try writeCAF(store.systemSoundSegmentsDirectory(meeting.id).appendingPathComponent(file),
                     seconds: length, channels: 2, bursts: bursts)
        guard recorded else { return }
        meeting.systemSoundSegmentList.append(
            SystemSoundSegment(file: file, startedAt: at(seconds), sampleRate: 48000, channels: 2))
    }

    func finalize() async throws -> FinalizeResult {
        try await Finalizer.export(meeting, in: store)
    }

    var recording: URL { store.directory(meeting.id).appendingPathComponent("recording.m4a") }
    var systemSound: URL { store.directory(meeting.id).appendingPathComponent("system.m4a") }

    func cleanUp() { try? FileManager.default.removeItem(at: store.root) }
}

@Suite struct SystemSoundFinalizerTests {
    /// 两个麦克风分片之间丢了 3 秒（墙钟 2–5 秒）。系统声音经时间线换算摆进录音：
    /// 墙钟 5.5 秒的声音在录音 2.5 秒处，而不是按墙钟直接减得到的 5.5 秒；断点里的声音丢弃
    @Test func 系统声音经时间线换算跨过麦克风断点() async throws {
        var f = try Fixture()
        defer { f.cleanUp() }
        try f.mic("0001.caf", at: 0, length: 2, bursts: [(0.2, 0.4)])
        try f.mic("0002.caf", at: 5, length: 2)
        // 墙钟 1–6.8 秒，有声的是墙钟 1.5、3.5（断点里）、5.5 秒起的各 0.2 秒
        try f.system("0001.caf", at: 1, length: 5.8, bursts: [(0.5, 0.7), (2.5, 2.7), (4.5, 4.7)])

        let result = try await f.finalize()

        #expect(abs(result.duration - 4) < 0.05)
        let recording = try decode(f.recording)
        expectLoud(recording.loud, [(0.2, 0.4), (1.5, 1.7), (2.5, 2.7)])
        let system = try decode(f.systemSound)
        expectLoud(system.loud, [(1.5, 1.7), (2.5, 2.7)])
    }

    /// 连续的系统声音跨过两个首尾相接的麦克风分片的边界（录音 2 秒处）：接缝处不重复、不丢失
    @Test func 系统声音跨过正常的麦克风分片边界不重复不丢失() async throws {
        var f = try Fixture()
        defer { f.cleanUp() }
        try f.mic("0001.caf", at: 0, length: 2)
        try f.mic("0002.caf", at: 2, length: 2)
        // 墙钟 0.5–3.5 秒；有声的是墙钟 1.8–2.2 秒，跨过接缝。重复或丢失都会让这段变长或变短
        try f.system("0001.caf", at: 0.5, length: 3, bursts: [(1.3, 1.7)])

        _ = try await f.finalize()

        expectLoud(try decode(f.recording).loud, [(1.8, 2.2)])
        expectLoud(try decode(f.systemSound).loud, [(1.8, 2.2)])
    }

    /// 前一个系统声音分片的结尾和后一个分片的开头在墙钟上重叠了 0.1 秒（墙钟起点有出入）：
    /// 录音里不出现两遍，后一个分片之后的声音位置不被推后
    @Test func 重叠的系统声音分片不把后面的声音推后() async throws {
        var f = try Fixture()
        defer { f.cleanUp() }
        try f.mic("0001.caf", at: 0, length: 4)
        // 前一个分片在墙钟 1.9–2.1 秒有声，其中 2.0–2.1 秒与后一个分片重叠
        try f.system("0001.caf", at: 0, length: 2.1, bursts: [(1.9, 2.1)])
        try f.system("0002.caf", at: 2, length: 1.5, bursts: [(1.0, 1.2)])

        _ = try await f.finalize()

        expectLoud(try decode(f.recording).loud, [(1.9, 2.1), (3.0, 3.2)])
    }

    @Test func 有系统声音时录音是单声道且系统声音文件与录音等长() async throws {
        var f = try Fixture()
        defer { f.cleanUp() }
        // 立体声的麦克风也一样混成单声道
        try f.mic("0001.caf", at: 0, length: 3, channels: 2, bursts: [(0.2, 0.4)])
        // 系统声音只在墙钟 1–2 秒有分片，system.m4a 其余位置是静音
        try f.system("0001.caf", at: 1, length: 1, bursts: [(0.5, 0.7)])

        let result = try await f.finalize()

        #expect(result.systemSoundFile == "system.m4a")
        let recording = try decode(f.recording)
        let system = try decode(f.systemSound)
        #expect(recording.channels == 1)
        #expect(system.channels == 1)
        #expect(abs(recording.duration - 3) < 0.05)
        #expect(abs(system.duration - recording.duration) < 0.05)
        expectLoud(recording.loud, [(0.2, 0.4), (1.5, 1.7)])
        expectLoud(system.loud, [(1.5, 1.7)])
    }

    /// 没开系统声音：照旧用 Apple 的 m4a 预设导出，立体声的麦克风仍是立体声，不生成 system.m4a
    @Test func 没有系统声音时产出与以前相同() async throws {
        var f = try Fixture()
        defer { f.cleanUp() }
        try f.mic("0001.caf", at: 0, length: 2, channels: 2, bursts: [(0.2, 0.4)])
        try f.mic("0002.caf", at: 2, length: 1)

        let result = try await f.finalize()

        #expect(result.systemSoundFile == nil)
        #expect(!FileManager.default.fileExists(atPath: f.systemSound.path))
        let recording = try decode(f.recording)
        #expect(recording.channels == 2)
        #expect(abs(result.duration - 3) < 0.05)
        #expect(result.placements.map(\.offset) == [0, 2])
        expectLoud(recording.loud, [(0.2, 0.4)])
        var m = f.meeting
        m.markFinalized(recording: Finalizer.recordingFile, result)
        #expect(m.systemSoundRecording == nil)
    }

    /// 崩溃时系统声音分片已经写盘、还没记进 meeting.json：不知道墙钟起点，丢弃
    @Test func 磁盘上有但会议里没记的系统声音分片被丢弃() async throws {
        var f = try Fixture()
        defer { f.cleanUp() }
        try f.mic("0001.caf", at: 0, length: 4)
        try f.system("0001.caf", at: 1, length: 1, bursts: [(0.2, 0.4)])
        try f.system("0002.caf", at: 2, length: 2, bursts: [(0, 2)], recorded: false)

        let result = try await f.finalize()

        expectLoud(try decode(f.recording).loud, [(1.2, 1.4)])
        expectLoud(try decode(f.systemSound).loud, [(1.2, 1.4)])
        var m = f.meeting
        m.markFinalized(recording: Finalizer.recordingFile, result)
        #expect(m.systemSoundRecording == "system.m4a")
    }

    /// 只有没记进会议的系统声音分片，或系统声音全落在麦克风断点里：没有系统声音摆进录音，产出与没开时相同
    @Test func 没有系统声音摆进录音时不生成系统声音文件() async throws {
        var f = try Fixture()
        defer { f.cleanUp() }
        try f.mic("0001.caf", at: 0, length: 2)
        try f.mic("0002.caf", at: 5, length: 2)
        try f.system("0001.caf", at: 2.5, length: 2, bursts: [(0, 2)])
        try f.system("0002.caf", at: 0, length: 2, bursts: [(0, 2)], recorded: false)

        let result = try await f.finalize()

        #expect(result.systemSoundFile == nil)
        #expect(!FileManager.default.fileExists(atPath: f.systemSound.path))
        expectLoud(try decode(f.recording).loud, [])
    }

    @Test func 删除会议时一并删除系统声音文件() async throws {
        var f = try Fixture()
        defer { f.cleanUp() }
        try f.mic("0001.caf", at: 0, length: 2)
        try f.system("0001.caf", at: 0, length: 2, bursts: [(0.5, 0.7)])
        let result = try await f.finalize()
        f.meeting.markFinalized(recording: Finalizer.recordingFile, result)
        try f.store.save(f.meeting)
        let system = try #require(f.store.systemSoundRecordingURL(f.meeting))
        #expect(FileManager.default.fileExists(atPath: system.path))

        try f.store.trash(f.meeting.id)

        #expect(!FileManager.default.fileExists(atPath: system.path))
        #expect(f.store.loadAll().isEmpty)
    }
}
