import AVFoundation
import Foundation
import Testing
@testable import FaymeeCore

/// 边送边收到的事件。送音频的任务和收事件的任务都会碰它
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [StreamingTranscriptionEvent] = []
    func append(_ event: StreamingTranscriptionEvent) { lock.withLock { events.append(event) } }
    var all: [StreamingTranscriptionEvent] { lock.withLock { events } }
}

/// 把录音按实时速度切成约 0.1 秒一块送入，返回收到的全部事件，以及送完音频、调用 finish() 之前已收到的事件。
/// 格式保持文件原样（22050 Hz），格式转换也一并测到
private func stream(_ url: URL, into transcription: any StreamingTranscription) async throws
    -> (all: [StreamingTranscriptionEvent], beforeFinish: [StreamingTranscriptionEvent]) {
    let file = try AVAudioFile(forReading: url)
    let received = Received()
    let collected = Task {
        for await event in transcription.events { received.append(event) }
    }
    let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
    while file.framePosition < file.length {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk))
        try file.read(into: buffer, frameCount: chunk)
        transcription.append(buffer)
        try await Task.sleep(for: .milliseconds(100))
    }
    let beforeFinish = received.all
    transcription.finish()
    await collected.value
    return (received.all, beforeFinish)
}

/// 去掉标点和空白后按字比较：1 − 编辑距离 / 较长的字数
private func similarity(_ a: String, _ b: String) -> Double {
    let x = Array(a.filter { !$0.isPunctuation && !$0.isWhitespace })
    let y = Array(b.filter { !$0.isPunctuation && !$0.isWhitespace })
    guard !x.isEmpty || !y.isEmpty else { return 1 }
    var row = Array(0...y.count)
    for i in x.indices {
        var diagonal = row[0]
        row[0] = i + 1
        for j in y.indices {
            let above = row[j + 1]
            row[j + 1] = x[i] == y[j] ? diagonal : min(diagonal, above, row[j]) + 1
            diagonal = above
        }
    }
    return 1 - Double(row[y.count]) / Double(max(x.count, y.count))
}

/// 契约测试：真实 SpeechAnalyzer 的流式输入。资源不在时跳过，同会后转写的契约测试
@Suite(.enabled("需要本机已下载中文语音资源", { await chineseAssetsInstalled() }))
struct SpeechAnalyzerStreamingTranscriberContractTests {
    @Test func 按实时速度送入_出现临时结果_定稿与会后转写大致一致_时间单调() async throws {
        let url = try sampleURL()
        let length = try duration(of: url)
        let engine = SpeechAnalyzerStreamingTranscriber()
        try await engine.prepare { _ in }
        let format = try AVAudioFile(forReading: url).processingFormat

        let (events, beforeFinish) = try await stream(url, into: engine.start(format: format, hotwords: ["飞书"]))

        // 边说边出字：送完音频之前就已经有临时结果（不开 fastResults 时要等输入结束才出）
        #expect(beforeFinish.contains { if case .volatile(let text, _) = $0 { !text.isEmpty } else { false } })
        let volatile = events.compactMap { if case .volatile(let text, _) = $0, !text.isEmpty { text } else { nil } }
        let sentences = events.compactMap { if case .sentence(let s) = $0 { s } else { nil } }
        let failures = events.compactMap { if case .failed(let reason) = $0 { reason } else { nil } }
        #expect(failures.isEmpty)
        #expect(!volatile.isEmpty)
        #expect(!sentences.isEmpty)
        #expect(sentences.allSatisfy { 0 <= $0.start && $0.start <= $0.end && $0.end <= length + 0.5 })
        #expect(zip(sentences, sentences.dropFirst()).allSatisfy { $0.end <= $1.start })

        let batch = try await SpeechAnalyzerTranscriber().transcribe(audio: url, hotwords: ["飞书"]) { _ in }
        let live = sentences.map(\.text).joined()
        let final = batch.map(\.text).joined()
        let score = similarity(live, final)
        print("流式定稿：\(live)\n会后转写：\(final)\n相似度：\(score)，临时结果 \(volatile.count) 次，定稿 \(sentences.count) 句")
        #expect(score >= 0.8)
    }

    @Test func 取消后事件流结束() async throws {
        let url = try sampleURL()
        let format = try AVAudioFile(forReading: url).processingFormat
        let transcription = SpeechAnalyzerStreamingTranscriber().start(format: format, hotwords: [])
        let collected = Task { for await _ in transcription.events {} }

        transcription.cancel()

        await collected.value
    }
}
