import Foundation
import SherpaOnnxC

/// Fun-ASR-Nano（sherpa-onnx `OfflineRecognizerFunASRNanoImpl`）识别一段音频。
///
/// - 输出带标点、数字规整过（`itn` 开）的文字；逐字时间是把段长按 token 平均分的，不是真的，所以不交出去
///   （句子时间按字数估算，见 `SentenceAssembly`）
/// - 提示词由 sherpa 拼：`语音转写成<language>：`，有热词时前面加「请结合上下文信息…热词列表：[a, b]」。
///   热词与提示词、音频（约 16.7 token/秒）、输出共用 512 token 的上下文，超了 sherpa 会悄悄截掉音频，
///   所以热词先按目录项的预算截断（`SegmentRecognizerLoader`）
/// - 只做识别，原样交出模型输出；标记、复读、日文、提示词泄漏由外面套的 `GuardedRecognizer` 处理
public final class FunASRNanoRecognizer: SegmentRecognizer {
    private let recognizer: OpaquePointer

    /// - Parameters:
    ///   - directory: 目录项的模型目录，文件要先按大小确认齐全（由 `SegmentRecognizerLoader` 给出）
    ///   - name: 错误信息里的模型名
    ///   - hotwords: 已截到预算内的热词
    ///   - language: 拼进提示词的语言名（自然语言，如「中文」），空串表示不指定
    init(directory: URL, name: String, hotwords: [String] = [], language: String = FunASRNano.language,
         threads: Int = 4, debug: Bool = false) throws {
        func path(_ name: String) -> UnsafeMutablePointer<CChar> {
            strdup(directory.appendingPathComponent(name).path)
        }
        let encoder = path("encoder_adaptor.int8.onnx"), llm = path("llm.int8.onnx")
        let embedding = path("embedding.int8.onnx"), tokenizer = path("Qwen3-0.6B")
        let cpu = strdup("cpu"), greedy = strdup("greedy_search")
        let system = strdup(FunASRNano.systemPrompt), user = strdup(FunASRNano.userPrompt)
        let lang = strdup(language), words = strdup(SherpaHotwords.argument(hotwords))
        defer { [encoder, llm, embedding, tokenizer, cpu, greedy, system, user, lang, words].forEach { free($0) } }

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Int32(SpeechSegmentation.sampleRate)
        config.feat_config.feature_dim = 80
        config.decoding_method = UnsafePointer(greedy)
        config.model_config.num_threads = Int32(threads)
        config.model_config.provider = UnsafePointer(cpu)
        config.model_config.debug = debug ? 1 : 0
        config.model_config.funasr_nano.encoder_adaptor = UnsafePointer(encoder)
        config.model_config.funasr_nano.llm = UnsafePointer(llm)
        config.model_config.funasr_nano.embedding = UnsafePointer(embedding)
        config.model_config.funasr_nano.tokenizer = UnsafePointer(tokenizer)
        config.model_config.funasr_nano.system_prompt = UnsafePointer(system)
        config.model_config.funasr_nano.user_prompt = UnsafePointer(user)
        // C API 里 0 表示默认值，这里显式写出 sherpa 的默认（同评估）：贪心解码（温度 ≤ 1e-6 即贪心）
        config.model_config.funasr_nano.max_new_tokens = 512
        config.model_config.funasr_nano.temperature = 1e-6
        config.model_config.funasr_nano.top_p = 0.8
        config.model_config.funasr_nano.seed = 42
        config.model_config.funasr_nano.language = UnsafePointer(lang)
        // itn 不走默认值：0 会让提示词变成「…，不进行文本规整」
        config.model_config.funasr_nano.itn = 1
        config.model_config.funasr_nano.hotwords = UnsafePointer(words)
        guard let r = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw SherpaModelError.engineUnavailable(model: name)
        }
        recognizer = r
    }

    deinit { SherpaOnnxDestroyOfflineRecognizer(recognizer) }

    public func recognize(_ samples: ArraySlice<Float>) throws -> SegmentRecognition {
        SegmentRecognition(text: rawText(samples), tokens: nil)
    }

    /// sherpa 的原始输出
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

/// Fun-ASR-Nano 的固定参数
public enum FunASRNano {
    static let systemPrompt = "You are a helpful assistant."
    static let userPrompt = "语音转写："
    public static let language = ""
}
