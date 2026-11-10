import Foundation

/// 文字生成引擎，只负责“给一段提示词，返回一段文字”。分段、提示词、解析、出处校验、合并
/// 都在 FaymeeCore 里（见 `generateMinutes`），与引擎无关。
/// 不叫 LanguageModel，避免和 FoundationModels、MLX 里的同名类型冲突
public protocol TextGenerator {
    /// 一次调用能容纳的输入 + 输出长度（token），决定分段大小。
    /// 应已扣除引擎自己套的对话模板、思考等开销
    var contextTokens: Int { get }
    /// 一段文字的 token 数，用分词器计算。分段时用它保证每段都在预算内
    func countTokens(_ text: String) -> Int
    /// 模型文件是否已下载。未下载时管线不开始，任务保持排队
    var isDownloaded: Bool { get }
    /// 把模型加载进内存，已加载时立即返回。不负责下载
    func load(progress: @escaping (Double) -> Void) async throws
    /// 生成文字，需要支持取消
    func generate(system: String, prompt: String, maxTokens: Int) async throws -> String
    /// 同上，用 `grammar`（llama.cpp 的 GBNF 文法，根规则名 `root`）约束输出的形状。
    /// 纪要生成总是调这个。不支持文法的引擎可以不实现，默认忽略文法、转调上面的版本
    func generate(system: String, prompt: String, maxTokens: Int, grammar: String?) async throws -> String
    /// 释放模型占用的内存
    func unload()
}

extension TextGenerator {
    public func generate(system: String, prompt: String, maxTokens: Int, grammar: String?) async throws -> String {
        try await generate(system: system, prompt: prompt, maxTokens: maxTokens)
    }
}
