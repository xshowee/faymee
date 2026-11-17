import Foundation
import Testing
@testable import FaymeeCore

private func resource(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "m4a", subdirectory: "Resources"))
}

/// 仓库里打进 App 的静音切段模型（scripts/fetch-vad-model.sh 下载，被 git 忽略）
private let repoVADModel = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/VAD/silero_vad.onnx")

/// two-speakers-zh.m4a 的六段话（见 SherpaOnnxDiarizerTests）
private let truth: [Range<Double>] = [0.00..<8.47, 9.07..<17.43, 18.03..<25.48, 26.08..<33.58, 34.18..<41.22,
                                      41.82..<48.21]

@Suite struct ParaformerRecognizerModelTests {
    @Test func 模型文件缺了不加载_报缺哪个文件() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: SherpaModelError.missing(model: "Paraformer", file: "model.int8.onnx")) {
            try ParaformerRecognizer(modelDirectory: root)
        }
    }
}

/// 契约测试：真实 Paraformer + 标点模型（ticket 01 下载到 ~/Library/Application Support/Faymee/Models）
@Suite(.serialized, .enabled(if: LocalModel.paraformer.isDownloaded() && LocalModel.punctuation.isDownloaded(),
                             "需要已下载的 Paraformer 和标点模型"))
struct ParaformerContractTests {
    @Test func 单句音频直接识别_有标点_逐字时间对得上文字() throws {
        // 实时字幕定稿的用法：不切段，直接把一句话的音频交给识别器
        let samples = try SherpaOnnxDiarizer.decode(try resource("two-speakers-zh"))
        let recognizer = try ParaformerRecognizer()

        let result = try recognizer.recognize(samples[0..<Int(truth[0].upperBound * 16000)])

        #expect(result.text.hasPrefix("大家好，"))
        #expect(result.text.contains("产品规划。"))
        // 逐字时间要能和最终文字（加了标点）逐字对上，不然句子时间会悄悄退回按字数估算
        let tokens = try #require(result.tokens)
        let content = result.text.filter { !$0.isWhitespace && !$0.isPunctuation }
        let starts = try #require(SentenceAssembly.align(Array(content), to: tokens))
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test(.enabled(if: (try? SileroVAD.check(repoVADModel)) != nil, "需要 Silero VAD"))
    func 会后转写_关键词在对应的那段话里_有标点_句子时间单调() async throws {
        let transcriber = SherpaOfflineTranscriber.paraformer(vadModel: repoVADModel)

        let sentences = try await transcriber.transcribe(audio: try resource("two-speakers-zh"),
                                                         hotwords: ["忽略"]) { _ in }

        func turn(of phrase: String) -> Int? {
            guard let s = sentences.first(where: { $0.text.contains(phrase) }) else { return nil }
            return truth.firstIndex { $0.lowerBound - 0.3 <= s.start && s.end <= $0.upperBound + 0.3 }
        }
        #expect(turn(of: "登录模块") == 1)
        #expect(turn(of: "支付模块") == 2)
        #expect(turn(of: "对接接口") == 3)
        #expect(sentences.filter { $0.text.contains("，") }.count >= 4)
        #expect(sentences.allSatisfy { $0.text.last.map { "。？！".contains($0) } ?? false })
        #expect(sentences.allSatisfy { $0.start < $0.end })
        #expect(zip(sentences, sentences.dropFirst()).allSatisfy { $0.end <= $1.start })
    }
}
