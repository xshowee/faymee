import AVFoundation
import Testing
@testable import FaymeeCore

/// 写一段指定时长的单声道 CAF（内容是低音量正弦波，内容本身不重要）
private func writeCAF(_ url: URL, seconds: Double, sampleRate: Double = 48000) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(seconds * sampleRate)
    guard frames > 0 else { return }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let samples = buffer.floatChannelData![0]
    for i in 0..<Int(frames) { samples[i] = 0.1 * sin(Float(i) * 2 * .pi * 440 / Float(sampleRate)) }
    try file.write(from: buffer)
}

@Suite struct FinalizerTests {
    @Test func 返回每个分片在录音中的偏移和时长() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinalizerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = (1...4).map { dir.appendingPathComponent(String(format: "%04d.caf", $0)) }
        try writeCAF(files[0], seconds: 2)
        // 刚创建就崩溃：只有文件头，没有音频
        try writeCAF(files[1], seconds: 0)
        // 内容损坏，打不开
        try Data("not a caf".utf8).write(to: files[2])
        // 中途换了麦克风，采样率不同
        try writeCAF(files[3], seconds: 1, sampleRate: 44100)

        let result = try await Finalizer.export(segments: files, to: dir.appendingPathComponent("recording.m4a"))

        #expect(abs(result.duration - 3) < 0.1)
        #expect(result.placements.map(\.file) == files)
        let expected: [(offset: TimeInterval, duration: TimeInterval)] = [(0, 2), (2, 0), (2, 0), (2, 1)]
        for (placement, want) in zip(result.placements, expected) {
            #expect(abs(placement.offset - want.offset) < 0.001, "\(placement.file.lastPathComponent) 的偏移")
            #expect(abs(placement.duration - want.duration) < 0.001, "\(placement.file.lastPathComponent) 的时长")
        }
    }

    @Test func 分片位置按文件名写回会议且磁盘上缺失的分片记为时长0() throws {
        let t0 = try Date("2026-11-10T02:00:00Z", strategy: .iso8601)
        let dir = URL(fileURLWithPath: "/tmp/m/segments", isDirectory: true)
        var m = Meeting(id: "m", title: "会议", startedAt: t0, status: .finalizing, segments: ["0001.caf", "0002.caf", "0003.caf"]
            .enumerated().map { i, file in
                Segment(file: file, startedAt: t0.addingTimeInterval(Double(i) * 600), sampleRate: 48000,
                        channels: 1, device: "MacBook Pro 麦克风", deviceUID: "BuiltIn")
            })

        // 0002.caf 不在磁盘上（例如被手动删掉），整理时没有它的位置
        m.recordPlacements([
            SegmentPlacement(file: dir.appendingPathComponent("0001.caf"), offset: 0, duration: 600),
            SegmentPlacement(file: dir.appendingPathComponent("0003.caf"), offset: 600, duration: 300),
        ])

        #expect(m.segments.map(\.offset) == [0, 600, 600])
        #expect(m.segments.map(\.duration) == [600, 0, 300])
    }
}
