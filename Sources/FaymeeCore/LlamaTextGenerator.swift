import Foundation
import llama
import os

/// 用 llama.cpp 在本机跑 GGUF 模型（目前是 Qwen3 4B，Metal 全部层放 GPU）的 `TextGenerator`。
///
/// - 对话模板手写 ChatML，并在 assistant 开头预填空的 `<think>` 块，等价于 Qwen3 官方模板的
///   `enable_thinking=false`：关闭思考，输出直接是正文
/// - 阻塞的 llama.cpp 调用都在一条专用的串行队列上跑，不占 Swift 并发的线程池；同一时间只有一个
///   `load` 或 `generate` 在跑，其余排队
/// - 取消：`generate`、`load` 所在的 Task 被取消，或调用 `unload()`，都会让正在跑的 llama.cpp 调用
///   尽快停下（prompt 阶段每个 ubatch 检查一次，约 0.2–0.5 秒；生成阶段每个 token 检查一次），
///   并抛出 `CancellationError`
public final class LlamaTextGenerator: TextGenerator, @unchecked Sendable {
    public let model: LocalModel
    public let directory: URL

    /// 实际开的上下文长度（llama.cpp 的 n_ctx）。8192 时 KV cache 约 1.1GB，进程 footprint 约 1.4GB
    /// （权重 2.3GB 是 mmap 的，不算在内）；16384 约 2.6GB，32768 约 5GB
    public static let defaultContextLength = 8192

    /// 对话模板（ChatML 标记、角色名、预填的空 think 块）占的 token，`contextTokens` 已扣除。
    /// 实际约 20 个，留些余量
    static let templateReserve = 32

    /// 固定时每次调用用 `seed + 调用次数`，可复现又不让“解析失败重试”拿到同一份输出；nil 时随机
    let seed: UInt32?
    let contextLength: Int
    var sampling = Sampling()

    /// 上一次 `generate` 的统计，调优和测试用
    private(set) var lastStats: Stats?

    // 模型指针。改动（加载、释放）在 `queue` 上并持有 `lock`；`countTokens` 在任意线程持有 `lock` 读取
    private let lock = NSLock()
    private var llamaModel: OpaquePointer?
    private var context: OpaquePointer?
    /// 只含词表的模型，给 `load` 之前的 `countTokens` 用（约 80 毫秒、60MB）
    private var vocabModel: OpaquePointer?

    private let queue = DispatchQueue(label: "com.faymee.llama", qos: .utility)
    /// 当前在 `queue` 上跑的那次调用的取消标志，llama.cpp 的 abort 回调读它
    private let running = RunningCall()
    private var calls: UInt32 = 0

    public convenience init(model: LocalModel = .qwen3_4B, directory: URL = LocalModel.defaultDirectory) {
        self.init(model: model, directory: directory, seed: nil)
    }

    init(model: LocalModel = .qwen3_4B, directory: URL = LocalModel.defaultDirectory,
         contextLength: Int = LlamaTextGenerator.defaultContextLength, seed: UInt32?) {
        self.model = model
        self.directory = directory
        self.contextLength = contextLength
        self.seed = seed
        liveEngines.add(self)
    }

    deinit { free() }

    public var contextTokens: Int { contextLength - Self.templateReserve }

    public var isDownloaded: Bool { model.isDownloaded(in: directory) }

    /// 用模型的分词器计数（不加 BOS、不解析特殊 token）。模型还没加载时只加载词表；
    /// 模型文件不在时按字数估算（中文偏多，英文偏多很多），只会让分段偏保守
    public func countTokens(_ text: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if llamaModel == nil, vocabModel == nil, isDownloaded {
            Self.initializeBackend
            var params = llama_model_default_params()
            params.vocab_only = true
            vocabModel = llama_model_load_from_file(model.url(in: directory).path, params)
        }
        guard let m = llamaModel ?? vocabModel else { return text.count }
        return tokenize(text, vocab: llama_model_get_vocab(m), parseSpecial: false).count
    }

