import Foundation
import Testing
@testable import FaymeeCore

/// 纠错文法的契约测试：真实的本机纪要模型（Qwen3.5 4B 等，同 `CatalogMinutesModelContractTests`）在文法约束下
/// 输出能解析、`id` 只在给出的集合里、条数不超过上限。模型不在时跳过；不比较纠错准确率（spec「测试决定」）。
/// 模型根目录可以用 `FAYMEE_CONTRACT_MODELS_DIR` 指到别处
private let modelsDirectory = ProcessInfo.processInfo.environment["FAYMEE_CONTRACT_MODELS_DIR"]
    .map { URL(fileURLWithPath: $0) } ?? LocalModel.defaultDirectory
private let correctionModels = ModelCatalog.builtIn.models(for: .minutes)
    .filter { $0.id != LocalModel.qwen3_4B.id && $0.download?.isDownloaded(in: modelsDirectory) == true }

@Suite(.serialized, .enabled(if: !correctionModels.isEmpty, "需要本机已下载 Qwen3.5 纪要模型"))
struct CorrectionModelContractTests {
    /// 37 句周会里放进几处读音相近的错字词
    private func transcriptWithErrors() throws -> Transcript {
        var t = try weeklyMeetingTranscript()
        let errors = ["s7": ("端到端", "端道的"), "s23": ("延迟", "言辞"), "s28": ("通知", "统治"), "s36": ("讨论", "套论")]
        for (id, (right, wrong)) in errors {
            let s = try #require(t.sentences.first { $0.id == id })
            try #require(s.text.contains(right))
            t.edit(sentence: id, to: s.text.replacingOccurrences(of: right, with: wrong))
            // 当作识别结果，不是人工修改
            let i = try #require(t.sentenceIndex(id))
            guard case var .sentence(edited) = t.items[i] else { continue }
            edited.original = nil
            t.items[i] = .sentence(edited)
        }
        return t
    }

    @Test(arguments: correctionModels.map(\.id))
    func 契约_文法约束下id只在给出的集合里_条数不超过上限(id: String) async throws {
        let entry = try #require(ModelCatalog.builtIn.model(id: id))
        let generator = LlamaTextGenerator(catalogModel: entry, directory: modelsDirectory)
        defer { generator.unload() }
        try await generator.load { _ in }
        let transcript = try transcriptWithErrors()
        // 整场一段（同 App 里本机的分段），只让单号句子可改：双号句子里的错（s28、s36）不能出现在输出里
        let editable = transcript.sentences.map(\.id).enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let lines = transcript.sentences.map { "[\($0.id)] \($0.text)" }
        let output = try await generator.generate(
            system: correctionSystemPrompt(.wordFixes, references: [], speakers: false),
            prompt: correctionPrompt(title: "十一月迭代周会", context: [], lines: lines),
            maxTokens: generator.contextTokens / 4, grammar: wordFixGrammar(ids: editable))
        print("\(id) 纠错输出：\(output)")
        let fixes = try #require(parseWordFixes(output))
        #expect(fixes.allSatisfy { editable.contains($0.id) })
        #expect(fixes.count <= editable.count)
    }

    @Test(arguments: correctionModels.map(\.id))
    func 契约_整场纠错跑通_输出都能解析(id: String) async throws {
        let entry = try #require(ModelCatalog.builtIn.model(id: id))
        let generator = LlamaTextGenerator(catalogModel: entry, directory: modelsDirectory)
        defer { generator.unload() }
        try await generator.load { _ in }
        let started = Date()
        let review = try await correctTranscript(try transcriptWithErrors(), title: "十一月迭代周会",
                                                 hotwords: ["端到端"], method: .wordFixes, generator: generator)
        print("\(id) 纠错 \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒：改了 \(review.texts)，"
              + "建议 \(review.suggestions)，挡掉 \(review.rejections)")
        #expect(review.rejections[CorrectionRule.unparseable.rawValue] == nil)
    }
}
