import AVFoundation
import Foundation
import Testing
@testable import FaymeeCore

/// 仓库里的模型目录（scripts/fetch-diarization-models.sh 下载，被 git 忽略）
private let modelDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Diarization", isDirectory: true)
private let modelsPresent = SherpaOnnxDiarizer.modelsPresent(in: modelDirectory)

private func resource(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "m4a", subdirectory: "Resources"))
}

/// two-speakers-zh.m4a 的真值：macOS `say` 的 Tingting（A）与 “Eddy (中文（中国大陆）)”（B）轮流各说三段中文，
/// `--data-format=LEI16@16000` 合成、段间插 0.6 秒静音拼接，再用 `afconvert -d aac@24000` 压成 24 kHz AAC
/// （顺带测了解码与重采样）。part1 是 0–25.78 秒（A B A），part2 是 25.78 秒到结尾（B A B）
private let truth: [(start: Double, end: Double, speaker: String)] = [
    (0.00, 8.47, "A"), (9.07, 17.43, "B"), (18.03, 25.48, "A"),
    (26.08, 33.58, "B"), (34.18, 41.22, "A"), (41.82, 48.21, "B"),
]

/// 一段区分结果里，与真值说话人 `name`（在 `range` 秒内）重合最多的引擎编号
private func label(of name: String, in segments: [SpeakerSegment], within range: ClosedRange<Double>,
                   offset: Double) -> Int? {
    var byLabel: [Int: Double] = [:]
    for t in truth where t.speaker == name && range.contains(t.start) {
        for s in segments {
            byLabel[s.speaker, default: 0] += max(0, min(t.end, s.end + offset) - max(t.start, s.start + offset))
        }
    }
    return byLabel.max { $0.value < $1.value }?.key
}

/// 真值说话时长里，被归给“该真值说话人对应的引擎说话人”的比例。引擎编号与真值按重合最多配对
private func agreement(_ segments: [SpeakerSegment]) -> Double {
    func overlap(_ a: (Double, Double), _ b: (Double, Double)) -> Double { max(0, min(a.1, b.1) - max(a.0, b.0)) }
    var mapping: [String: Int] = [:]
    for name in ["A", "B"] {
        var byLabel: [Int: Double] = [:]
        for t in truth where t.speaker == name {
            for s in segments { byLabel[s.speaker, default: 0] += overlap((t.start, t.end), (s.start, s.end)) }
        }
        mapping[name] = byLabel.max { $0.value < $1.value }?.key
    }
    let total = truth.reduce(0) { $0 + $1.end - $1.start }
    let correct = truth.reduce(0.0) { sum, t in
        sum + segments.filter { $0.speaker == mapping[t.speaker] }
            .reduce(0) { $0 + overlap((t.start, t.end), ($1.start, $1.end)) }
    }
    return correct / total
}

/// 契约测试：用真实模型跑。模型不在时跳过（先跑 scripts/fetch-diarization-models.sh）
@Suite(.serialized, .enabled(if: modelsPresent, "需要 Resources/Diarization 下的模型，见 scripts/fetch-diarization-models.sh"))
struct SherpaOnnxDiarizerContractTests {
    @Test func 自动判断人数_区分出2人且大部分时长归属正确() async throws {
        let engine = SherpaOnnxDiarizer(modelDirectory: modelDirectory)
        try await engine.prepare { _ in }

        let result = try await engine.diarize(audio: try resource("two-speakers-zh"), speakerCount: nil) { _ in }

        #expect(Set(result.segments.map(\.speaker)).count == 2)
        #expect(agreement(result.segments) >= 0.9)
    }

    @Test func 指定人数() async throws {
        let engine = SherpaOnnxDiarizer(modelDirectory: modelDirectory)

        let result = try await engine.diarize(audio: try resource("two-speakers-zh"), speakerCount: 2) { _ in }

        #expect(Set(result.segments.map(\.speaker)).count == 2)
        #expect(agreement(result.segments) >= 0.9)
    }

    @Test func 每个说话人都有声纹() async throws {
        let engine = SherpaOnnxDiarizer(modelDirectory: modelDirectory)

        let result = try await engine.diarize(audio: try resource("two-speakers-zh"), speakerCount: nil) { _ in }

        #expect(Set(result.voiceprints.keys) == Set(result.segments.map(\.speaker)))
        #expect(result.voiceprints.values.allSatisfy { $0.vector.count == 192 })
    }