    public func load(progress: @escaping (Double) -> Void) async throws {
        try await run { call in try self.loadSync(call, progress: progress) }
    }

    public func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        try await run { call in try self.generateSync(call, system: system, prompt: prompt, maxTokens: maxTokens) }
    }

    /// 释放模型、上下文和词表。正在跑和排队中的 `load`/`generate` 都会被中止（抛 `CancellationError`），
    /// 等正在跑的那次停下后才释放，所以可能阻塞零点几秒
    public func unload() {
        running.cancelAll()
        queue.sync { free() }
    }

    // MARK: - 队列上的同步实现

    /// 在 `queue` 上执行 `body`；所在 Task 被取消时置取消标志
    private func run<T>(_ body: @escaping (Call) throws -> T) async throws -> T {
        let call = Call()
        running.add(call)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.running.begin(call)
                    defer { self.running.end(call) }
                    continuation.resume(with: Result {
                        if call.isCancelled { throw CancellationError() }
                        return try body(call)
                    })
                }
            }
        } onCancel: {
            call.cancel()
        }
    }

    private func loadSync(_ call: Call, progress: @escaping (Double) -> Void) throws {
        if context != nil { return }
        guard isDownloaded else { throw LlamaError.modelNotDownloaded }
        Self.initializeBackend

        let reporter = LoadProgress(call: call, report: progress)
        var mp = llama_model_default_params()
        mp.n_gpu_layers = -1
        mp.progress_callback = { value, data in
            let reporter = Unmanaged<LoadProgress>.fromOpaque(data!).takeUnretainedValue()
            reporter.report(Double(value))
            return !reporter.call.isCancelled
        }
        mp.progress_callback_user_data = Unmanaged.passUnretained(reporter).toOpaque()
        let m = withExtendedLifetime(reporter) { llama_model_load_from_file(model.url(in: directory).path, mp) }
        guard let m else {
            if call.isCancelled { throw CancellationError() }
            throw LlamaError.loadFailed
        }

        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(contextLength)
        cp.n_batch = 2048
        cp.n_ubatch = 512
        cp.abort_callback = { data in
            Unmanaged<RunningCall>.fromOpaque(data!).takeUnretainedValue().isCancelled
        }
        cp.abort_callback_data = Unmanaged.passUnretained(running).toOpaque()
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw LlamaError.outOfMemory
        }
        lock.withLock {
            if let v = vocabModel { llama_model_free(v) }
            vocabModel = nil
            llamaModel = m
            context = c
        }
        Self.unloadAtExit
        progress(1)
    }

    private func generateSync(_ call: Call, system: String, prompt: String, maxTokens: Int) throws -> String {
        guard let ctx = context, let m = llamaModel else { throw LlamaError.notLoaded }
        let vocab = llama_model_get_vocab(m)
        // 模板标记按特殊 token 解析，内容按普通文字切：转写稿里出现 "<|im_end|>" 字样也不会被当成标记，
        // 而且总长正好是模板开销 + 两次 countTokens，和管线的预算对得上
        var tokens = tokenize("<|im_start|>system\n", vocab: vocab, parseSpecial: true)
        tokens += tokenize(system, vocab: vocab, parseSpecial: false)
        tokens += tokenize("<|im_end|>\n<|im_start|>user\n", vocab: vocab, parseSpecial: true)
        tokens += tokenize(prompt, vocab: vocab, parseSpecial: false)
        tokens += tokenize("<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n", vocab: vocab, parseSpecial: true)
        guard tokens.count + maxTokens <= Int(llama_n_ctx(ctx)) else {
            throw LlamaError.promptTooLong(tokens: tokens.count, maxTokens: maxTokens)
        }

        var stats = Stats(promptTokens: tokens.count)
        let start = Date()
        llama_memory_clear(llama_get_memory(ctx), true) // 每次调用都是独立的一轮对话
        let sampler = makeSampler(vocab: vocab)
        defer { llama_sampler_free(sampler) }

        let batchSize = Int(llama_n_batch(ctx))
        var i = 0
        while i < tokens.count {
            if call.isCancelled { throw CancellationError() }
            let n = min(batchSize, tokens.count - i)
            let rc = tokens.withUnsafeMutableBufferPointer {
                llama_decode(ctx, llama_batch_get_one($0.baseAddress! + i, Int32(n)))
            }
            try check(rc)
            i += n
        }
        stats.promptSeconds = Date().timeIntervalSince(start)

        var bytes: [UInt8] = []
        while stats.outputTokens < maxTokens {
            if call.isCancelled { throw CancellationError() }
            var token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { stats.endedByEOG = true; break }
            bytes += piece(token, vocab: vocab)
            stats.outputTokens += 1
            try check(llama_decode(ctx, llama_batch_get_one(&token, 1)))
        }
        stats.totalSeconds = Date().timeIntervalSince(start)
        lastStats = stats
        // 中文一个字可能拆在两个 token 里，所以先攒字节、最后再解码
        return Self.stripThink(String(decoding: bytes, as: UTF8.self))
    }

    /// llama_decode 的返回值：0 成功，1 KV 放不下，2 被 abort 回调中止，其余为错误
    private func check(_ rc: Int32) throws {
        switch rc {
        case 0: return
        case 2: throw CancellationError()
        default: throw LlamaError.decodeFailed(rc)
        }
    }

    private func makeSampler(vocab: OpaquePointer?) -> UnsafeMutablePointer<llama_sampler> {
        calls &+= 1
        let s = sampling
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(s.topK))
        // 惩罚放在 top-k 之后，免得扫描整个词表
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(
            llama_vocab_n_tokens(vocab), s.penaltyLastN, s.repeatPenalty, 0, s.presencePenalty))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(s.topP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_min_p(s.minP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(s.temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(seed.map { $0 &+ calls } ?? UInt32.random(in: 0..<UInt32.max)))
        return chain
    }

    private func free() {
        lock.withLock {
            if let c = context { llama_free(c) }
            if let m = llamaModel { llama_model_free(m) }
            if let v = vocabModel { llama_model_free(v) }
            context = nil
            llamaModel = nil
            vocabModel = nil
        }
    }

    // MARK: - 工具

    private func tokenize(_ text: String, vocab: OpaquePointer?, parseSpecial: Bool) -> [llama_token] {
        let length = Int32(text.utf8.count)
        guard length > 0 else { return [] }
        // 缓冲区不够时返回负的所需长度
        let needed = -llama_tokenize(vocab, text, length, nil, 0, false, parseSpecial)
        var tokens = [llama_token](repeating: 0, count: Int(max(needed, 1)))
        let n = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), false, parseSpecial)
        return Array(tokens.prefix(Int(max(n, 0))))
    }

    private func piece(_ token: llama_token, vocab: OpaquePointer?) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if n < 0 {
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(n, 0))).map { UInt8(bitPattern: $0) }
    }

    /// 预填了空 think 块，正常不会再有；保险起见去掉开头的 `<think>…</think>`
    static func stripThink(_ text: String) -> String {
        guard let open = text.range(of: "<think>"),
              text[..<open.lowerBound].allSatisfy(\.isWhitespace),
              let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex)
        else { return text }
        return String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 每个进程初始化一次：Metal 设备和内嵌的 shader 在这里准备（App 第一次或更新后第一次约 6 秒），
    /// 日志只把警告和错误转到系统日志，不刷 stderr
    private static let initializeBackend: Void = {
        llama_log_set({ level, text, _ in
            guard let text, level == GGML_LOG_LEVEL_ERROR || level == GGML_LOG_LEVEL_WARN else { return }
            llamaLog.log("\(String(cString: text), privacy: .public)")
        }, nil)
        llama_backend_init()
    }()

    /// 进程退出时 ggml 的 Metal 设备在静态析构里断言所有缓冲都已释放，模型还在内存里就会 abort
    /// （App 退出时生成纪要的模型可能还没释放）。atexit 按注册的逆序执行，所以在第一次建好上下文、
    /// ggml 的静态对象都已构造之后再注册，才能赶在它们析构之前释放
    private static let unloadAtExit: Void = { atexit { liveEngines.unloadAll() } }()
}

