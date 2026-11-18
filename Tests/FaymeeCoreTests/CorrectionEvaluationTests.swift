import Darwin
import Foundation
import Testing
@testable import FaymeeCore

/// 转写纠错的评估（ticket 04，spec「补充说明 › 评估」）：不是回归测试，只在手动设环境变量时运行，
/// 用例、转写稿和结果都不进仓库。纠错跑的是 App 里同一套 `correctTranscript`（提示词、分段、比对、护栏），
/// 只是包了一层记录原始输出、耗时和内存。
///
/// 一、合成会议转写：`<audio>/<名>.m4a` + `<名>.json`（`{title, hotwords, lines: [{speaker, text}]}`，标准稿），
/// 用每个本机会后转写模型转写并区分说话人，转写稿写进 `<out>/asr-store/<名>-<模型>/`，用例写进 `<out>/cases/`：
///
///     FAYMEE_CORRECTION_EVAL_OUT=… FAYMEE_CORRECTION_EVAL_AUDIO=<audio> \
///         swift test --filter CorrectionEvaluation/transcribe
///
/// 二、纠错：`FAYMEE_CORRECTION_EVAL_CASES` 里每个用例（`EvalCase` 的 JSON）跑一遍，写
/// `<out>/<label>/<用例>-r<n>.json`（改前改后、建议、挡掉、原始输出、耗时、内存，有标准稿时带计分）。
/// 引擎 `local`（Qwen3.5 4B，换字词）、`local-full`（同一个模型走在线的整句改写，试本机补字删字）、
/// `online`（DeepSeek 经 `OnlineMinutesEngine.makeGenerator`，同 App 在线纪要的路径；模型默认 deepseek-flash，即评估时
/// 这台机器在线纪要选的模型，`FAYMEE_DEEPSEEK_MODEL` 可改）。热词默认不给（新安装热词表是空的），
/// `FAYMEE_CORRECTION_EVAL_HOTWORDS=1` 时用用例自带的。`online-whatif` 是假设输出上限放大（`FAYMEE_CORRECTION_EVAL_MAX_OUTPUT`，
/// 默认 32768）的在线，不是 App 的配置；`FAYMEE_CORRECTION_EVAL_FIRST_RUN` 只补跑某一次；`FAYMEE_CORRECTION_EVAL_REPLAY=<结果目录>`
/// 用那次记下的原始输出代替模型生成，只重跑分段和护栏（护栏改了以后重算）：
///
///     FAYMEE_CORRECTION_EVAL_OUT=… FAYMEE_CORRECTION_EVAL_CASES=<dir> FAYMEE_CORRECTION_EVAL_ENGINE=local \
///     [FAYMEE_CORRECTION_EVAL_RUNS=3] [FAYMEE_CORRECTION_EVAL_LABEL=…] [FAYMEE_CORRECTION_EVAL_ONLY=名1,名2] \
///     [FAYMEE_DEEPSEEK_API_KEY=… FAYMEE_DEEPSEEK_MODEL=…] swift test --filter CorrectionEvaluationTests/correct
///
/// 三、裁判：`FAYMEE_CORRECTION_EVAL_JUDGE=<结果目录>` 里真实会议（set == real）的每处修改交给在线模型
/// （默认 deepseek-v4-pro）判断，写 `<结果目录>/judge-<用例>-r<n>.json`。只作参考，不进门槛
private let env = ProcessInfo.processInfo.environment
private let evalOut = env["FAYMEE_CORRECTION_EVAL_OUT"].map { URL(fileURLWithPath: $0) }
private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

