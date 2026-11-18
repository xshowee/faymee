import Foundation
import SherpaOnnxC

/// sherpa-onnx 在线（流式）transducer 识别器的薄封装：建识别器、建流、取结果。只在一个线程里用
final class OnlineRecognizer {
    let handle: OpaquePointer

    /// 加载模型。文件要先确认齐全（`LocalModel.isDownloaded`）。有热词时用 `modified_beam_search`，
    /// 并给出 sentencepiece 词表让 sherpa-onnx 把热词切成模型的 token；词表准备不出来时不用热词
    init(model: LocalModel, directory: URL, threads: Int, hotwords: [String]) throws {
        let dir = model.directory(in: directory)
        func path(prefix: String) -> String? {
            model.files.first { $0.path.hasPrefix(prefix) }.map { dir.appendingPathComponent($0.path).path }
        }
        guard let encoder = path(prefix: "encoder"), let decoder = path(prefix: "decoder"),
              let joiner = path(prefix: "joiner"), let tokens = path(prefix: "tokens.txt")
        else { throw SherpaStreamingError.engineUnavailable }
        let vocab = hotwords.isEmpty ? nil : path(prefix: "bpe.model").flatMap(Self.hotwordsVocab(for:))

        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            strings.append(p)
            return UnsafePointer(p)
        }
        // 全部字段先清零：sherpa-onnx 把 0 / NULL 当“用默认值”
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = Int32(MonoResampler.sampleRate)
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = c(encoder)
        config.model_config.transducer.decoder = c(decoder)
        config.model_config.transducer.joiner = c(joiner)
        config.model_config.tokens = c(tokens)
        config.model_config.num_threads = Int32(threads)
        config.model_config.provider = c("cpu")
        // 说完一句的判定。rule1：一个字都没识别出时尾部静音多久算结束；rule2：识别出字后尾部静音 0.6 秒定稿（spec）；
        // rule3：一句最长 20 秒，到了强制定稿。数值同评估（eval/stream_cmp.py）
        config.enable_endpoint = 1
        config.rule1_min_trailing_silence = 2.4
        config.rule2_min_trailing_silence = 0.6
        config.rule3_min_utterance_length = 20
        if let vocab {
            config.decoding_method = c("modified_beam_search")
            config.max_active_paths = 4
            // X-ASR 的 token 全是 sentencepiece 的 BPE（中文也是“▁的”这样的片段），不是按字
            config.model_config.modeling_unit = c("bpe")
            config.model_config.bpe_vocab = c(vocab.path)
            config.hotwords_score = 1.5
        } else {
            config.decoding_method = c("greedy_search")
        }
        guard let handle = SherpaOnnxCreateOnlineRecognizer(&config) else {
            throw SherpaStreamingError.engineUnavailable
        }
        self.handle = handle
        usesHotwords = vocab != nil
    }

    deinit { SherpaOnnxDestroyOnlineRecognizer(handle) }

    /// 建识别器时准备好了热词词表（有热词、模型带 bpe.model）
    private let usesHotwords: Bool

    /// 识别出的字只往后加、不回头改：`greedy_search` 是这样；`modified_beam_search`（用热词时）的最优路径会变
    var isAppendOnly: Bool { !usesHotwords }

    /// 建一个识别流。热词按流传入，sherpa-onnx 用“/”分隔
    func makeStream(hotwords: [String]) -> OpaquePointer {
        let words = hotwords.map(Self.spacedForBPE).filter { !$0.isEmpty }
        if usesHotwords, !words.isEmpty,
           let stream = SherpaOnnxCreateOnlineStreamWithHotwords(handle, words.joined(separator: "/")) {
            return stream
        }
        return SherpaOnnxCreateOnlineStream(handle)
    }

    /// X-ASR 的词表里每个汉字是单独的“▁字”（训练文本里汉字之间有空格），sentencepiece 切“支付模块”会切成
    /// “▁支”“付模块”这类模型从不输出的片段，热词就对不上。所以汉字前后加空格，英文单词照旧。“/”是分隔符，换成空格
    static func spacedForBPE(_ word: String) -> String {
        var out = ""
        for c in word.replacingOccurrences(of: "/", with: " ") {
            if c.isASCII || c.isWhitespace {
                out.append(c)
            } else {
                out += " \(c) "
            }
        }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 当前这句（上次 endpoint 之后）到目前的结果
    func result(of stream: OpaquePointer) -> OnlineResult {
        guard let json = SherpaOnnxGetOnlineStreamResultAsJson(handle, stream) else { return OnlineResult() }
        defer { SherpaOnnxDestroyOnlineStreamResultJson(json) }
        return (try? OnlineResult(json: Data(String(cString: json).utf8))) ?? OnlineResult()
    }

    // MARK: - 热词词表

    /// sherpa-onnx 切热词要的是 sentencepiece 导出的文本词表（每行“片段\t分数”，`spm_export_vocab` 的格式），
    /// 不是模型包里带的二进制 `bpe.model`。这里从 `bpe.model`（protobuf）里读出片段和分数写成词表，
    /// 放在临时目录（按 bpe.model 的大小和修改时间命名，换了模型自然换文件）。读不出来返回 nil（不用热词）
    static func hotwordsVocab(for bpeModel: String) -> URL? {
        let url = URL(fileURLWithPath: bpeModel)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: bpeModel),
              let size = (attributes[.size] as? NSNumber)?.int64Value
        else { return nil }
        let stamp = Int((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let vocab = FileManager.default.temporaryDirectory
            .appendingPathComponent("faymee-bpe-\(size)-\(stamp).vocab")
        if FileManager.default.fileExists(atPath: vocab.path) { return vocab }
        guard let data = try? Data(contentsOf: url),
              let pieces = SentencePieceModel.pieces(in: data), !pieces.isEmpty
        else { return nil }
        let text = pieces.map { "\($0.piece)\t\($0.score)" }.joined(separator: "\n") + "\n"
        do {
            try Data(text.utf8).write(to: vocab, options: .atomic)
        } catch {
            return nil
        }
        return vocab
    }
}

/// 一段（上次 endpoint 之后）到目前的识别结果，时间都是识别器时间（秒）
struct OnlineResult {
    /// 这一段的 token 和它被识别出的位置。开头的标点已去掉：识别器常在上一段 endpoint 之后才补出上一句的句号，
    /// 它属于上一句（已经发出去了），不该出现在这一句开头
    private var tokens: [(text: String, time: Double)] = []

    /// 一个 token 的时间只是它被识别出的那一帧；句子结束取最后一个字再加这么多，算上它本身的长度。
    /// 对照 two-speakers-zh.m4a 的真值：每段最后一个字的时间比说完早约 0.3 秒
    static let lastTokenLength = 0.3

    private struct Raw: Decodable {
        var tokens: [String]?
        var timestamps: [Double]?
        var start_time: Double?
    }

    init() {}

    /// sherpa-onnx 的 JSON 结果：`tokens`、`timestamps`（相对 `start_time`，即这一段的开头）
    init(json: Data) throws {
        let raw = try JSONDecoder().decode(Raw.self, from: json)
        let base = raw.start_time ?? 0
        let times = raw.timestamps ?? []
        var tokens = (raw.tokens ?? []).enumerated().map { i, text in
            (text: text.replacingOccurrences(of: "▁", with: " "), time: base + (i < times.count ? times[i] : times.last ?? 0))
        }
        while let first = tokens.first, Self.isPunctuation(first.text) { tokens.removeFirst() }
        self.tokens = tokens
    }

    /// 这一段到目前的文字
    var text: String { Self.join(tokens.map(\.text)) }
    /// 这一段第一个字的位置
    var start: Double { tokens.first?.time ?? 0 }

    /// 按句末标点（。？！?! 和英文句点）切成句子。每句从它第一个字起，到最后一个字再加 `lastTokenLength`，
    /// 不超过下一句的开头，也不超过 limit（已送入的音频长度）
    func sentences(limit: Double) -> [TranscribedSentence] {
        var groups: [[(text: String, time: Double)]] = [[]]
        for (i, token) in tokens.enumerated() {
            groups[groups.count - 1].append(token)
            let next = i + 1 < tokens.count ? tokens[i + 1].text : nil
            if Self.endsSentence(token.text, next: next) { groups.append([]) }
        }
        let pieces = groups.filter { $0.contains { !Self.isPunctuation($0.text) } }
        return pieces.enumerated().map { i, group in
            let start = group[0].time
            let last = group.last { !Self.isPunctuation($0.text) }?.time ?? start
            let next = i + 1 < pieces.count ? pieces[i + 1][0].time : .infinity
            let end = min(last + Self.lastTokenLength, next, limit)
            return TranscribedSentence(start: start, end: max(start, end), text: Self.join(group.map(\.text)))
        }
    }

    private static func isPunctuation(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.allSatisfy { $0.isPunctuation }
    }

    /// 英文句点只在后面是新词（带空格）或段尾时算句末，“3.5”里的不算
    private static func endsSentence(_ token: String, next: String?) -> Bool {
        let t = token.trimmingCharacters(in: .whitespaces)
        if ["。", "？", "！", "?", "!"].contains(t) { return true }
        return t == "." && (next.map { $0.hasPrefix(" ") } ?? true)
    }

    /// 拼起来，只在两边都是 ASCII 字符（英文单词、数字）时保留空格：中文和全角标点前后不要空格
    private static func join(_ tokens: [String]) -> String {
        let chars = Array(tokens.joined())
        var out = ""
        var i = 0
        while i < chars.count {
            guard chars[i].isWhitespace else {
                out.append(chars[i])
                i += 1
                continue
            }
            var j = i
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            if let before = out.last, j < chars.count, before.isASCII, chars[j].isASCII { out.append(" ") }
            i = j
        }
        return out
    }
}

/// 读 sentencepiece 的 `bpe.model`（protobuf `ModelProto`）里的片段和分数。只认需要的字段：
/// `ModelProto.pieces = 1`（重复的 `SentencePiece`），`SentencePiece.piece = 1`（string）、`score = 2`（float）
enum SentencePieceModel {
    static func pieces(in data: Data) -> [(piece: String, score: Float)]? {
        var reader = ProtoReader(bytes: [UInt8](data))
        var result: [(String, Float)] = []
        while !reader.isAtEnd {
            guard let (field, wire) = reader.tag() else { return nil }
            if field == 1, wire == 2 {
                guard let message = reader.lengthDelimited() else { return nil }
                var inner = ProtoReader(bytes: message)
                var piece: String?
                var score: Float = 0
                while !inner.isAtEnd {
                    guard let (f, w) = inner.tag() else { return nil }
                    switch (f, w) {
                    case (1, 2):
                        guard let bytes = inner.lengthDelimited() else { return nil }
                        piece = String(decoding: bytes, as: UTF8.self)
                    case (2, 5):
                        guard let bits = inner.fixed32() else { return nil }
                        score = Float(bitPattern: bits)
                    default:
                        guard inner.skip(wire: w) else { return nil }
                    }
                }
                if let piece { result.append((piece, score)) }
            } else {
                guard reader.skip(wire: wire) else { return nil }
            }
        }
        return result
    }

    private struct ProtoReader {
        let bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index >= bytes.count }

        mutating func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }

        mutating func tag() -> (Int, Int)? {
            guard let key = varint() else { return nil }
            return (Int(key >> 3), Int(key & 7))
        }

        mutating func lengthDelimited() -> [UInt8]? {
            guard let length = varint(), let n = Int(exactly: length), n <= bytes.count - index else { return nil }
            defer { index += n }
            return Array(bytes[index..<index + n])
        }

        mutating func fixed32() -> UInt32? {
            guard bytes.count - index >= 4 else { return nil }
            defer { index += 4 }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[index + $1]) << (8 * $1) }
        }

        mutating func skip(wire: Int) -> Bool {
            switch wire {
            case 0: return varint() != nil
            case 1:
                guard bytes.count - index >= 8 else { return false }
                index += 8
                return true
            case 2: return lengthDelimited() != nil
            case 5: return fixed32() != nil
            default: return false
            }
        }
    }
}
