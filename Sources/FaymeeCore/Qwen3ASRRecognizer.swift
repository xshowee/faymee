import Foundation
import SherpaOnnxC

/// Qwen3-ASR 0.6B（sherpa-onnx `OfflineRecognizerQwen3ASRImpl`）识别一段音频。
///
/// - 输出带标点；不给逐字时间（句子时间按字数估算，见 `SentenceAssembly`）
/// - 提示词由 sherpa 拼：热词用空格连接放在 system 段（`<|im_start|>system\n甲 乙<|im_end|>`），
///   模型先输出 `language Chinese<asr_text>` 再输出文字，sherpa 会去掉这个前缀。
///   热词、音频、输出共用 `max_total_len`（512）的上下文，超了 sherpa 会悄悄截掉音频，
///   所以热词先按目录项的预算截断（`SegmentRecognizerLoader`）
/// - 带热词时偶尔把提示词当成结果输出（整串热词，或单独的「system」）：这一段不带热词再转一遍
///   （见 `Qwen3ASR.decodeAvoidingPromptLeak`）
/// - sherpa 自己会截掉「只在两三个 token 间打转」的复读；其余复读（含整句重复到输出上限）、
///   不带热词仍有的泄漏（单独的「system」），由外面套的 `GuardedRecognizer` 处理。
///   不带热词重转后输出里仍有整串热词，就是会上真说了，不再当泄漏
public final class Qwen3ASRRecognizer: SegmentRecognizer {
    private let recognizer: OpaquePointer
    private let hotwords: [String]

    /// - Parameters:
    ///   - directory: 目录项的模型目录，文件要先按大小确认齐全（由 `SegmentRecognizerLoader` 给出）
    ///   - name: 错误信息里的模型名
    ///   - contextTokens: 提示词 + 音频 + 输出的上限（sherpa `max_total_len`）；nil 用 sherpa 的默认值（512）
    ///   - hotwords: 已截到预算内的热词
    init(directory: URL, name: String, contextTokens: Int?, hotwords: [String] = [], threads: Int = 4,
         debug: Bool = false) throws {
        func path(_ name: String) -> UnsafeMutablePointer<CChar> {
            strdup(directory.appendingPathComponent(name).path)
        }
        let frontend = path("conv_frontend.onnx"), encoder = path("encoder.int8.onnx")
        let decoder = path("decoder.int8.onnx"), tokenizer = path("tokenizer")
        let cpu = strdup("cpu"), greedy = strdup("greedy_search")
        let words = strdup(SherpaHotwords.argument(hotwords))
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
        config.model_config.qwen3_asr.max_total_len = Int32(contextTokens ?? 0)
        config.model_config.qwen3_asr.max_new_tokens = 128
        config.model_config.qwen3_asr.temperature = 1e-6
        config.model_config.qwen3_asr.top_p = 0.8
        config.model_config.qwen3_asr.seed = 42
        config.model_config.qwen3_asr.hotwords = UnsafePointer(words)
        guard let r = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw SherpaModelError.engineUnavailable(model: name)
        }
        recognizer = r
        self.hotwords = SherpaHotwords.sanitize(hotwords)
    }

    deinit { SherpaOnnxDestroyOfflineRecognizer(recognizer) }

    public func recognize(_ samples: ArraySlice<Float>) throws -> SegmentRecognition {
        let text = Qwen3ASR.decodeAvoidingPromptLeak(hotwords: hotwords) { rawText(samples, options: $0) }
        return SegmentRecognition(text: text.trimmingCharacters(in: .whitespacesAndNewlines), tokens: nil)
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

/// Qwen3-ASR 的提示词泄漏处理
public enum Qwen3ASR {
    /// 解码一段；输出泄漏了提示词（整串热词、单独的「system」）且这次带了热词时，这一段用按流选项去掉热词再解一次。
    /// 三场真实会议上这样的泄漏都只在带热词时出现，不带热词重转都得到正常内容；对半重转常常仍有一半泄漏而被丢掉
    /// - Parameter decode: 按流选项解码（`[:]` = 用识别器的热词，`["hotwords": ""]` = 不带热词）
    static func decodeAvoidingPromptLeak(hotwords: [String], decode: ([String: String]) -> String) -> String {
        let text = decode([:])
        guard !hotwords.isEmpty,
              ASROutputGuard.problem(in: ASROutputGuard.clean(text), hotwords: hotwords) == .promptLeak else { return text }
        return decode(["hotwords": ""])
    }
}
