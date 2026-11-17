import Foundation
import SherpaOnnxC

/// Qwen3-ASR 0.6B（sherpa-onnx `OfflineRecognizerQwen3ASRImpl`）识别一段音频。
///
/// - 输出带标点；不给逐字时间（句子时间按字数估算，见 `SentenceAssembly`）
/// - 提示词由 sherpa 拼：热词用空格连接放在 system 段（`<|im_start|>system\n甲 乙<|im_end|>`），
///   模型先输出 `language Chinese<asr_text>` 再输出文字，sherpa 会去掉这个前缀。
///   热词、音频、输出共用 `max_total_len`（512）的上下文，超了 sherpa 会悄悄截掉音频，
///   所以热词先按 `Qwen3ASR.fitHotwords` 截到预算内
/// - sherpa 自己会截掉「只在两三个 token 间打转」的复读；其余复读、单独的「system」这类提示词泄漏
///   由外面套的 `GuardedRecognizer` 处理
public final class Qwen3ASRRecognizer: SegmentRecognizer {
    private let recognizer: OpaquePointer

    /// - Parameters:
    ///   - directory: 模型目录（`LocalModel.qwen3ASR.directory(in:)`），文件要先按大小确认齐全
    ///   - hotwords: 已截到预算内的热词
    public init(directory: URL, hotwords: [String] = [], threads: Int = 4, debug: Bool = false) throws {
        func path(_ name: String) -> UnsafeMutablePointer<CChar> {
            strdup(directory.appendingPathComponent(name).path)
        }
        let frontend = path("conv_frontend.onnx"), encoder = path("encoder.int8.onnx")
        let decoder = path("decoder.int8.onnx"), tokenizer = path("tokenizer")
        let cpu = strdup("cpu"), greedy = strdup("greedy_search")
        let words = strdup(Qwen3ASR.hotwordsArgument(hotwords))
        defer { [frontend, encoder, decoder, tokenizer, cpu, greedy, words].forEach { free($0) } }

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Int32(SpeechSegmentation.sampleRate)
        config.feat_config.feature_dim = 80
        config.decoding_method = UnsafePointer(greedy)
        config.model_config.num_threads = Int32(threads)
        config.model_config.provider = UnsafePointer(cpu)
        config.model_config.debug = debug ? 1 : 0
        config.model_config.qwen3_asr.conv_frontend = UnsafePointer(frontend)
        config.model_config.qwen3_asr.encoder = UnsafePointer(encoder)
        config.model_config.qwen3_asr.decoder = UnsafePointer(decoder)
        config.model_config.qwen3_asr.tokenizer = UnsafePointer(tokenizer)
        // C API 里 0 表示默认值，这里显式写出 sherpa 的默认（同评估）：贪心解码（温度 ≤ 1e-6 即贪心）。
        // 提示词、音频（10 秒段）、热词（≤ 150）加上最多 128 个输出 token 放得进 512
        config.model_config.qwen3_asr.max_total_len = Int32(Qwen3ASR.contextTokens)
        config.model_config.qwen3_asr.max_new_tokens = 128
        config.model_config.qwen3_asr.temperature = 1e-6
        config.model_config.qwen3_asr.top_p = 0.8
        config.model_config.qwen3_asr.seed = 42
        config.model_config.qwen3_asr.hotwords = UnsafePointer(words)
        guard let r = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw SherpaModelError.engineUnavailable(model: Qwen3ASR.name)
        }
        recognizer = r
    }

    deinit { SherpaOnnxDestroyOfflineRecognizer(recognizer) }

    public func recognize(_ samples: ArraySlice<Float>) throws -> SegmentRecognition {
        SegmentRecognition(text: rawText(samples).trimmingCharacters(in: .whitespacesAndNewlines), tokens: nil)
    }

    /// sherpa 的原始输出。`options` 是按流的选项（`language`、`hotwords`、`max_new_tokens`…）
    func rawText(_ samples: ArraySlice<Float>, options: [String: String] = [:]) -> String {
        guard !samples.isEmpty, let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        for (key, value) in options { SherpaOnnxOfflineStreamSetOption(stream, key, value) }
        samples.withUnsafeBufferPointer {
            SherpaOnnxAcceptWaveformOffline(stream, Int32(SpeechSegmentation.sampleRate), $0.baseAddress,
                                            Int32($0.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        return result.pointee.text.map { String(cString: $0) } ?? ""
    }
}

/// Qwen3-ASR 的固定参数
public enum Qwen3ASR {
    public static let name = "Qwen3-ASR"
    /// 写进转写稿的引擎名（与目录 id 相同）
    public static let engine = LocalModel.qwen3ASR.id
    /// 提示词 + 音频 + 输出的上限（sherpa `max_total_len`）
    static let contextTokens = 512

    /// 交给 sherpa 的 `hotwords` 参数：逗号连接（sherpa 按 ASCII `,` 拆开，再用空格连接拼进提示词）。
    /// 热词里的分隔符先换成空格，同 Fun-ASR-Nano
    static func hotwordsArgument(_ hotwords: [String]) -> String {
        FunASRNano.sanitize(hotwords).joined(separator: ",")
    }

    /// 按 Qwen3 tokenizer 的实际计数把热词截到预算内（按热词表顺序，放不下就停）。
    /// 计的是 system 段里空格连接的热词串（Qwen3-ASR 的 tokenizer 与 Fun-ASR-Nano 的 Qwen3-0.6B 是同一份）
    public static func fitHotwords(_ hotwords: [String], budget: Int, modelDirectory: URL) throws -> [String] {
        let words = FunASRNano.sanitize(hotwords)
        guard !words.isEmpty else { return [] }
        let counter = try QwenTokenCounter(directory: modelDirectory.appendingPathComponent("tokenizer"))
        return HotwordBudget.fit(words, budget: budget, separator: " ", count: counter.count)
    }
}

extension SherpaOfflineTranscriber {
    /// 用 Qwen3-ASR 的会后转写：热词按目录项的预算截断，识别器套上输出防护（`GuardedRecognizer`）。
    /// 写进转写稿的引擎名是 `Qwen3ASR.engine`
    /// - Parameters:
    ///   - model: Qwen3-ASR 的目录项（`LocalModel.qwen3ASR.id`）
    ///   - vadModel: 静音切段模型，App 里传 `SileroVAD.bundledModel`
    public static func qwen3ASR(model: CatalogModel, catalog: ModelCatalog = .builtIn,
                                modelDirectory: URL = LocalModel.defaultDirectory, vadModel: URL?,
                                threads: Int = 4) -> SherpaOfflineTranscriber {
        let budget = model.parameters.hotwordTokenBudget ?? 150
        let directory = LocalModel.qwen3ASR.directory(in: modelDirectory)
        return SherpaOfflineTranscriber(model: model, catalog: catalog, modelDirectory: modelDirectory,
                                        vadModel: vadModel) { hotwords in
            let fitted = try Qwen3ASR.fitHotwords(hotwords, budget: budget, modelDirectory: directory)
            return GuardedRecognizer(try Qwen3ASRRecognizer(directory: directory, hotwords: fitted, threads: threads))
        }
    }
}
