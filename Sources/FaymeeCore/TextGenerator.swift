import Foundation

/// 文字生成引擎，只负责“给一段提示词，返回一段文字”。分段、提示词、解析、出处校验、合并
/// 都在 FaymeeCore 里（见 `generateMinutes`），与引擎无关。
/// 不叫 LanguageModel，避免和 FoundationModels、MLX 里的同名类型冲突
public protocol TextGenerator {
    /// 一次调用能容纳的输入 + 输出长度（token），决定分段大小。
    /// 应已扣除引擎自己套的对话模板、思考等开销
    var contextTokens: Int { get }
    /// 单次调用允许的最大输出长度（token），与 `contextTokens` 解耦。
    /// 默认按 `contextTokens / 2` 计算，保持本机模型的既有预算行为
    var maxOutputTokens: Int { get }
    /// 纪要每次调用留多少给输出（随模型的输出习惯定，见 `MinutesChunking`）。默认 `.standard`
    var minutesChunking: MinutesChunking { get }
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
    /// 关掉思考的同一个引擎，给纠错这类机械活用：思考算在输出上限里，会把正文挤成空的。
    /// 本机模型由目录项定（`ModelParameters.thinking`），默认原样返回
    func withThinkingDisabled() -> any TextGenerator
}

extension TextGenerator {
    public var maxOutputTokens: Int { contextTokens / 2 }
    public var minutesChunking: MinutesChunking { .standard }
    public func withThinkingDisabled() -> any TextGenerator { self }

    public func generate(system: String, prompt: String, maxTokens: Int, grammar: String?) async throws -> String {
        try await generate(system: system, prompt: prompt, maxTokens: maxTokens)
    }
}

/// 纪要的分段参数：每次调用的上下文里留多少给输出，其余给系统提示和转写稿（留给提示词的越多，分的段越少）。
/// 和模型的输出习惯有关，由目录项带上（`ModelParameters.minutesChunking`）
public struct MinutesChunking: Sendable, Hashable {
    /// 提取（逐段）和展开会中标注时留给输出的比例
    public var extractionOutput: TokenShare
    /// 合并各段草稿时留给输出的比例
    public var mergeOutput: TokenShare

    public init(extractionOutput: TokenShare, mergeOutput: TokenShare) {
        self.extractionOutput = extractionOutput
        self.mergeOutput = mergeOutput
    }

    /// 按 Qwen3 4B 实测定的比例（ticket 04，见 `Budget`）：提取 2/5，合并 1/2
    public static let standard = MinutesChunking(extractionOutput: TokenShare(2, 5), mergeOutput: TokenShare(1, 2))
}

/// 上下文的几分之几。用整数分子分母，算出的 token 数和原来的 `contextTokens * 2 / 5` 一致，不受浮点误差影响
public struct TokenShare: Sendable, Hashable {
    public var numerator: Int
    public var denominator: Int

    public init(_ numerator: Int, _ denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    public func of(_ tokens: Int) -> Int { tokens * numerator / denominator }
}

/// 去掉模型输出开头的 `<think>…</think>` 推理块，保留后续正文
func stripLeadingThinkBlock(_ text: String) -> String {
    guard let open = text.range(of: "<think>"),
          text[..<open.lowerBound].allSatisfy(\.isWhitespace),
          let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex)
    else { return text }
    return String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
}
