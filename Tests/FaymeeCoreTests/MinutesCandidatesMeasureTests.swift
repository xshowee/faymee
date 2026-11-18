import Darwin
import Foundation
import Testing
@testable import FaymeeCore

/// 纪要模型候选的实测（ticket 11）：不是回归测试，只在手动指定会议或转写稿时运行，会议、转写稿和结果都不进仓库。
///
/// 一、用会后转写的默认模型（Fun-ASR-Nano）+ 区分说话人，把一场会议转成转写稿（同 App：热词表、空白、说话人）。
/// `FAYMEE_CANDIDATES_STORE` 是会议目录的根（建议先把会议拷到别处，免得动到 App 的会议目录），
/// 转写稿写进同一个目录（`<id>/transcript.json`）：
///
///     FAYMEE_CANDIDATES_STORE=/some/Meetings FAYMEE_CANDIDATES_MEETINGS=2026-11-10_10-59-02,… \
///         swift test --filter MinutesCandidatesMeasure/transcribe
///
/// 二、用一个纪要模型的目录项（`LlamaTextGenerator(catalogModel:)`，同 App）对转写稿跑完整的纪要生成，
/// 写 `<out>/<id>-<label>-r<n>.json`：`{minutes, error, calls: [{maxTokens, promptTokens, outputTokens, eog,
/// seconds, output}], loadSeconds, seconds, peakFootprintMB, peakResidentMB}`：
///
///     FAYMEE_CANDIDATES_STORE=… FAYMEE_CANDIDATES_MEETINGS=… FAYMEE_CANDIDATES_OUT=/some/dir \
///     FAYMEE_CANDIDATES_MODEL=llama/qwen3-4b-q4km | /path/model.gguf \
///     [FAYMEE_CANDIDATES_MODELS_DIR=…] [FAYMEE_CANDIDATES_THINKING=1] [FAYMEE_CANDIDATES_CONTEXT=16384] \
///     [FAYMEE_CANDIDATES_EXTRACT=2/5] [FAYMEE_CANDIDATES_MERGE=1/2] [FAYMEE_CANDIDATES_SAMPLING=thinking] \
///     [FAYMEE_CANDIDATES_RUNS=2] [FAYMEE_CANDIDATES_LABEL=…] \
///         swift test --filter MinutesCandidatesMeasure/minutes
///
/// 目录里没有的模型给 GGUF 路径，按文件临时建一个目录项（家族 llamaGGUF，参数取环境变量）
private let env = ProcessInfo.processInfo.environment
private let storeRoot = env["FAYMEE_CANDIDATES_STORE"].map { URL(fileURLWithPath: $0) }
private let meetingIDs = (env["FAYMEE_CANDIDATES_MEETINGS"] ?? "").split(separator: ",").map(String.init)
private let vad = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/VAD/silero_vad.onnx")
private let diarizationModels = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/Diarization")

