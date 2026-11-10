import Foundation
import Testing
@testable import FaymeeCore

private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 在 `dir` 里放一个指定大小的稀疏文件，冒充模型文件
private func placeFile(_ name: String, size: Int64, in dir: URL) throws {
    let url = dir.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(size))
    try handle.close()
}

struct LlamaTextGeneratorDownloadTests {
    @Test func 模型文件不在约定位置时未下载() throws {
        let dir = try temporaryDirectory()
        #expect(!LlamaTextGenerator(directory: dir).isDownloaded)
    }

    @Test func 文件大小不对时未下载() throws {
        let dir = try temporaryDirectory()
        try placeFile("Qwen3-4B-Q4_K_M.gguf", size: 1_000_000, in: dir)
        #expect(!LlamaTextGenerator(directory: dir).isDownloaded)
    }

    @Test func 文件名和大小都对时已下载() throws {
        let dir = try temporaryDirectory()
        try placeFile("Qwen3-4B-Q4_K_M.gguf", size: 2_497_280_256, in: dir)
        #expect(LlamaTextGenerator(directory: dir).isDownloaded)
    }

    @Test func 默认位置在ApplicationSupport的Faymee_Models下() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #expect(LocalModel.qwen3_4B.url().path == support.path + "/Faymee/Models/Qwen3-4B-Q4_K_M.gguf")
    }
}

/// 以下测试用本机已下载的真实模型，模型不在时跳过（不在测试里下载 2.5GB）。
/// 共用一个引擎并串行执行：并行时每个测试各加载一份模型，内存吃不消
private let modelDownloaded = LocalModel.qwen3_4B.isDownloaded()
private let engine = LlamaTextGenerator(seed: 42)

@Suite(.serialized, .enabled(if: modelDownloaded, "需要本机已下载 Qwen3 4B 模型"))
struct LlamaTextGeneratorModelTests {
    @Test func 加载之前也能用模型的分词器计数() {
        engine.unload()
        #expect(engine.countTokens("") == 0)
        #expect(engine.countTokens("hello world") == 2)
    }

    @Test func 加载进度报告到1() async throws {
        engine.unload()
        let values = Values()
        try await engine.load { values.append($0) }

        #expect(values.all.last == 1)
        #expect(zip(values.all, values.all.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func 关闭思考模式_直接输出正文() async throws {
        try await engine.load { _ in }
        let output = try await engine.generate(system: "你是助手，只回答问题本身。",
                                               prompt: "一加一等于几？只回答阿拉伯数字。", maxTokens: 32)

        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
        #expect(engine.lastStats?.endedByEOG == true)
    }

