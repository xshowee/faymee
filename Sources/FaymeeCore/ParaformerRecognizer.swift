import Foundation
import SherpaOnnxC

/// Paraformer 中文（2023-09-14 int8，唯一带逐字时间的一版）+ 离线标点模型：一段 16 kHz 音频 → 带标点的文字和真实逐字开始时间。
///
/// - 会后转写：`SherpaOfflineTranscriber.paraformer(...)` 每场建一个
/// - 实时字幕定稿：会话开始时建一个，对每句音频直接 `recognize`（不切段、不要 VAD），会话结束释放
/// - 创建时按大小确认 Paraformer 和标点模型文件齐全（坏文件会让 sherpa-onnx `_Exit` 整个进程），然后加载两个模型
/// - 每段识别后单独加标点，标点按字序并回识别结果（标点模型改了字就不用它的标点）；再合并英文单个字母（「a i」→「AI」）
/// - 不支持热词
public final class ParaformerRecognizer: SegmentRecognizer, @unchecked Sendable {
    /// 写进转写稿的引擎名，同目录项 id
    public static let engine = LocalModel.paraformer.id

    private let recognizer: OpaquePointer
    private let punctuation: OpaquePointer

    /// - Parameters:
    ///   - modelDirectory: 模型根目录（下面是 Paraformer 和标点模型各自的目录）
    ///   - threads: 每个模型的推理线程数
    public init(modelDirectory: URL = LocalModel.defaultDirectory, threads: Int = 2) throws {
        let paraformerName = ModelCatalog.builtIn.model(id: LocalModel.paraformer.id)?.name ?? "Paraformer"
        let punctuationName = ModelCatalog.builtIn.model(id: LocalModel.punctuation.id)?.name ?? "标点模型"
        try LocalModel.paraformer.checkFiles(name: paraformerName, in: modelDirectory)
        try LocalModel.punctuation.checkFiles(name: punctuationName, in: modelDirectory)

        let dir = LocalModel.paraformer.directory(in: modelDirectory)
        let model = strdup(dir.appendingPathComponent("model.int8.onnx").path)
        let tokens = strdup(dir.appendingPathComponent("tokens.txt").path)
        let punctModel = strdup(LocalModel.punctuation.directory(in: modelDirectory)
            .appendingPathComponent("model.int8.onnx").path)
        let cpu = strdup("cpu"), greedy = strdup("greedy_search")
        defer { free(model); free(tokens); free(punctModel); free(cpu); free(greedy) }

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Int32(SpeechSegmentation.sampleRate)
        config.feat_config.feature_dim = 80
        config.model_config.paraformer.model = UnsafePointer(model)
        config.model_config.tokens = UnsafePointer(tokens)
        config.model_config.num_threads = Int32(threads)
        config.model_config.provider = UnsafePointer(cpu)
        config.decoding_method = UnsafePointer(greedy)
        guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw SherpaModelError.engineUnavailable(model: paraformerName)
        }