@Suite(.serialized, .enabled(if: storeRoot != nil && !meetingIDs.isEmpty, "设 FAYMEE_CANDIDATES_STORE 和 _MEETINGS 才跑"))
struct MinutesCandidatesMeasureTests {
    @Test(.enabled(if: env["FAYMEE_CANDIDATES_OUT"] == nil, "只转写时不设 FAYMEE_CANDIDATES_OUT"))
    func transcribe() async throws {
        let store = MeetingStore(root: storeRoot!)
        let meetings = store.loadAll()
        let hotwords = Hotwords.parse(try HotwordStore().load())
        let model = try #require(ModelCatalog.builtIn.model(id: LocalModel.funASRNano.id))
        let transcriber = try #require(LocalTranscriptionEngine.transcriber(
            for: model, modelDirectory: LocalModel.defaultDirectory, vadModel: vad))
        let diarizer = SherpaOnnxDiarizer(modelDirectory: diarizationModels)
        for id in meetingIDs {
            let m = try #require(meetings.first { $0.id == id }, "没有会议 \(id)")
            let audio = try #require(store.recordingURL(m))
            let started = Date()
            let sentences = try await transcriber.transcribe(audio: audio, hotwords: hotwords) { _ in }
            let transcribed = Date().timeIntervalSince(started)
            var transcript = Transcript.assemble(sentences, meeting: m, engine: model.id,
                                                 hotwords: hotwords, createdAt: Date())
            let result = try await diarizer.diarize(audio: audio, sentences: transcript.sentences.map { $0.start...$0.end },
                                                    speakerCount: nil) { _ in }
            transcript = transcript.withSpeakers(result, engine: diarizer.engine, voiceprintModel: diarizer.voiceprintModel,
                                                 createdAt: Date())
            try store.saveTranscript(transcript, for: id)
            print(String(format: "%@：%d 句，%d 个说话人，转写 %.0f 秒，共 %.0f 秒", id, transcript.sentences.count,
                         transcript.diarization?.speakers.count ?? 0, transcribed, Date().timeIntervalSince(started)))
        }
    }

    @Test(.enabled(if: env["FAYMEE_CANDIDATES_OUT"] != nil && env["FAYMEE_CANDIDATES_MODEL"] != nil))
    func minutes() async throws {
        let out = URL(fileURLWithPath: env["FAYMEE_CANDIDATES_OUT"]!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (catalogModel, directory) = try candidate(env["FAYMEE_CANDIDATES_MODEL"]!)
        let label = env["FAYMEE_CANDIDATES_LABEL"] ?? catalogModel.id
        let runs = Int(env["FAYMEE_CANDIDATES_RUNS"] ?? "") ?? 1
        let store = MeetingStore(root: storeRoot!)
        let meetings = store.loadAll()
        for id in meetingIDs {
            let m = try #require(meetings.first { $0.id == id })
            let transcript = try #require(try store.loadTranscript(id))
            for run in 1...runs {
                let engine = LlamaTextGenerator(catalogModel: catalogModel, directory: directory)
                if env["FAYMEE_CANDIDATES_SAMPLING"] == "thinking" {
                    // Qwen3 / Qwen3.5 思考模式的建议值；presence penalty 保持 App 的 0.5
                    engine.sampling.temperature = 0.6
                    engine.sampling.topP = 0.95
                }
                let recorder = CallRecorder(engine)
                let peak = PeakMemory()
                let started = Date()
                var minutes: Minutes?
                var failure: String?
                var loadSeconds = 0.0
                do {
                    try await engine.load { _ in }
                    loadSeconds = Date().timeIntervalSince(started)
                    minutes = try await generateMinutes(
                        transcript: transcript, title: m.title, startedAt: m.startedAt, template: .general,
                        generator: recorder, model: catalogModel.id)
                } catch {
                    failure = "\(error)"
                }
                let seconds = Date().timeIntervalSince(started)
                let (footprint, resident) = peak.stop()
                engine.unload()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let minutesJSON = try minutes.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) }
                let record: [String: Any] = [
                    "meeting": id, "label": label, "run": run, "model": catalogModel.id,
                    "thinking": engine.thinking, "contextTokens": engine.contextTokens,
                    "minutes": minutesJSON ?? NSNull(), "error": failure ?? NSNull(),
                    "loadSeconds": loadSeconds, "seconds": seconds,
                    "peakFootprintMB": footprint, "peakResidentMB": resident,
                    "calls": recorder.calls.map { c in
                        ["maxTokens": c.maxTokens, "promptTokens": c.stats?.promptTokens ?? -1,
                         "outputTokens": c.stats?.outputTokens ?? -1, "eog": c.stats?.endedByEOG ?? false,
                         "seconds": c.stats?.totalSeconds ?? -1, "output": c.output] as [String: Any]
                    },
                ]
                let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: out.appendingPathComponent("\(id)-\(label)-r\(run).json"))
                print(String(format: "%@ %@ r%d：%.0f 秒（加载 %.1f），调用 %d 次，峰值 footprint %d MB / resident %d MB%@",
                             id, label, run, seconds, loadSeconds, recorder.calls.count, footprint, resident,
                             failure.map { "，失败：\($0)" } ?? ""))
            }
        }
    }

    /// 目录里的 id，或 GGUF 文件路径（按文件临时建目录项）
    private func candidate(_ spec: String) throws -> (CatalogModel, URL) {
        let modelsDir = env["FAYMEE_CANDIDATES_MODELS_DIR"].map { URL(fileURLWithPath: $0) } ?? LocalModel.defaultDirectory
        var parameters = ModelParameters()
        if let model = ModelCatalog.builtIn.model(id: spec) { parameters = model.parameters }
        if let c = env["FAYMEE_CANDIDATES_CONTEXT"].flatMap(Int.init) { parameters.contextTokens = c }
        if let t = env["FAYMEE_CANDIDATES_THINKING"] { parameters.thinking = t == "1" }
        func share(_ s: String?) -> TokenShare? {
            guard let parts = s?.split(separator: "/").compactMap({ Int($0) }), parts.count == 2 else { return nil }
            return TokenShare(parts[0], parts[1])
        }
        let standard = parameters.minutesChunking ?? .standard
        parameters.minutesChunking = MinutesChunking(
            extractionOutput: share(env["FAYMEE_CANDIDATES_EXTRACT"]) ?? standard.extractionOutput,
            mergeOutput: share(env["FAYMEE_CANDIDATES_MERGE"]) ?? standard.mergeOutput)

        if let model = ModelCatalog.builtIn.model(id: spec) {
            return (CatalogModel(id: model.id, roles: model.roles, family: model.family, source: model.source,
                                 name: model.name, parameters: parameters, license: model.license), modelsDir)
        }
        let file = URL(fileURLWithPath: spec)
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        let local = LocalModel(id: "llama/" + file.deletingPathExtension().lastPathComponent.lowercased(),
                               fileName: file.lastPathComponent, size: size, sha256: "", downloadURLs: [])
        return (CatalogModel(id: local.id, roles: [.minutes], family: .llamaGGUF, source: .download(local),
                             name: file.lastPathComponent, parameters: parameters),
                file.deletingLastPathComponent())
    }
}