@Suite(.serialized, .enabled(if: evalOut != nil, "设 FAYMEE_CORRECTION_EVAL_OUT 才跑"))
struct CorrectionEvaluationTests {
    @Test(.enabled(if: env["FAYMEE_CORRECTION_EVAL_AUDIO"] != nil, "转写合成会议：设 FAYMEE_CORRECTION_EVAL_AUDIO 才跑"))
    func transcribe() async throws {
        let audio = URL(fileURLWithPath: env["FAYMEE_CORRECTION_EVAL_AUDIO"]!)
        let store = MeetingStore(root: evalOut!.appendingPathComponent("asr-store"))
        let cases = evalOut!.appendingPathComponent("cases")
        try FileManager.default.createDirectory(at: cases, withIntermediateDirectories: true)
        let diarizer = SherpaOnnxDiarizer(modelDirectory: repository.appendingPathComponent("Resources/Diarization"))
        let vad = repository.appendingPathComponent("Resources/VAD/silero_vad.onnx")
        let models = (env["FAYMEE_CORRECTION_EVAL_ASR"] ?? "")
            .split(separator: ",").map(String.init)
        let catalog = ModelCatalog.builtIn.models(for: .transcription)
            .filter { models.isEmpty || models.contains($0.id) }
        let names = try FileManager.default.contentsOfDirectory(atPath: audio.path)
            .filter { $0.hasSuffix(".m4a") }.map { String($0.dropLast(4)) }.sorted()
        for name in names {
            let meta = try JSONDecoder().decode(ScriptMeta.self,
                                                from: Data(contentsOf: audio.appendingPathComponent(name + ".json")))
            for model in catalog {
                guard let transcriber = LocalTranscriptionEngine.transcriber(
                    for: model, modelDirectory: LocalModel.defaultDirectory, vadModel: vad) else { continue }
                let short = model.id.split(separator: "/").last.map(String.init) ?? model.id
                let id = "\(name)-\(short)"
                let started = Date()
                // 转写不给热词：评估决定新安装的默认值，新安装热词表是空的
                let sentences = try await transcriber.transcribe(audio: audio.appendingPathComponent(name + ".m4a"),
                                                                 hotwords: []) { _ in }
                let items = sentences.enumerated().map { i, s in
                    TranscriptItem.sentence(TranscriptSentence(id: "s\(i + 1)", start: s.start, end: s.end, text: s.text))
                }
                var transcript = Transcript(engine: model.id, createdAt: Date(), hotwords: [], items: items)
                let result = try await diarizer.diarize(audio: audio.appendingPathComponent(name + ".m4a"),
                                                        sentences: transcript.sentences.map { $0.start...$0.end },
                                                        speakerCount: nil) { _ in }
                transcript = transcript.withSpeakers(result, engine: diarizer.engine,
                                                     voiceprintModel: diarizer.voiceprintModel, createdAt: Date())
                try FileManager.default.createDirectory(at: store.root.appendingPathComponent(id),
                                                        withIntermediateDirectories: true)
                try store.saveTranscript(transcript, for: id)
                let evalCase = EvalCase(name: id, set: "asr", title: meta.title, hotwords: meta.hotwords,
                                        reference: meta.lines.map(\.text).joined(separator: "\n"),
                                        store: store.root.path, meeting: id)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(evalCase).write(to: cases.appendingPathComponent(id + ".json"))
                print(String(format: "%@：%d 句，%.0f 秒", id, transcript.sentences.count,
                             Date().timeIntervalSince(started)))
            }
        }
    }

