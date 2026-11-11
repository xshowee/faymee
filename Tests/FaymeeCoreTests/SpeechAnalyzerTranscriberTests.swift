import AVFoundation
import Foundation
import Speech
import Testing
@testable import FaymeeCore

/// 契约测试：用一段几秒的真实中文录音跑系统语音识别。
/// 依赖本机已下载的中文语音资源，不在时跳过（不在测试里下载，避免测试联网、耗时数分钟）
func chineseAssetsInstalled() async -> Bool {
    guard SpeechTranscriber.isAvailable,
          let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN"))
    else { return false }
    // status(forModules:) 在资源已装好但本进程未登记时也会报 .supported，不可靠；
    // 安装请求为 nil 才表示无需下载
    let module = SpeechTranscriber(locale: locale, preset: .transcription)
    return (try? await AssetInventory.assetInstallationRequest(supporting: [module])) == nil
}

func sampleURL() throws -> URL {
    try #require(Bundle.module.url(forResource: "zh-sample", withExtension: "m4a", subdirectory: "Resources"))
}

func duration(of url: URL) throws -> TimeInterval {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.processingFormat.sampleRate
}

@Suite(.enabled("需要本机已下载中文语音资源", { await chineseAssetsInstalled() }))
struct SpeechAnalyzerTranscriberContractTests {
    @Test func 输出非空且时间单调递增并在录音时长之内() async throws {
        let url = try sampleURL()
        let length = try duration(of: url)
        let engine = SpeechAnalyzerTranscriber()
        try await engine.prepare { _ in }

        let sentences = try await engine.transcribe(audio: url, hotwords: ["飞书"]) { _ in }

        #expect(!sentences.isEmpty)
        #expect(sentences.allSatisfy { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(sentences.allSatisfy { 0 <= $0.start && $0.start <= $0.end && $0.end <= length })
        #expect(zip(sentences, sentences.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    @Test func 按句输出而不是整段一行() async throws {
        // 样本念的是两句话，引擎只给出一段结果
        let sentences = try await SpeechAnalyzerTranscriber().transcribe(audio: try sampleURL(), hotwords: []) { _ in }

        #expect(sentences.count >= 2)
    }

    @Test func 取消后抛出CancellationError() async throws {
        let url = try sampleURL()
        let task = Task { try await SpeechAnalyzerTranscriber().transcribe(audio: url, hotwords: []) { _ in } }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// 识别结果里每一小段文字的时间。个别片段（如引擎补的标点）可能没有 audioTimeRange
@Suite struct 逐字时间 {
    private func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600))
    }

    @Test func 有时间的片段用自己的时间() {
        let token = SpeechAnalyzerTranscriber.token("好", range: range(1.25, 1.5),
                                                    previous: nil, result: range(0, 20), length: 60)
        #expect(token == TimedToken(text: "好", start: 1.25, end: 1.5))
    }

    /// 不能用整段结果的时间：那会让这个字横跨约 20 秒，断句、合盖空白判断和高亮都会错
    @Test func 没有时间的片段紧接前一个字_长度为零() {
        let previous = TimedToken(text: "好", start: 1.25, end: 1.5)
        let token = SpeechAnalyzerTranscriber.token("。", range: nil,
                                                    previous: previous, result: range(0, 20), length: 60)
        #expect(token == TimedToken(text: "。", start: 1.5, end: 1.5))
    }

    @Test func 段首没有时间的片段放在这段结果开头_长度为零() {
        let token = SpeechAnalyzerTranscriber.token("嗯", range: nil,
                                                    previous: nil, result: range(20, 40), length: 60)
        #expect(token == TimedToken(text: "嗯", start: 20, end: 20))
    }

    @Test func 时间不超过录音时长() {
        let token = SpeechAnalyzerTranscriber.token("好", range: range(59.75, 60.5),
                                                    previous: nil, result: range(40, 60.5), length: 60)
        #expect(token == TimedToken(text: "好", start: 59.75, end: 60))
    }
}
