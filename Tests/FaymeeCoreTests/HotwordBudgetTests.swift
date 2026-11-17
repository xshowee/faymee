import Foundation
import Testing
@testable import FaymeeCore

@Suite struct HotwordBudgetTests {
    /// 按字数计的假 tokenizer
    private let characters: (String) -> Int = { $0.count }

    @Test func 按顺序放到预算用完为止_后面的词丢掉() {
        // 拼成「甲乙, 丙丁戊, 己」计数：甲乙 = 2；甲乙, 丙丁戊 = 7；再加 「, 己」= 10
        let words = ["甲乙", "丙丁戊", "己"]
        #expect(HotwordBudget.fit(words, budget: 10, count: characters) == ["甲乙", "丙丁戊", "己"])
        #expect(HotwordBudget.fit(words, budget: 9, count: characters) == ["甲乙", "丙丁戊"])
        #expect(HotwordBudget.fit(words, budget: 1, count: characters) == [])
        #expect(HotwordBudget.fit([], budget: 150, count: characters) == [])
    }

    @Test func 超预算的长词之后的短词不再补进去() {
        // 热词表的顺序就是用户排的优先级：一个放不下就停，不跳过它去塞后面的
        #expect(HotwordBudget.fit(["甲", "很长很长很长的词", "乙"], budget: 6, count: characters) == ["甲"])
    }
}

private let counter = Result { try QwenTokenCounter(directory: LocalModel.funASRNano.directory().appendingPathComponent("Qwen3-0.6B")) }

/// 契约测试：用 Fun-ASR-Nano 自带的 Qwen3 tokenizer（merges.txt）计数，与 Hugging Face tokenizers 0.22 对同一份
/// tokenizer.json 的计数一致。模型没下载时跳过
@Suite(.enabled(if: LocalModel.funASRNano.isDownloaded(), "需要已下载的 Fun-ASR-Nano"))
struct QwenTokenCounterContractTests {
    @Test(arguments: [
        ("DeerFlow", 3), ("LangChain", 2), ("Harness", 1), ("Agent", 1), ("智能体", 2), ("工具广场", 2),
        ("端到端研发", 4),
        ("DeerFlow, LangChain, Harness, Agent, 智能体, 工具广场, 模型广场, 端到端研发", 33),
        ("热词列表：[DeerFlow, LangChain, Harness, Agent, 智能体, 工具广场, 模型广场, 端到端研发]\n", 39),
        ("张三丰, 李四, 王小二, 鑫淼焱垚, 𠀀", 25),
        ("iOS, macOS, GPT-4o, Qwen3-ASR, k8s, 2026年11月", 30),
        ("  hello   world  \n\n x's it'll", 9),
    ])
    func 计数与HuggingFace一致(_ text: String, _ expected: Int) throws {
        #expect(try counter.get().count(text) == expected)
    }
}