    @Test(.enabled(if: env["FAYMEE_CORRECTION_EVAL_CASES"] != nil && env["FAYMEE_CORRECTION_EVAL_ENGINE"] != nil,
                   "纠错：设 FAYMEE_CORRECTION_EVAL_CASES 和 FAYMEE_CORRECTION_EVAL_ENGINE 才跑"))
    func correct() async throws {
        let engineName = env["FAYMEE_CORRECTION_EVAL_ENGINE"]!
        let label = env["FAYMEE_CORRECTION_EVAL_LABEL"] ?? engineName
        let runs = Int(env["FAYMEE_CORRECTION_EVAL_RUNS"] ?? "") ?? 1
        let useHotwords = env["FAYMEE_CORRECTION_EVAL_HOTWORDS"] == "1"
        let only = Set((env["FAYMEE_CORRECTION_EVAL_ONLY"] ?? "").split(separator: ",").map(String.init))
        let out = evalOut!.appendingPathComponent(label)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let cases = try loadCases(URL(fileURLWithPath: env["FAYMEE_CORRECTION_EVAL_CASES"]!))
            .filter { only.isEmpty || only.contains($0.name) }

        let transport = RecordingHTTPTransport()
        let (generator, method, engineID, local) = try makeEngine(engineName, transport: transport)
        let replayDirectory = env["FAYMEE_CORRECTION_EVAL_REPLAY"].map { URL(fileURLWithPath: $0) }
        var loadSeconds = 0.0
        if let local {
            let started = Date()
            try await local.load { _ in }
            loadSeconds = Date().timeIntervalSince(started)
        }
        defer { local?.unload() }

        for evalCase in cases {
            let transcript = try evalCase.transcript()
            // FAYMEE_CORRECTION_EVAL_FIRST_RUN：补跑某一次（如网络断了的那次）
            let first = Int(env["FAYMEE_CORRECTION_EVAL_FIRST_RUN"] ?? "") ?? 1
            for run in first...max(first, runs) {
                // 重放：用以前某次运行记下的原始输出代替模型，只重跑护栏（护栏改了以后重算本机的结果）
                let source = try replayDirectory.map { directory -> any TextGenerator in
                    let file = directory.appendingPathComponent("\(evalCase.name)-r\(run).json")
                    let old = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
                    return ReplayGenerator(generator, outputs: old?["outputs"] as? [String] ?? [])
                } ?? generator
                let recorder = RecordingGenerator(source)
                transport.removeAll()
                let peak = EvalPeakMemory()
                let started = Date()
                var review: CorrectionReview?
                var failure: String?
                do {
                    review = try await correctTranscript(
                        transcript, title: evalCase.title, hotwords: useHotwords ? evalCase.hotwords : [],
                        method: method, generator: recorder)
                } catch {
                    failure = "\(error)"
                }
                let seconds = Date().timeIntervalSince(started)
                let (footprint, resident) = peak.stop()
                let sentences = transcript.sentences
                let after = sentences.map { review?.texts[$0.id] ?? $0.text }
                var record: [String: Any] = [
                    "case": evalCase.name, "set": evalCase.set, "engine": engineID, "label": label, "run": run,
                    "hotwords": useHotwords, "sentences": sentences.count, "error": failure ?? NSNull(),
                    "seconds": seconds, "loadSeconds": loadSeconds, "calls": recorder.outputs.count,
                    "peakFootprintMB": footprint, "peakResidentMB": resident,
                    "rejections": review?.rejections ?? [:],
                    "suggestions": (review?.suggestions ?? []).map { ["sentence": $0.sentence, "from": $0.from, "to": $0.to] },
                    "changes": sentences.indices.filter { after[$0] != sentences[$0].text }.map { i in
                        ["index": i, "id": sentences[i].id, "before": sentences[i].text, "after": after[i]] as [String: Any]
                    },
                    "outputs": recorder.outputs,
                    // 在线：每次请求的 finish_reason 和 usage（不含正文）
                    "http": httpSummary(transport),
                ]
                if let known = evalCase.known {
                    let texts = Dictionary(zip(sentences.map(\.id), after), uniquingKeysWith: { a, _ in a })
                    record["known"] = known.map { k in
                        let text = texts[k.sentence] ?? ""
                        return ["sentence": k.sentence, "wrong": k.wrong, "right": k.right,
                                "fixed": text.contains(k.right) && !text.contains(k.wrong), "after": text] as [String: Any]
                    }
                }
                if let reference = evalCase.reference {
                    let score = CorrectionScore(before: sentences.map(\.text), after: after, reference: reference,
                                                clean: evalCase.set == "clean")
                    record["score"] = [
                        "referenceLength": score.referenceLength, "errorsBefore": score.errorsBefore,
                        "errorsAfter": score.errorsAfter, "changed": score.changed, "improved": score.improved,
                        "broken": score.broken, "neutral": score.neutral,
                        "deltas": Dictionary(uniqueKeysWithValues: score.deltas.map { (sentences[$0.key].id, $0.value) }),
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: out.appendingPathComponent("\(evalCase.name)-r\(run).json"))
                print(String(format: "%@ %@ r%d：%.0f 秒，改了 %d 句%@", label, evalCase.name, run, seconds,
                             review?.texts.count ?? 0, failure.map { "，失败：\($0)" } ?? ""))
            }
        }
    }

    @Test(.enabled(if: env["FAYMEE_CORRECTION_EVAL_JUDGE"] != nil && env["FAYMEE_CORRECTION_EVAL_CASES"] != nil,
                   "裁判：设 FAYMEE_CORRECTION_EVAL_JUDGE 和 FAYMEE_CORRECTION_EVAL_CASES 才跑"))
    func judge() async throws {
        let results = URL(fileURLWithPath: env["FAYMEE_CORRECTION_EVAL_JUDGE"]!)
        let cases = Dictionary(try loadCases(URL(fileURLWithPath: env["FAYMEE_CORRECTION_EVAL_CASES"]!))
            .map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let key = try #require(env["FAYMEE_DEEPSEEK_API_KEY"], "要 FAYMEE_DEEPSEEK_API_KEY")
        let model = env["FAYMEE_CORRECTION_EVAL_JUDGE_MODEL"] ?? "deepseek-v4-pro"
        let transport = RecordingHTTPTransport()
        // 裁判是推理模型，思考也算在 max_tokens 里：给足输出上限，每批少放几处
        let judge = OpenAICompatibleTextGenerator(config: deepSeekConfig(model: model, key: key), transport: transport,
                                                  contextTokens: 256_000, maxOutputTokens: 64_000)
        let files = try FileManager.default.contentsOfDirectory(atPath: results.path)
            .filter { !$0.hasPrefix("judge-") && $0.hasSuffix(".json") }.sorted()
        for file in files {
            let record = try #require(try JSONSerialization.jsonObject(
                with: Data(contentsOf: results.appendingPathComponent(file))) as? [String: Any])
            guard record["set"] as? String == "real", let evalCase = cases[record["case"] as? String ?? ""],
                  let changes = record["changes"] as? [[String: Any]], !changes.isEmpty else { continue }
            let sentences = try evalCase.transcript().sentences
            var verdicts: [[String: Any]] = []
            transport.removeAll()
            for batch in stride(from: 0, to: changes.count, by: 10).map({ Array(changes[$0..<min($0 + 10, changes.count)]) }) {
                let items = batch.enumerated().map { n, change -> String in
                    let i = change["index"] as! Int
                    let context = { (range: Range<Int>) in
                        range.clamped(to: 0..<sentences.count).map { sentences[$0].text }.joined(separator: " / ")
                    }
                    return """
                    #\(n + 1)
                    上文：\(context(i - 2..<i))
                    原句：\(change["before"] as! String)
                    改后：\(change["after"] as! String)
                    下文：\(context(i + 1..<i + 3))
                    """
                }
                // 输出被截断、为空时这一批算「裁判没跑成」，不当成判断
                let output = try? await judge.generate(system: judgeSystemPrompt, prompt: items.joined(separator: "\n\n"),
                                                       maxTokens: 32_000)
                let parsed = output.flatMap { jsonEntries($0, key: "verdicts") } as? [[String: Any]] ?? []
                for (n, change) in batch.enumerated() {
                    let verdict = parsed.first { ($0["n"] as? Int) == n + 1 }
                    verdicts.append(["id": change["id"]!, "before": change["before"]!, "after": change["after"]!,
                                     "verdict": verdict?["verdict"] ?? "notRun", "reason": verdict?["reason"] ?? ""])
                }
            }
            let data = try JSONSerialization.data(withJSONObject: ["case": evalCase.name, "judge": model,
                                                                   "verdicts": verdicts, "http": httpSummary(transport)],
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: results.appendingPathComponent("judge-" + file))
            let counts = Dictionary(grouping: verdicts, by: { $0["verdict"] as? String ?? "" }).mapValues(\.count)
            print("裁判 \(file)：\(counts)")
        }
    }

