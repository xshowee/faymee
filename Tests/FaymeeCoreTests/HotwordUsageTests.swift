import Foundation
import Testing
@testable import FaymeeCore

/// 热词页上关于会后转写所选模型的提示：模型不用热词表、热词超出预算
@Suite struct HotwordUsageTests {
    private let catalog = ModelCatalog.builtIn
    private let empty = FileManager.default.temporaryDirectory.appendingPathComponent("FaymeeHotwordUsage-\(UUID().uuidString)")

    @Test(arguments: [ModelCatalog.speechAnalyzerID, LocalModel.paraformer.id])
    func 不支持热词的模型说明不使用热词表(_ id: String) throws {
        let model = try #require(catalog.model(id: id))
        let usage = HotwordUsage(model: model, hotwords: ["登录模块"], modelDirectory: empty)
        #expect(usage == .unused(model: model.name))
        #expect(usage.note == "当前模型（\(model.name)）不使用热词表")
    }

    @Test func 支持热词但模型没下载时算不了预算_不提示() throws {
        let model = try #require(catalog.model(id: LocalModel.funASRNano.id))
        let usage = HotwordUsage(model: model, hotwords: ["登录模块"], modelDirectory: empty)
        #expect(usage == .unknown)
        #expect(usage.note == nil)
    }

    @Test func 超出预算时说明只用得上前几个() {
        #expect(HotwordUsage.partial(model: "Fun-ASR-Nano", used: 30, total: 42).note
                == "热词太多：当前模型（Fun-ASR-Nano）只用得上前 30 个，后面 12 个不生效")
        #expect(HotwordUsage.all.note == nil)
    }
}

/// 用 Fun-ASR-Nano 自带的 tokenizer 实际计数。模型没下载时跳过
@Suite(.enabled(if: LocalModel.funASRNano.isDownloaded(), "需要已下载的 Fun-ASR-Nano"))
struct HotwordUsageContractTests {
    /// 这 8 个词拼成的列表是 33 个 token（见 QwenTokenCounterContractTests）
    private let words = ["DeerFlow", "LangChain", "Harness", "Agent", "智能体", "工具广场", "模型广场", "端到端研发"]

    private func funASRNano(budget: Int) -> CatalogModel {
        let m = ModelCatalog.builtIn.model(id: LocalModel.funASRNano.id)!
        return CatalogModel(id: m.id, roles: m.roles, family: m.family, source: m.source, name: m.name,
                            capabilities: m.capabilities,
                            parameters: ModelParameters(contextTokens: 512, hotwordTokenBudget: budget))
    }

    @Test func 预算内全部生效_超出时只用得上前面的() {
        let dir = LocalModel.defaultDirectory
        #expect(HotwordUsage(model: funASRNano(budget: 33), hotwords: words, modelDirectory: dir) == .all)
        #expect(HotwordUsage(model: funASRNano(budget: 33), hotwords: words + ["多余"], modelDirectory: dir)
                == .partial(model: "Fun-ASR-Nano", used: 8, total: 9))
    }
}

/// 用 Qwen3-ASR 自带的 tokenizer 实际计数（热词用空格连接）。模型没下载时跳过
@Suite(.enabled(if: LocalModel.qwen3ASR.isDownloaded(), "需要已下载的 Qwen3-ASR"))
struct HotwordUsageQwen3ASRContractTests {
    /// 这 8 个词用空格连接是 26 个 token（与 sherpa 的 debug 日志一致，见 ticket 05）
    private let words = ["DeerFlow", "LangChain", "Harness", "Agent", "智能体", "工具广场", "模型广场", "端到端研发"]

    private func qwen3ASR(budget: Int) -> CatalogModel {
        let m = ModelCatalog.builtIn.model(id: LocalModel.qwen3ASR.id)!
        return CatalogModel(id: m.id, roles: m.roles, family: m.family, source: m.source, name: m.name,
                            capabilities: m.capabilities, parameters: ModelParameters(hotwordTokenBudget: budget))
    }

    @Test func 预算内全部生效_超出时只用得上前面的() {
        let dir = LocalModel.defaultDirectory
        #expect(HotwordUsage(model: qwen3ASR(budget: 26), hotwords: words, modelDirectory: dir) == .all)
        #expect(HotwordUsage(model: qwen3ASR(budget: 26), hotwords: words + ["多余"], modelDirectory: dir)
                == .partial(model: "Qwen3-ASR", used: 8, total: 9))
    }
}
