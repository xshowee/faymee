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
private let vadPresent = (try? SileroVAD.check(repoVADModel)) != nil

/// 契约测试：真实 Silero VAD + 已下载的 Qwen3-ASR（~/Library/Application Support/Faymee/Models）走通会后转写。
/// 模型不在时跳过
@Suite(.serialized, .enabled(if: vadPresent && LocalModel.qwen3ASR.isDownloaded(), "需要 Silero VAD 和已下载的 Qwen3-ASR"))
struct Qwen3ASRContractTests {
    /// two-speakers-zh.m4a 的六段话（见 SherpaOnnxDiarizerTests）
    private let truth: [Range<Double>] = [0.00..<8.47, 9.07..<17.43, 18.03..<25.48, 26.08..<33.58, 34.18..<41.22,
                                          41.82..<48.21]

    @Test func 转出关键词_有标点_句子落在对应的那段话里() async throws {
        let model = try #require(ModelCatalog.builtIn.model(id: LocalModel.qwen3ASR.id))
        let transcriber = SherpaOfflineTranscriber.qwen3ASR(model: model, vadModel: repoVADModel)

        let sentences = try await transcriber.transcribe(audio: try resource("two-speakers-zh"), hotwords: []) { _ in }

        let text = sentences.map(\.text).joined()
        for phrase in ["登录模块", "支付模块", "对接接口", "推迟"] {
            #expect(text.contains(phrase), "\(text)")
        }
        #expect(text.contains("。") && text.contains("，"), "\(text)")
        func turn(of phrase: String) -> Int? {
            guard let s = sentences.first(where: { $0.text.contains(phrase) }) else { return nil }
            return truth.firstIndex { $0.lowerBound - 0.3 <= s.start && s.end <= $0.upperBound + 0.3 }
        }
        #expect(turn(of: "登录模块") == 1)
        #expect(turn(of: "支付模块") == 2)
        #expect(turn(of: "对接接口") == 3)
        #expect(zip(sentences, sentences.dropFirst()).allSatisfy { $0.end <= $1.start })
        #expect(Qwen3ASR.engine == LocalModel.qwen3ASR.id)
    }

    @Test func 带热词也能转_热词按tokenizer计数截到预算内() async throws {
        let model = try #require(ModelCatalog.builtIn.model(id: LocalModel.qwen3ASR.id))
        let transcriber = SherpaOfflineTranscriber.qwen3ASR(model: model, vadModel: repoVADModel)
        let sentences = try await transcriber.transcribe(audio: try resource("two-speakers-zh"),
                                                         hotwords: ["登录模块", "支付模块"]) { _ in }
        #expect(sentences.map(\.text).joined().contains("支付模块"))

        let directory = LocalModel.qwen3ASR.directory()
        // 评估用的 8 个热词：Qwen3-ASR 用空格连接，拼起来远小于 150
        let eval = ["DeerFlow", "LangChain", "Harness", "Agent", "智能体", "工具广场", "模型广场", "端到端研发"]
        #expect(try Qwen3ASR.fitHotwords(eval, budget: 150, modelDirectory: directory) == eval)

        let many = (1...200).map { "项目代号\($0)" }
        let fitted = try Qwen3ASR.fitHotwords(many, budget: 150, modelDirectory: directory)
        let counter = try QwenTokenCounter(directory: directory.appendingPathComponent("tokenizer"))
        #expect(fitted == Array(many.prefix(fitted.count)))
        #expect(counter.count(fitted.joined(separator: " ")) <= 150)
        #expect(counter.count((fitted + [many[fitted.count]]).joined(separator: " ")) > 150)
        #expect(fitted.count > 20)
    }
}
