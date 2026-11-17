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

private func twoSpeakersURL() throws -> URL {
    try #require(Bundle.module.url(forResource: "two-speakers-zh", withExtension: "m4a", subdirectory: "Resources"))
}

/// 把录音切成约 0.1 秒一块、按文件原样的格式送入（24 kHz，格式转换一并测到），返回收到的全部事件，
/// 以及调用 finish() 之前已收到的事件。pace 是每块之间等多久（真实会议是 0.1 秒；识别器不看墙钟，测试可以送快些）
private func stream(_ url: URL, into transcription: any StreamingTranscription,
                    pace: Duration = .milliseconds(20)) async throws
    -> (all: [StreamingTranscriptionEvent], beforeFinish: [StreamingTranscriptionEvent]) {
    let file = try AVAudioFile(forReading: url)
    let received = Received()
    let collected = Task {
        for await event in transcription.events { received.append(event) }
    }
    let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
    while file.framePosition < file.length {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk))
        let position = Double(file.framePosition) / file.processingFormat.sampleRate
        try file.read(into: buffer, frameCount: chunk)
        transcription.append(buffer, at: position)
        try await Task.sleep(for: pace)
    }
    // 让识别器跟上，再看结束前收到了什么
    try await Task.sleep(for: .milliseconds(500))
    let beforeFinish = received.all
    transcription.finish()
    await collected.value
    return (received.all, beforeFinish)
}

private let xASRDownloaded = LocalModel.xASR480.isDownloaded() && LocalModel.xASR960.isDownloaded()

/// 契约测试：真实 X-ASR 模型（ticket 01 下载到 Application Support 的那份）。模型不在本机时跳过
@Suite(.serialized, .enabled(if: xASRDownloaded, "需要本机已下载 X-ASR 480ms / 960ms 模型（设置 › 实时字幕）"))
struct SherpaStreamingTranscriberContractTests {
    @Test(arguments: [LocalModel.xASR480, LocalModel.xASR960])
    func 按0点1秒一块送入_出临时文字和定稿句子_时间单调(model: LocalModel) async throws {
        let url = try twoSpeakersURL()
        let length = try duration(of: url)
        let engine = SherpaStreamingTranscriber(model: model)
        try await engine.prepare { _ in }
        let format = try AVAudioFile(forReading: url).processingFormat

        let (events, beforeFinish) = try await stream(url, into: engine.start(format: format, hotwords: []))

        let failures = events.compactMap { if case .failed(let reason) = $0 { reason } else { nil } }
        #expect(failures.isEmpty)
        // 边说边出：送完之前就有临时文字和定稿句子（句间有 0.6 秒停顿，尾部静音 0.6 秒定稿）
        #expect(beforeFinish.contains { if case .volatile(let text, _) = $0 { !text.isEmpty } else { false } })
        #expect(beforeFinish.contains { if case .sentence = $0 { true } else { false } })
        let sentences = events.compactMap { if case .sentence(let s) = $0 { s } else { nil } }
        #expect(sentences.count >= 3)
        #expect(sentences.allSatisfy { !$0.text.isEmpty })
        #expect(sentences.allSatisfy { 0 <= $0.start && $0.start <= $0.end && $0.end <= length + 0.5 })
        #expect(zip(sentences, sentences.dropFirst()).allSatisfy { $0.end <= $1.start })
        // 临时文字的开头时间也不倒退
        let volatileStarts = events.compactMap { if case .volatile(let t, let start) = $0, !t.isEmpty { start } else { nil } }
        #expect(volatileStarts.allSatisfy { 0 <= $0 && $0 <= length + 0.5 })

        let text = sentences.map(\.text).joined()
        print("\(model.id)：\(sentences.map { String(format: "[%.2f–%.2f] ", $0.start, $0.end) + $0.text }.joined(separator: "\n"))")
        // 自带标点；两人说的关键词转得出来（合成语音 Eddy 的「支付模块」SpeechAnalyzer 转不对）
        #expect(text.contains { "，。？！".contains($0) })
        #expect(text.contains("登录模块"))
    }

    /// 时间按送入时带的时间换算：整体往后挪 100 秒送入，句子也都在 100 秒之后
    @Test func 送入的时间整体偏移时_句子时间跟着偏移() async throws {
        let url = try twoSpeakersURL()
        let length = try duration(of: url)
        let engine = SherpaStreamingTranscriber(model: .xASR480)
        let file = try AVAudioFile(forReading: url)
        let transcription = engine.start(format: file.processingFormat, hotwords: [])
        let received = Received()
        let collected = Task { for await event in transcription.events { received.append(event) } }
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        while file.framePosition < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk))
            let position = Double(file.framePosition) / file.processingFormat.sampleRate
            try file.read(into: buffer, frameCount: chunk)
            transcription.append(buffer, at: 100 + position)
        }
        transcription.finish()
        await collected.value

        let sentences = received.all.compactMap { if case .sentence(let s) = $0 { s } else { nil } }
        #expect(!sentences.isEmpty)
        #expect(sentences.allSatisfy { 100 <= $0.start && $0.end <= 100 + length + 0.5 })
    }

    @Test func 带热词也能转() async throws {
        let url = try twoSpeakersURL()
        let engine = SherpaStreamingTranscriber(model: .xASR480)
        let format = try AVAudioFile(forReading: url).processingFormat

        let (events, _) = try await stream(url, into: engine.start(format: format, hotwords: ["对接接口", "提测", "飞书", "LangChain"]),
                                           pace: .zero)

        let failures = events.compactMap { if case .failed(let reason) = $0 { reason } else { nil } }
        #expect(failures.isEmpty)
        let text = events.compactMap { if case .sentence(let s) = $0 { s.text } else { nil } }.joined()
        print("带热词：\(text)")
        #expect(text.contains("登录模块"))
    }

    @Test func 取消后事件流尽快结束() async throws {
        let url = try twoSpeakersURL()
        let file = try AVAudioFile(forReading: url)
        let transcription = SherpaStreamingTranscriber(model: .xASR480).start(format: file.processingFormat, hotwords: [])
        let collected = Task { for await _ in transcription.events {} }
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        for _ in 0..<50 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk))
            try file.read(into: buffer, frameCount: chunk)
            transcription.append(buffer, at: 0)
        }
        let started = ContinuousClock.now

        transcription.cancel()

        await collected.value
        #expect(ContinuousClock.now - started < .milliseconds(200))
        // 识别器可能还在加载（取消打断不了 sherpa-onnx 的加载，加载完立即释放）。
        // 测试进程在加载中途退出会让 onnxruntime 崩在已析构的全局表上，等它加载完再结束
        try await Task.sleep(for: .seconds(3))
    }
}