    /// 前后两半当成两场会议分别区分：同一人跨场的声纹比不同人像，且推荐阈值把两者分开
    @Test func 同一人两段录音的声纹相似度高于不同人() async throws {
        let engine = SherpaOnnxDiarizer(modelDirectory: modelDirectory)
        let first = try await engine.diarize(audio: try resource("two-speakers-zh-part1"), speakerCount: nil) { _ in }
        let second = try await engine.diarize(audio: try resource("two-speakers-zh-part2"), speakerCount: nil) { _ in }

        func voiceprint(_ name: String, _ r: DiarizationResult, part: Int) throws -> Voiceprint {
            let range = part == 1 ? 0.0...25.78 : 25.78...60
            let l = try #require(label(of: name, in: r.segments, within: range, offset: part == 1 ? 0 : 25.78))
            return try #require(r.voiceprints[l])
        }
        let a1 = try voiceprint("A", first, part: 1), b1 = try voiceprint("B", first, part: 1)
        let a2 = try voiceprint("A", second, part: 2), b2 = try voiceprint("B", second, part: 2)
        let threshold = SherpaOnnxDiarizer.recommendedMatchThreshold

        #expect(a1.similarity(to: a2) > threshold)
        #expect(b1.similarity(to: b2) > threshold)
        #expect(a1.similarity(to: b2) < threshold)
        #expect(b1.similarity(to: a2) < threshold)
    }

    @Test func 进度单调递增并报告到1() async throws {
        let values = Values()
        _ = try await SherpaOnnxDiarizer(modelDirectory: modelDirectory)
            .diarize(audio: try resource("two-speakers-zh"), speakerCount: nil) { values.append($0) }

        #expect(values.all.last == 1)
        #expect(values.all.count > 3)
        #expect(zip(values.all, values.all.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func 开始前取消_抛出CancellationError() async throws {
        let url = try resource("two-speakers-zh")
        let engine = SherpaOnnxDiarizer(modelDirectory: modelDirectory)
        let task = Task { try await engine.diarize(audio: url, speakerCount: nil) { _ in } }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// sherpa-onnx 中途停不下来：跑完这次再抛，结果作废
    @Test func 进行中取消_抛出CancellationError() async throws {
        let url = try resource("two-speakers-zh")
        let engine = SherpaOnnxDiarizer(modelDirectory: modelDirectory)
        let started = Values()
        let task = Task { try await engine.diarize(audio: url, speakerCount: nil) { started.append($0) } }
        while started.all.allSatisfy({ $0 < 0.1 }) { try await Task.sleep(for: .milliseconds(20)) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func 全程静音_没有说话人() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 10))
        buffer.frameLength = buffer.frameCapacity  // 新建的 buffer 全是 0
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)

        let result = try await SherpaOnnxDiarizer(modelDirectory: modelDirectory)
            .diarize(audio: url, speakerCount: nil) { _ in }

        #expect(result.segments.isEmpty)
        #expect(result.voiceprints.isEmpty)
    }
}

/// 模型文件不对时要抛错，不能交给 sherpa-onnx（它遇到坏模型会直接结束整个进程）。不需要真实模型
struct SherpaOnnxDiarizerModelTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 放一个大小对、内容不对的文件
    private func placeFake(_ model: SherpaOnnxDiarizer.ModelFile, in dir: URL) throws {
        let url = dir.appendingPathComponent(model.name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(model.size))
        try handle.close()
    }

    @Test func 缺模型时没有可用引擎_准备时报缺少() async throws {
        let dir = try directory()
        try placeFake(SherpaOnnxDiarizer.embeddingModel, in: dir)

        #expect(!SherpaOnnxDiarizer.modelsPresent(in: dir))
        await #expect(throws: SherpaOnnxDiarizerError.modelMissing(SherpaOnnxDiarizer.segmentationModel.name)) {
            try await SherpaOnnxDiarizer(modelDirectory: dir).prepare { _ in }
        }
    }

    @Test func 模型内容不对时准备和区分都报损坏() async throws {
        let dir = try directory()
        for m in SherpaOnnxDiarizer.models { try placeFake(m, in: dir) }
        let engine = SherpaOnnxDiarizer(modelDirectory: dir)

        #expect(SherpaOnnxDiarizer.modelsPresent(in: dir))
        let corrupted = SherpaOnnxDiarizerError.modelCorrupted(SherpaOnnxDiarizer.segmentationModel.name)
        await #expect(throws: corrupted) { try await engine.prepare { _ in } }
        await #expect(throws: corrupted) {
            try await engine.diarize(audio: dir.appendingPathComponent("none.m4a"), speakerCount: nil) { _ in }
        }
    }
}

/// 引擎处理失败（sherpa-onnx 返回 NULL）时要抛错，不能当成“没有说话人”：否则重新区分会用空结果覆盖原来的说话人和名字。
/// 真实引擎没法稳定地造出 NULL，直接测把 C 结果转成说话片段的那一步。不需要真实模型
struct SherpaOnnxDiarizerResultTests {
    @Test func 引擎没有返回结果时抛错() {
        #expect(throws: SherpaOnnxDiarizerError.processingFailed) {
            try SherpaOnnxDiarizer.segments(of: nil)
        }
    }
}

private final class Values: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ v: Double) { lock.withLock { values.append(v) } }
    var all: [Double] { lock.withLock { values } }
}