/// 记下每次调用的 maxTokens、统计和原始输出
private final class CallRecorder: TextGenerator, @unchecked Sendable {
    struct Call {
        var maxTokens: Int
        var stats: LlamaTextGenerator.Stats?
        var output: String
    }

    let engine: LlamaTextGenerator
    var calls: [Call] = []
    init(_ engine: LlamaTextGenerator) { self.engine = engine }
    var contextTokens: Int { engine.contextTokens }
    var maxOutputTokens: Int { engine.maxOutputTokens }
    var minutesChunking: MinutesChunking { engine.minutesChunking }
    func countTokens(_ text: String) -> Int { engine.countTokens(text) }
    var isDownloaded: Bool { engine.isDownloaded }
    func load(progress: @escaping (Double) -> Void) async throws { try await engine.load(progress: progress) }
    func unload() { engine.unload() }
    func generate(system: String, prompt: String, maxTokens: Int) async throws -> String {
        try await generate(system: system, prompt: prompt, maxTokens: maxTokens, grammar: nil)
    }

    func generate(system: String, prompt: String, maxTokens: Int, grammar: String?) async throws -> String {
        let output = try await engine.generate(system: system, prompt: prompt, maxTokens: maxTokens, grammar: grammar)
        calls.append(Call(maxTokens: maxTokens, stats: engine.lastStats, output: output))
        return output
    }
}

/// 每 0.2 秒采一次进程内存，记峰值（MB）：phys_footprint（活动监视器的“内存”，不含 mmap 的模型权重）
/// 和 resident_size（含已读进内存的权重页）
private final class PeakMemory: @unchecked Sendable {
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