/// 模型文件不全时不交给 sherpa-onnx（坏模型会让它 `_Exit` 整个进程）
struct SherpaStreamingTranscriberModelTests {
    @Test func 模型没下载时_准备抛错_开始转写发出failed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = SherpaStreamingTranscriber(model: .xASR480, directory: dir)

        await #expect(throws: (any Error).self) { try await engine.prepare { _ in } }

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let transcription = engine.start(format: format, hotwords: [])
        var events: [StreamingTranscriptionEvent] = []
        for await event in transcription.events { events.append(event) }
        #expect(events.count == 1)
        if case .failed(let reason) = events.first { #expect(reason.contains("模型")) } else {
            Issue.record("应发出 .failed")
        }
    }
}

/// sherpa-onnx 在线识别结果（JSON）怎么变成句子。样例取自 X-ASR 480ms 转 two-speakers-zh.m4a 的真实输出（节选）
struct OnlineResultTests {
    private func result(_ tokens: [(String, Double)], start: Double) throws -> OnlineResult {
        let json: [String: Any] = ["text": tokens.map(\.0).joined(), "tokens": tokens.map(\.0),
                                   "timestamps": tokens.map(\.1), "start_time": start]
        return try OnlineResult(json: JSONSerialization.data(withJSONObject: json))
    }

    @Test func 按句末标点分句_去掉中文前后的空格_时间取各句首尾的字() throws {
        let r = try result([(" 大", 0.48), (" 家", 0.6), (" 好", 0.92), (" ，", 1.16), (" 今", 1.52), (" 天", 1.72),
                            (" 。", 2.4), (" 首", 2.5), (" 先", 2.7), (" ？", 3.2), (" 好", 3.5), (" 的", 3.8)],
                           start: 10)

        #expect(r.text == "大家好，今天。首先？好的")
        #expect(r.start == 10.48)
        let sentences = r.sentences(limit: 100)
        #expect(sentences.map(\.text) == ["大家好，今天。", "首先？", "好的"])
        #expect(sentences.map(\.start) == [10.48, 12.5, 13.5])
        // 结束取最后一个字再加 0.3 秒（字的时间只是被识别出的那一帧），不超过下一句开头
        #expect(abs(sentences[0].end - 12.02) < 1e-9)
        #expect(abs(sentences[1].end - 13.0) < 1e-9)
        #expect(abs(sentences[2].end - 14.1) < 1e-9)
    }

    /// 上一句说完（endpoint）后识别器才补出它的句号，落在下一段的开头：归上一句，这一句不要它
    @Test func 开头的标点不算这一句() throws {
        let r = try result([(" 。", 0), (" 那", 0.12), (" 支", 0.48), (" 付", 0.6)], start: 18.24)

        #expect(r.text == "那支付")
        #expect(abs(r.start - 18.36) < 1e-9)
        #expect(r.sentences(limit: 100).map(\.text) == ["那支付"])
    }

    @Test func 英文单词之间保留空格_结束时间不超过已送入的音频() throws {
        let r = try result([(" 用", 1.0), (" Lang", 1.2), ("Chain", 1.4), (" and", 1.6), (" Agent", 1.8), (" 吧", 2.0)],
                           start: 0)

        #expect(r.text == "用LangChain and Agent吧")
        #expect(r.sentences(limit: 2.1).map(\.end) == [2.1])
    }

    @Test func 只有标点或空结果时没有句子() throws {
        #expect(try result([(" 。", 0)], start: 5).sentences(limit: 100).isEmpty)
        #expect(try result([], start: 5).text.isEmpty)
    }
}

struct OnlineRecognizerHotwordTests {
    /// X-ASR 的词表里汉字是一个个“▁字”，热词里的汉字要分开，英文单词保持整词
    @Test func 热词里的汉字分开_英文单词不拆() {
        #expect(OnlineRecognizer.spacedForBPE("支付模块") == "支 付 模 块")
        #expect(OnlineRecognizer.spacedForBPE("LangChain 智能体") == "LangChain 智 能 体")
        #expect(OnlineRecognizer.spacedForBPE("A/B测试") == "A B 测 试")
    }
}