    private func makeEngine(_ name: String, transport: RecordingHTTPTransport) throws
        -> (any TextGenerator, CorrectionMethod, String, LlamaTextGenerator?) {
        switch name {
        case "local", "local-full":
            let entry = try #require(ModelCatalog.builtIn.model(id: LocalModel.qwen3_5_4B.id))
            let engine = LlamaTextGenerator(catalogModel: entry, directory: LocalModel.defaultDirectory)
            return (engine, name == "local" ? .wordFixes : .sentenceRewrite, entry.id, engine)
        case "online":
            let key = try #require(env["FAYMEE_DEEPSEEK_API_KEY"], "要 FAYMEE_DEEPSEEK_API_KEY")
            let model = env["FAYMEE_DEEPSEEK_MODEL"] ?? "deepseek-flash"
            let generator = OnlineMinutesEngine.makeGenerator(provider: .deepSeek,
                                                              config: deepSeekConfig(model: model, key: key),
                                                              transport: transport)
            return (generator, .sentenceRewrite, "deepseek/\(model)", nil)
        case "online-whatif":
            // 假设：输出上限放大（推理模型的思考也算在 max_tokens 里）。不是 App 的配置，只作参考
            let key = try #require(env["FAYMEE_DEEPSEEK_API_KEY"], "要 FAYMEE_DEEPSEEK_API_KEY")
            let model = env["FAYMEE_DEEPSEEK_MODEL"] ?? "deepseek-flash"
            let output = Int(env["FAYMEE_CORRECTION_EVAL_MAX_OUTPUT"] ?? "") ?? 32_768
            let generator = OpenAICompatibleTextGenerator(config: deepSeekConfig(model: model, key: key),
                                                          transport: transport, contextTokens: output * 4,
                                                          maxOutputTokens: output)
            return (generator, .sentenceRewrite, "deepseek/\(model)@\(output)", nil)
        default:
            throw EvalError.unknownEngine(name)
        }
    }