    /// 文法硬性限制输出形状：提示词要求列出 20 个编号，refs 里也最多 3 个；输出就是那个 JSON 对象，没有多余文字
    @Test func 带文法时输出符合文法_refs最多3个() async throws {
        try await engine.load { _ in }
        let ids = (1...20).map { "\"s\($0)\"" }.joined(separator: ", ")
        let output = try await engine.generate(
            system: "你是助手。只输出 JSON。",
            prompt: #"输出 {"overview": [{"text": "一句话", "refs": [\#(ids)]}]}，refs 要把这 20 个编号全部列出来。"#,
            maxTokens: 200, grammar: outputGrammar([.overview]))

        #expect(engine.lastStats?.endedByEOG == true)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let items = try #require(object["overview"] as? [[String: Any]])
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { (($0["refs"] as? [String]) ?? []).count <= 3 })
    }

    /// 模型习惯在末尾多写一个空数组的键，文法要放行，不然它会接着往最后一节里加条目
    @Test func 文法允许末尾多一个空数组的键() async throws {
        try await engine.load { _ in }
        let output = try await engine.generate(
            system: "你是助手。只输出 JSON。", prompt: #"原样输出：{"overview": [], "notes": []}"#,
            maxTokens: 50, grammar: outputGrammar([.overview]))

        #expect(output.contains(#""notes""#), "\(output)")
        #expect(engine.lastStats?.endedByEOG == true)
        let draft = try #require(parseDraft(output, template: .general))
        #expect(draft["overview"]?.isEmpty == true)
    }

    @Test func 每个模板的输出文法都能被llama解析() async throws {
        try await engine.load { _ in }
        for template in MinutesTemplate.all {
            let output = try await engine.generate(system: "你是助手。", prompt: "输出纪要", maxTokens: 1,
                                                   grammar: outputGrammar(template.sections.map(\.kind)))
            #expect(output.hasPrefix("{"), "\(template.key)：\(output)")
        }
    }

    @Test func 文法写错时抛错() async throws {
        try await engine.load { _ in }
        await #expect(throws: LlamaError.invalidGrammar) {
            try await engine.generate(system: "你是助手。", prompt: "你好", maxTokens: 8, grammar: "root ::= (")
        }
    }

    @Test func 到maxTokens就停() async throws {
        try await engine.load { _ in }
        _ = try await engine.generate(system: "你是助手。", prompt: "从 1 数到 200，用逗号分隔。", maxTokens: 10)

        #expect(engine.lastStats?.outputTokens == 10)
        #expect(engine.lastStats?.endedByEOG == false)
    }

    @Test func 提示词和输出正好填满contextTokens时放得下() async throws {
        try await engine.load { _ in }
        let system = "你是助手。"
        let maxTokens = 8
        let filler = String(repeating: "好", count: 4000)
        // 用分词器把提示词裁到正好 contextTokens - system - maxTokens
        var prompt = filler
        let target = engine.contextTokens - engine.countTokens(system) - maxTokens
        while engine.countTokens(prompt) > target { prompt.removeLast(max(1, (engine.countTokens(prompt) - target) / 2)) }
        #expect(engine.countTokens(system) + engine.countTokens(prompt) + maxTokens <= engine.contextTokens)

        _ = try await engine.generate(system: system, prompt: prompt, maxTokens: maxTokens)
    }

    @Test func 超出上下文时抛错而不是崩溃() async throws {
        try await engine.load { _ in }
        let prompt = String(repeating: "好", count: engine.contextTokens * 2)

        await #expect(throws: LlamaError.self) {
            try await engine.generate(system: "你是助手。", prompt: prompt, maxTokens: 16)
        }
    }

    @Test func 取消后很快抛出CancellationError_之后还能继续用() async throws {
        try await engine.load { _ in }
        let task = Task {
            try await engine.generate(system: "你是助手。", prompt: "写一篇两千字的散文，题目是秋天。", maxTokens: 2000)
        }
        try await Task.sleep(for: .seconds(2))
        let cancelledAt = Date()
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(cancelledAt) < 1)

        let output = try await engine.generate(system: "你是助手，只回答问题本身。",
                                               prompt: "一加一等于几？只回答阿拉伯数字。", maxTokens: 32)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }

    @Test func 处理长提示词时取消_一秒内停下() async throws {
        try await engine.load { _ in }
        // 约 6000 token：一块 2048 的 batch 要一秒多，只有 abort 回调能在块内停下
        let prompt = String(repeating: "大家讨论了项目的进度和下一步的安排。", count: 600)
        let task = Task { try await engine.generate(system: "你是助手。", prompt: prompt, maxTokens: 100) }
        try await Task.sleep(for: .milliseconds(500))
        let cancelledAt = Date()
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(cancelledAt) < 1)
    }

    @Test func unload时排队中还没开始的生成也一并中止() async throws {
        try await engine.load { _ in }
        let first = Task {
            try await engine.generate(system: "你是助手。", prompt: "写一篇两千字的散文，题目是秋天。", maxTokens: 2000)
        }
        try await Task.sleep(for: .seconds(1))
        let queued = Task {
            try await engine.generate(system: "你是助手。", prompt: "写一篇两千字的散文，题目是春天。", maxTokens: 2000)
        }
        try await Task.sleep(for: .milliseconds(200))
        let unloadedAt = Date()
        engine.unload()

        #expect(Date().timeIntervalSince(unloadedAt) < 1)
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await queued.value }
    }

    @Test func 生成中unload_中止生成并释放模型() async throws {
        try await engine.load { _ in }
        let task = Task {
            try await engine.generate(system: "你是助手。", prompt: "写一篇两千字的散文，题目是秋天。", maxTokens: 2000)
        }
        try await Task.sleep(for: .seconds(2))
        let unloadedAt = Date()
        engine.unload()

        #expect(Date().timeIntervalSince(unloadedAt) < 1)
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: LlamaError.notLoaded) {
            try await engine.generate(system: "你是助手。", prompt: "你好", maxTokens: 8)
        }
    }
}

/// 手写的一场 37 句的周会转写稿（Resources/weekly-meeting.txt，每行 `[s12 03:15] 内容`）
func weeklyMeetingTranscript() throws -> Transcript {
    let url = try #require(Bundle.module.url(forResource: "weekly-meeting", withExtension: "txt",
                                             subdirectory: "Resources"))
    let pattern = try Regex(#"\[(s\d+) (\d+):(\d+)\] (.+)"#)
    let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line in
        let m = try #require(line.wholeMatch(of: pattern))
        let start = Double(String(m.output[2].substring!))! * 60 + Double(String(m.output[3].substring!))!
        return (id: String(m.output[1].substring!), start: start, text: String(m.output[4].substring!))
    }
    let sentences = rows.enumerated().map { i, row in
        TranscriptSentence(id: row.id, start: row.start,
                           end: i + 1 < rows.count ? rows[i + 1].start - 0.5 : row.start + 5, text: row.text)
    }
    return Transcript(engine: "apple/speechanalyzer", createdAt: Date(timeIntervalSince1970: 1_794_279_660),
                      hotwords: [], items: sentences.map { .sentence($0) })
}

extension LlamaTextGeneratorModelTests {
    /// 契约测试：02 的生成入口 + 真实引擎
    @Test func 契约_真实模型生成的纪要能解析_出处都存在_各节不全为空() async throws {
        let transcript = try weeklyMeetingTranscript()
        let ids = Set(transcript.sentences.map(\.id))
        try await engine.load { _ in }

        let started = Date()
        let minutes = try await generateMinutes(
            transcript: transcript, title: "十一月迭代周会", startedAt: Date(timeIntervalSince1970: 1_794_276_000),
            template: .general, generator: engine, model: LocalModel.qwen3_4B.id,
            timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        print("契约测试：生成 \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒，\(engine.lastStats.map { "\($0)" } ?? "")")

        // 只断言契约本身；条数、有没有“未找到出处”随采样和提示词变化，只打印出来，质量对比见 ticket 10
        let items = minutes.sections.flatMap(\.items)
        print("契约测试：各节条数 \(minutes.sections.map(\.items.count))，未找到出处 \(items.filter(\.isUnsourced).count) 条")
        #expect(minutes.sections.contains { !$0.items.isEmpty })
        #expect(items.flatMap(\.refs).allSatisfy { ids.contains($0.id) })
        #expect(items.contains { !$0.refs.isEmpty })
    }
}

private final class Values: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ v: Double) { lock.withLock { values.append(v) } }
    var all: [Double] { lock.withLock { values } }
}