/// 所有活着的引擎（弱引用），退出时统一释放
private let liveEngines = LiveEngines()

private final class LiveEngines: @unchecked Sendable {
    private let lock = NSLock()
    private let engines = NSHashTable<LlamaTextGenerator>.weakObjects()
    func add(_ engine: LlamaTextGenerator) { lock.withLock { engines.add(engine) } }
    func unloadAll() { lock.withLock { engines.allObjects }.forEach { $0.unload() } }
}

private let llamaLog = Logger(subsystem: "com.faymee.app", category: "llama")

extension LlamaTextGenerator {
    /// 采样参数：Qwen3 官方建议的非思考模式参数（0.7 / 0.8 / 20 / 0），presence penalty 例外：
    /// 官方建议 1.5，实测输出 JSON 时偶尔漏条目；0 时偶尔陷入重复同一条直到 maxTokens。取中间的 0.5
    /// （样本少，见 ticket 04 的调优记录，正式对比在 ticket 10）
    struct Sampling {
        var temperature: Float = 0.7
        var topP: Float = 0.8
        var topK: Int32 = 20
        var minP: Float = 0
        var presencePenalty: Float = 0.5
        var repeatPenalty: Float = 1
        var penaltyLastN: Int32 = 64
    }

    struct Stats {
        var promptTokens: Int
        var outputTokens = 0
        /// 因 EOG 结束；false 表示到了 maxTokens 被截断
        var endedByEOG = false
        var promptSeconds: TimeInterval = 0
        var totalSeconds: TimeInterval = 0
    }
}

