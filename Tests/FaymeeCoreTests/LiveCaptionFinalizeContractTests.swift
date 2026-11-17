import AVFoundation
import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-11T02:00:00Z", strategy: .iso8601)

/// two-speakers-zh.m4a 的第二、三段话（见 SherpaOnnxDiarizerTests）
private let loginTurn = 9.07..<17.43
private let paymentTurn = 18.03..<25.48

private let models: [LocalModel] = [.paraformer, .funASRNano]

/// 契约测试：真实会话 + 真实定稿模型（ticket 01 下载到 ~/Library/Application Support/Faymee/Models）。
/// 流式结果用假引擎按真实的句子时间发，音频是 two-speakers-zh 转成的 16 kHz 块
@MainActor
@Suite(.serialized, .enabled(if: models.allSatisfy { $0.isDownloaded() } && LocalModel.punctuation.isDownloaded(),
                             "需要已下载的 Paraformer、标点模型和 Fun-ASR-Nano"))
struct LiveCaptionFinalizeContractTests {
    private func audio() throws -> [Float] {
        let url = try #require(Bundle.module.url(forResource: "two-speakers-zh", withExtension: "m4a",
                                                 subdirectory: "Resources"))
        return try SherpaOnnxDiarizer.decode(url)
    }

    @Test(arguments: models)
    func 流式句子被定稿模型的结果替换(model: LocalModel) async throws {
        let catalog = ModelCatalog.builtIn
        let finalizer = try #require(LiveCaptionFinalizerModel(selected: catalog.model(id: model.id)))
        let engine = FakeStreamingTranscriber()
        let session = LiveCaptionSession(engine: engine, recordingStartedAt: t0, hotwords: ["支付模块"],
                                         finalizer: finalizer)
        defer { session.stop() }
        func until(_ seconds: Int, _ condition: () -> Bool) async throws {
            for _ in 0..<(seconds * 20) where !condition() { try await Task.sleep(for: .milliseconds(50)) }
            try #require(condition())
        }
        try await until(5) { session.status == .running }

        let samples = try audio()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        for start in stride(from: 0, to: samples.count, by: 1600) {
            let count = min(1600, samples.count - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { buffer.floatChannelData![0][i] = samples[start + i] }
            session.append(buffer, at: t0.addingTimeInterval(Double(start) / 16000))
        }
        engine.last.sentence(loginTurn.lowerBound, loginTurn.upperBound, "流式一。")
        engine.last.sentence(paymentTurn.lowerBound, paymentTurn.upperBound, "流式二。")

        var texts: [String] { session.lines.compactMap { if case .sentence(let s) = $0 { s.text } else { nil } } }
        // 加载大模型要几秒
        try await until(60) { texts.count == 2 && !texts.contains { $0.hasPrefix("流式") } }
        #expect(texts[0].contains("登录模块"))
        #expect(texts[1].contains("支付模块"))
    }

    /// 刚开始加载就结束（录音刚开始就停）：加载完就释放，App 退出前等得到
    @Test(arguments: models)
    func 加载中结束时加载完就释放(model: LocalModel) async throws {
        let finalizer = try #require(LiveCaptionFinalizerModel(selected: ModelCatalog.builtIn.model(id: model.id)))
        let worker = SentenceFinalizer(model: finalizer, hotwords: [])
        worker.submit(id: 1, samples: [Float](repeating: 0, count: 16000))
        // 等它开始加载（Paraformer 约 0.6 秒加载完）
        try await Task.sleep(for: .milliseconds(150))
        let cancelled = Date()
        worker.cancel()

        #expect(SherpaStreamingTranscriber.waitUntilReleased(timeout: 30))
        print("定稿模型 \(model.id) 取消后 \(Date().timeIntervalSince(cancelled)) 秒释放")
        var results = 0
        for await _ in worker.results { results += 1 }
        #expect(results == 0)
    }
}