    private func deepSeekConfig(model: String, key: String) -> OnlineEndpointConfig {
        OnlineEndpointConfig(baseURL: OnlineMinutesProvider.deepSeek.defaultBaseURL, model: model, apiKey: key,
                             requiresHTTPS: true, requiresAPIKey: true,
                             providerID: OnlineMinutesProvider.deepSeek.providerID)
    }

    private func loadCases(_ directory: URL) throws -> [EvalCase] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted()
            .map { try JSONDecoder().decode(EvalCase.self, from: Data(contentsOf: directory.appendingPathComponent($0))) }
    }
}

private enum EvalError: Error {
    case unknownEngine(String)
    /// 重放时调用次数比记下的多（分段变了）
    case replayExhausted
    case noTranscript(String)
}

private let judgeSystemPrompt = """
你是严格的中文会议转写稿校对评审。转写稿由语音识别生成，有人用自动纠错改了其中一些句子。\
对每一处，结合上下文判断这次修改：
- correct：原句有识别错误（听错的字词、漏字、失控重复、标记残留），改后更接近说话人实际说的话，且没有引入新错误；
- wrong：原句本来没错却被改了，或改成了别的错误、改变了原意、删掉了说话人真的说过的话；
- unsure：上下文不足，无法判断。
口语、口吃、语气词本来就该保留，被删掉算 wrong；只调整标点且不影响意思算 correct。
只输出 JSON：{"verdicts": [{"n": 1, "verdict": "correct", "reason": "一句话理由"}]}，每一处一条，n 对应编号。
"""

/// 一个评估用例。转写稿来自会议目录（`store` + `meeting`），或直接给句子（`sentences`）
struct EvalCase: Codable {
    struct Sentence: Codable {
        var id: String
        var text: String
        var speaker: String?
    }

    struct Known: Codable {
        var sentence: String
        var wrong: String
        var right: String
    }

    var name: String
    /// asr（合成会议转写）、injected（标准稿上制造错误）、clean（本来全对）、real（真实会议，没有标准稿）
    var set: String
    var title: String
    var hotwords: [String] = []
    /// 标准稿；real 没有
    var reference: String?
    var store: String?
    var meeting: String?
    var sentences: [Sentence]?
    /// 已知错例（真实会议的回归清单）
    var known: [Known]?

    func transcript() throws -> Transcript {
        if let store, let meeting {
            guard let t = try MeetingStore(root: URL(fileURLWithPath: store)).loadTranscript(meeting) else {
                throw EvalError.noTranscript(meeting)
            }
            return t
        }
        let sentences = sentences ?? []
        let items = sentences.enumerated().map { i, s in
            TranscriptItem.sentence(TranscriptSentence(id: s.id, start: Double(i * 5), end: Double(i * 5 + 4),
                                                       text: s.text, speaker: s.speaker))
        }
        var t = Transcript(engine: "eval/text", createdAt: Date(timeIntervalSince1970: 0), hotwords: [], items: items)
        let speakers = Array(Set(sentences.compactMap(\.speaker))).sorted()
        if !speakers.isEmpty {
            t.diarization = Diarization(engine: "eval", voiceprintModel: "eval", speakersCreatedAt: Date(timeIntervalSince1970: 0),
                                        speakers: speakers.map { Speaker(id: $0, voiceprint: Voiceprint([0]), speechDuration: 1) })
        }
        return t
    }
}