        var punctConfig = SherpaOnnxOfflinePunctuationConfig()
        punctConfig.model.ct_transformer = UnsafePointer(punctModel)
        punctConfig.model.num_threads = Int32(threads)
        punctConfig.model.provider = UnsafePointer(cpu)
        guard let punctuation = SherpaOnnxCreateOfflinePunctuation(&punctConfig) else {
            SherpaOnnxDestroyOfflineRecognizer(recognizer)
            throw SherpaModelError.engineUnavailable(model: punctuationName)
        }
        self.recognizer = recognizer
        self.punctuation = punctuation
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
        SherpaOnnxDestroyOfflinePunctuation(punctuation)
    }

    public func recognize(_ samples: ArraySlice<Float>) throws -> SegmentRecognition {
        let raw = recognizeRaw(samples)
        let punctuated = punctuate(raw.text).map { ParaformerText.restorePunctuation(raw: raw.text, punctuated: $0) }
        return SegmentRecognition(text: ParaformerText.mergeLetters(punctuated ?? raw.text), tokens: raw.tokens)
    }

    /// sherpa 的原始结果：不带标点的文字 + 逐字开始时间（相对这段音频开头）
    func recognizeRaw(_ samples: ArraySlice<Float>) -> SegmentRecognition {
        let stream = SherpaOnnxCreateOfflineStream(recognizer)
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer {
            SherpaOnnxAcceptWaveformOffline(stream, Int32(SpeechSegmentation.sampleRate), $0.baseAddress, Int32($0.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let r = SherpaOnnxGetOfflineStreamResult(stream) else { return SegmentRecognition(text: "", tokens: nil) }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(r) }
        let text = r.pointee.text.map { String(cString: $0) } ?? ""
        let tokens: [SegmentRecognition.Token]? = r.pointee.timestamps.flatMap { times in
            guard let arr = r.pointee.tokens_arr else { return nil }
            return (0..<Int(r.pointee.count)).compactMap { i in
                arr[i].map { SegmentRecognition.Token(text: String(cString: $0), start: Double(times[i])) }
            }
        }
        return SegmentRecognition(text: text, tokens: tokens)
    }

    /// 标点模型的输出；空文字不调用
    func punctuate(_ text: String) -> String? {
        guard !text.allSatisfy(\.isWhitespace) else { return nil }
        guard let out = SherpaOfflinePunctuationAddPunct(punctuation, text) else { return nil }
        defer { SherpaOfflinePunctuationFreeText(out) }
        return String(cString: out)
    }
}

extension SherpaOfflineTranscriber {
    /// Paraformer 会后转写（转写稿 `engine` 用 `ParaformerRecognizer.engine`）。热词参数忽略：Paraformer 不支持热词
    /// - Parameters:
    ///   - vadModel: 静音切段模型，App 里传 `SileroVAD.bundledModel`
    ///   - threads: Paraformer 和标点模型各自的推理线程数
    public static func paraformer(modelDirectory: URL = LocalModel.defaultDirectory, vadModel: URL?,
                                  threads: Int = 4) -> SherpaOfflineTranscriber {
        let model = ModelCatalog.builtIn.model(id: LocalModel.paraformer.id)!
        return SherpaOfflineTranscriber(model: model, catalog: .builtIn, modelDirectory: modelDirectory,
                                        vadModel: vadModel) { _ in
            try ParaformerRecognizer(modelDirectory: modelDirectory, threads: threads)
        }
    }
}

/// Paraformer 文字后处理（纯函数）
enum ParaformerText {
    /// 把标点模型加的标点按字序并回 Paraformer 原文：字和空格都用原文的，只取标点模型插进来的标点。
    ///
    /// - 标点模型应当只插标点、不改字；它改了字（多字、少字、换字）就放弃标点，返回原文（这一段只在段尾断句）
    /// - 大小写不算改字（用原文的）；开头的标点丢掉
    /// - 标点模型会去掉中英文之间的空格，这里保留原文的空格；只是中文标点后面紧跟的空格去掉（「ppt， 你」→「ppt，你」）
    /// - 原文本身可能带撇号等符号（「don't」），照原文保留
    static func restorePunctuation(raw: String, punctuated: String) -> String {
        let source = raw.filter { !$0.isWhitespace }
        var marks = [String](repeating: "", count: source.count)
        var j = source.startIndex
        var k = 0
        for p in punctuated where !p.isWhitespace {
            // 原文的符号标点模型没照抄，跳过
            while j < source.endIndex, source[j].isPunctuation, !p.isPunctuation, source[j] != p {
                j = source.index(after: j)
                k += 1
            }
            if j < source.endIndex, source[j].lowercased() == p.lowercased() {
                j = source.index(after: j)
                k += 1
            } else if p.isPunctuation {
                if k > 0 { marks[k - 1].append(p) }
            } else {
                return raw
            }
        }
        guard source[j...].allSatisfy(\.isPunctuation) else { return raw }

        var out = ""
        var k2 = 0
        var dropSpace = false
        for c in raw {
            if c.isWhitespace {
                if !dropSpace { out.append(c) }
                continue
            }
            out.append(c)
            out += marks[k2]
            dropSpace = !marks[k2].isEmpty && !marks[k2].allSatisfy(\.isASCII)
            k2 += 1
        }
        return out
    }

    private static let singleLetters = try! NSRegularExpression(pattern: "(?<![A-Za-z])[a-z](?:\\s+[a-z])+(?![A-Za-z])")

    /// 英文后处理：连续的单个小写字母（Paraformer 把念出来的缩写拆成一个个字母）合并并转大写：
    /// 「a i」→「AI」，「d r flow」→「DR flow」。单词、单独一个字母、被标点隔开的字母不动
    static func mergeLetters(_ text: String) -> String {
        let ns = text as NSString
        var out = text
        for match in singleLetters.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let letters = ns.substring(with: match.range).filter { !$0.isWhitespace }.uppercased()
            out = (out as NSString).replacingCharacters(in: match.range, with: letters)
        }
        return out
    }
}