public enum LlamaError: LocalizedError, Equatable {
    case modelNotDownloaded
    /// llama.cpp 加载模型失败时不给原因，多半是文件损坏
    case loadFailed
    /// 建上下文（分配 KV cache 等）失败
    case outOfMemory
    case notLoaded
    /// 提示词加输出超出上下文长度。管线按 `contextTokens` 分段时不会出现
    case promptTooLong(tokens: Int, maxTokens: Int)
    case decodeFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .modelNotDownloaded: "模型还没有下载"
        case .loadFailed: "模型加载失败，文件可能已损坏"
        case .outOfMemory: "内存不足，关闭一些应用后重试"
        case .notLoaded: "模型还没有加载"
        case let .promptTooLong(tokens, maxTokens): "输入太长（\(tokens) + \(maxTokens) token），超出模型上下文"
        case let .decodeFailed(code): "模型运行出错（\(code)）"
        }
    }
}

/// 一次 `load`/`generate` 调用的取消标志
private final class Call: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// 还没结束的调用（排队中的和队列上正在跑的那次）。llama.cpp 的 abort 回调是 C 函数指针，
/// 不能捕获上下文，经 user_data 拿到它，读正在跑的那次的取消标志
private final class RunningCall: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ObjectIdentifier: Call] = [:]
    private var current: Call?
    func add(_ call: Call) { lock.withLock { pending[ObjectIdentifier(call)] = call } }
    func begin(_ call: Call) { lock.withLock { current = call } }
    func end(_ call: Call) {
        lock.withLock {
            pending[ObjectIdentifier(call)] = nil
            current = nil
        }
    }
    func cancelAll() { lock.withLock { Array(pending.values) }.forEach { $0.cancel() } }
    var isCancelled: Bool { lock.withLock { current }?.isCancelled ?? false }
}

private final class LoadProgress {
    let call: Call
    let report: (Double) -> Void
    init(call: Call, report: @escaping (Double) -> Void) {
        self.call = call
        self.report = report
    }
}
