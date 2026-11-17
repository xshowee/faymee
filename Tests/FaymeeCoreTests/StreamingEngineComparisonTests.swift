import AVFoundation
import Foundation
import Testing
@testable import FaymeeCore

/// 实时字幕引擎的对比（ticket 07）：同一段录音按 0.1 秒一块、按实时速度同时送给 SpeechAnalyzer 流式和 X-ASR，
/// 记下各自的定稿句子和每句定稿比说完晚多久。只在手动指定录音时运行，录音和结果都不进仓库：
///
///     FAYMEE_STREAM_EVAL=/path/a.m4a,/path/b.m4a FAYMEE_STREAM_EVAL_OUT=/some/dir \
///         swift test --filter StreamingEngineComparison
///
/// 每段录音写一个 `<录音所在目录名>.json`：`{引擎: {text, sentences: [{start, end, text, latency}]}}`。
/// 字差异率另用脚本按 eval/stream_cmp.py 的方法对参照文本算
private let evalAudio = ProcessInfo.processInfo.environment["FAYMEE_STREAM_EVAL"]?
    .split(separator: ",").map { URL(fileURLWithPath: String($0)) } ?? []
private let evalOutput = ProcessInfo.processInfo.environment["FAYMEE_STREAM_EVAL_OUT"].map { URL(fileURLWithPath: $0) }
/// 只跑这几个引擎（逗号分隔的引擎名，如 `SpeechAnalyzer`）；不设时全跑
private let evalEngines = ProcessInfo.processInfo.environment["FAYMEE_STREAM_EVAL_ENGINES"]?
    .split(separator: ",").map(String.init)
/// 热词对比用的热词表（同评估 loops.py）
private let evalHotwords = ["DeerFlow", "LangChain", "Harness", "Agent", "智能体", "工具广场", "模型广场", "端到端研发"]

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var sentences: [(TranscribedSentence, latency: Double)] = []
    private var failures: [String] = []
    func add(_ s: TranscribedSentence, latency: Double) { lock.withLock { sentences.append((s, latency)) } }
    func fail(_ reason: String) { lock.withLock { failures.append(reason) } }
    var all: [(TranscribedSentence, latency: Double)] { lock.withLock { sentences } }
    var failed: [String] { lock.withLock { failures } }
}

@Suite(.enabled(if: !evalAudio.isEmpty && evalOutput != nil, "手动对比：设 FAYMEE_STREAM_EVAL 和 FAYMEE_STREAM_EVAL_OUT"))
struct StreamingEngineComparisonTests {
    @Test func 同一段录音实时送给各引擎() async throws {
        let output = try #require(evalOutput)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for url in evalAudio {
                group.addTask { try await compare(url, output: output) }
            }
            try await group.waitForAll()
        }
    }

    private func compare(_ url: URL, output: URL) async throws {
        let engines: [(String, any StreamingTranscriber, [String])] = [
            ("SpeechAnalyzer", SpeechAnalyzerStreamingTranscriber(), []),
            ("X-ASR-480ms", SherpaStreamingTranscriber(model: .xASR480), []),
            ("X-ASR-960ms", SherpaStreamingTranscriber(model: .xASR960), []),
            ("X-ASR-480ms+热词", SherpaStreamingTranscriber(model: .xASR480), evalHotwords),
        ].filter { evalEngines?.contains($0.0) ?? true }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        for (_, engine, _) in engines { try await engine.prepare { _ in } }
        let clock = ContinuousClock()
        let began = clock.now
        var runs: [(String, any StreamingTranscription, Collected, Task<Void, Never>)] = []
        for (name, engine, hotwords) in engines {
            let transcription = engine.start(format: format, hotwords: hotwords)
            let collected = Collected()
            let task = Task {
                for await event in transcription.events {
                    switch event {
                    case .sentence(let s):
                        let now = clock.now - began
                        let wall = Double(now.components.seconds) + Double(now.components.attoseconds) / 1e18
                        collected.add(s, latency: wall - s.end)
                    case .failed(let reason): collected.fail(reason)
                    case .volatile: break
                    }
                }
            }
            runs.append((name, transcription, collected, task))
        }

        // 按实时速度送：第 i 块在开始后 i × 0.1 秒送入，不因为某块送得慢而累积误差
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        var index = 0
        while file.framePosition < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk))
            let position = Double(file.framePosition) / format.sampleRate
            try file.read(into: buffer, frameCount: chunk)
            for run in runs { run.1.append(buffer, at: position) }
            index += 1
            try await clock.sleep(until: began + .milliseconds(100 * index))
        }
        for run in runs { run.1.finish() }
        var result: [String: Any] = [:]
        for (name, _, collected, task) in runs {
            await task.value
            #expect(collected.failed.isEmpty, "\(name)：\(collected.failed)")
            let sentences = collected.all
            result[name] = [
                "text": sentences.map(\.0.text).joined(),
                "failures": collected.failed,
                "sentences": sentences.map { ["start": $0.0.start, "end": $0.0.end, "text": $0.0.text, "latency": $0.latency] },
            ]
        }
        let name = url.deletingLastPathComponent().lastPathComponent
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("\(name).json"))
    }
}
