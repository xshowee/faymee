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

@Suite struct FunASRNanoHotwordTests {
    @Test func 热词里的分隔符换成空格_免得sherpa把一个词拆开() {
        #expect(SherpaHotwords.sanitize(["A,B", "张三；李四", " 智能体 ", "", "，"]) == ["A B", "张三 李四", "智能体"])
    }
}

/// 契约测试：真实 Silero VAD + 已下载的 Fun-ASR-Nano（~/Library/Application Support/Faymee/Models）走通会后转写。
/// 模型不在时跳过
@Suite(.serialized, .enabled(if: vadPresent && LocalModel.funASRNano.isDownloaded(), "需要 Silero VAD 和已下载的 Fun-ASR-Nano"))
struct FunASRNanoContractTests {
    /// two-speakers-zh.m4a 的六段话（见 SherpaOnnxDiarizerTests）
    private let truth: [Range<Double>] = [0.00..<8.47, 9.07..<17.43, 18.03..<25.48, 26.08..<33.58, 34.18..<41.22,
                                          41.82..<48.21]

    @Test func 转出关键词_有标点_句子落在对应的那段话里() async throws {
        let model = try #require(ModelCatalog.builtIn.model(id: LocalModel.funASRNano.id))
        let loader = try #require(SegmentRecognizerLoader(model: model))
        let transcriber = SherpaOfflineTranscriber(loader: loader, vadModel: repoVADModel)

        // 不给热词：关键词要靠模型自己认出来（热词路径见下面的预算测试）
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
    }

    @Test func 热词按tokenizer计数截到预算内() throws {
        let directory = LocalModel.funASRNano.directory()
        let fitting = try #require(SegmentRecognizerAdapter.funASRNano.hotwordFitting)
        // 8 个评估用的热词拼起来 33 token（Hugging Face tokenizers 计数），预算 150 放得下
        let eval = ["DeerFlow", "LangChain", "Harness", "Agent", "智能体", "工具广场", "模型广场", "端到端研发"]
        #expect(try fitting.fit(eval, budget: 150, modelDirectory: directory) == eval)
        #expect(try fitting.fit(eval, budget: 32, modelDirectory: directory) == Array(eval.prefix(7)))

        // 一长串：截到 150 以内，且再多放一个就超
        let many = (1...200).map { "项目代号\($0)" }
        let fitted = try fitting.fit(many, budget: 150, modelDirectory: directory)
        let counter = try QwenTokenCounter(directory: directory.appendingPathComponent("Qwen3-0.6B"))
        #expect(fitted == Array(many.prefix(fitted.count)))
        #expect(counter.count(fitted.joined(separator: ", ")) <= 150)
        #expect(counter.count((fitted + [many[fitted.count]]).joined(separator: ", ")) > 150)
        #expect(fitted.count > 20)
    }
}