/// 合成会议的稿子（`synth.py` 写的）
private struct ScriptMeta: Decodable {
    struct Line: Decodable {
        var speaker: String
        var text: String
    }

    var title: String
    var hotwords: [String]
    var lines: [Line]
}

/// 重放记下的原始输出；分词、上下文长度用原来的引擎，分段才和当时一样
private final class ReplayGenerator: TextGenerator, @unchecked Sendable {
    let base: any TextGenerator
    private var outputs: [String]

    init(_ base: any TextGenerator, outputs: [String]) {
        self.base = base
        self.outputs = outputs
    }

    var contextTokens: Int { base.contextTokens }
    var maxOutputTokens: Int { base.maxOutputTokens }
    func countTokens(_ text: String) -> Int { base.countTokens(text) }
    var isDownloaded: Bool { true }
    func load(progress: @escaping (Double) -> Void) async throws {}
    func unload() {}
    func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        guard !outputs.isEmpty else { throw EvalError.replayExhausted }
        return outputs.removeFirst()
    }
}

/// 每次在线请求的状态码、耗时、`finish_reason`、`usage`（不含正文），写进评估记录
private func httpSummary(_ transport: RecordingHTTPTransport) -> [[String: Any]] {
    transport.exchanges.map { exchange in
        let object = exchange.json
        let choice = (object?["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any]
        return [
            "status": exchange.response.status, "seconds": exchange.seconds,
            "finishReason": choice?["finish_reason"] ?? NSNull(), "usage": object?["usage"] ?? NSNull(),
            "model": object?["model"] ?? NSNull(),
            "contentLength": (message?["content"] as? String)?.count ?? -1,
            "reasoningLength": (message?["reasoning_content"] as? String)?.count ?? -1,
        ]
    }
}

/// 包一层 `TextGenerator`，记下每次调用的原始输出。`withThinkingDisabled`（在线纠错关思考）转给里面的引擎，
/// 记录照样记在同一处
final class RecordingGenerator: TextGenerator, @unchecked Sendable {
    private final class Log: @unchecked Sendable {
        var outputs: [String] = []
    }

    let engine: any TextGenerator
    private let log: Log
    var outputs: [String] { log.outputs }

    convenience init(_ engine: any TextGenerator) { self.init(engine, log: Log()) }
    private init(_ engine: any TextGenerator, log: Log) {
        self.engine = engine
        self.log = log
    }

    var contextTokens: Int { engine.contextTokens }
    var maxOutputTokens: Int { engine.maxOutputTokens }
    var minutesChunking: MinutesChunking { engine.minutesChunking }
    func countTokens(_ text: String) -> Int { engine.countTokens(text) }
    var isDownloaded: Bool { engine.isDownloaded }
    func load(progress: @escaping (Double) -> Void) async throws { try await engine.load(progress: progress) }
    func unload() { engine.unload() }
    func withThinkingDisabled() -> any TextGenerator { RecordingGenerator(engine.withThinkingDisabled(), log: log) }
    func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        try await generate(system: system, prompt: prompt, maxTokens: maxTokens, grammar: nil)
    }

    func generate(system: String, prompt: String, maxTokens: Int, grammar: String?) async throws -> String {
        let output = try await engine.generate(system: system, prompt: prompt, maxTokens: maxTokens, grammar: grammar)
        log.outputs.append(output)
        return output
    }
}

/// 每 0.2 秒采一次进程内存，记峰值（MB），同 `MinutesCandidatesMeasureTests`
private final class EvalPeakMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var footprint: UInt64 = 0
    private var resident: UInt64 = 0
    private var running = true

    init() {
        Thread { [self] in
            while lock.withLock({ running }) {
                sample()
                Thread.sleep(forTimeInterval: 0.2)
            }
        }.start()
    }

    private func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        lock.withLock {
            footprint = max(footprint, info.phys_footprint)
            resident = max(resident, info.resident_size)
        }
    }

    func stop() -> (footprint: Int, resident: Int) {
        sample()
        return lock.withLock {
            running = false
            return (Int(footprint / 1_000_000), Int(resident / 1_000_000))
        }
    }
}
