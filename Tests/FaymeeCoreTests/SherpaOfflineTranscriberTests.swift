import Foundation
import Testing
@testable import FaymeeCore

private func resource(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "m4a", subdirectory: "Resources"))
}

/// 仓库里打进 App 的静音切段模型（scripts/fetch-vad-model.sh 下载，被 git 忽略）
private let repoVADModel = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/VAD/silero_vad.onnx")
private let vadPresent = (try? SileroVAD.check(repoVADModel)) != nil

/// 按顺序回放文字的识别器；记录收到的每段样本数
private final class FakeRecognizer: SegmentRecognizer, @unchecked Sendable {
    var texts: [String]
    private(set) var received: [Int] = []
    /// 每次识别前调用（参数是第几段）
    var onRecognize: (Int) -> Void = { _ in }

    init(texts: [String]) { self.texts = texts }

    func recognize(_ samples: ArraySlice<Float>) throws -> SegmentRecognition {
        onRecognize(received.count)
        received.append(samples.count)
        return SegmentRecognition(text: texts.isEmpty ? "" : texts.removeFirst(), tokens: nil)
    }
}

/// 一个装着假模型文件的目录 + 只有这个模型的目录（catalog）
private struct Fixture {
    let root: URL
    let vad: URL
    let asr = LocalModel(id: "test/asr", directoryName: "asr", files: [
        ModelFile(path: "model.onnx", size: 1000, sha256: "", downloadURLs: []),
        ModelFile(path: "sub/tokens.txt", size: 200, sha256: "", downloadURLs: []),
    ])
    let punct = LocalModel(id: "test/punct", directoryName: "punct", files: [
        ModelFile(path: "punct.onnx", size: 300, sha256: "", downloadURLs: []),
    ])
    var catalog: ModelCatalog {
        ModelCatalog(models: [
            CatalogModel(id: asr.id, roles: [.transcription], family: .sherpaParaformer, source: .download(asr),
                         name: "测试模型", dependencies: [punct.id, ModelCatalog.sileroVADID]),
            CatalogModel(id: punct.id, roles: [], family: .sherpaPunctuation, source: .download(punct), name: "标点模型"),
        ])
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        vad = root.appendingPathComponent("VAD/silero_vad.onnx")
        for (model, file) in [(asr, asr.files[0]), (asr, asr.files[1]), (punct, punct.files[0])] {
            try place(model.url(of: file, in: root), size: file.size)
        }
        try place(vad, size: SileroVAD.modelSize)
    }

    /// 放一个指定大小的空文件
    func place(_ url: URL, size: Int64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }

    /// 切段用固定的说话段（秒），不跑 VAD
    func transcriber(speech: [Range<Double>], recognizer: @escaping @Sendable ([String]) throws -> any SegmentRecognizer)
        -> SherpaOfflineTranscriber {
        let ranges = speech.map { Int($0.lowerBound * 16000)..<Int($0.upperBound * 16000) }
        return SherpaOfflineTranscriber(model: catalog.model(id: asr.id)!, catalog: catalog, modelDirectory: root,
                                        vadModel: vad, segmenter: { _, _ in ranges }, makeRecognizer: recognizer)
    }
}

@Suite struct SherpaOfflineTranscriberTests {
    @Test func 按段识别_组装成句子() async throws {
        let f = try Fixture()
        let recognizer = FakeRecognizer(texts: ["大家。今天", "好的"])
        let transcriber = f.transcriber(speech: [1..<5, 9..<12]) { _ in recognizer }

        let sentences = try await transcriber.transcribe(audio: try resource("two-speakers-zh"), hotwords: []) { _ in }

        #expect(sentences.map(\.text) == ["大家。", "今天", "好的"])
        // 没有逐字时间：按字数在说话段（1–5 秒、9–12 秒）里等分
        #expect(sentences.map(\.start) == [1, 3, 9])
        #expect(sentences.map(\.end) == [3, 5, 12])
        // 前后各补 0.3 秒
        #expect(recognizer.received == [Int(4.6 * 16000), Int(3.6 * 16000)])
    }

    @Test func 热词交给识别器_一场转写结束后释放识别器() async throws {
        let f = try Fixture()
        let received = Box<[String]>([])
        let made = WeakBox()
        let transcriber = f.transcriber(speech: [1..<5]) { hotwords in
            received.value = hotwords
            let r = FakeRecognizer(texts: ["好的"])
            made.value = r
            return r
        }

        _ = try await transcriber.transcribe(audio: try resource("two-speakers-zh"), hotwords: ["智能体", "DeerFlow"]) { _ in }

        #expect(received.value == ["智能体", "DeerFlow"])
        #expect(made.value == nil)
    }

    @Test func 进度按已处理的时长只增不减_最后到1() async throws {
        let f = try Fixture()
        let transcriber = f.transcriber(speech: [1..<5, 9..<12, 20..<30]) { _ in FakeRecognizer(texts: []) }
        let values = Box<[Double]>([])

        _ = try await transcriber.transcribe(audio: try resource("two-speakers-zh"), hotwords: []) { values.value.append($0) }

        #expect(values.value == values.value.sorted())
        #expect(values.value.last == 1)
        // 识别进度按段尾在录音里的位置：48.8 秒的录音，第一段（到 5 秒）之后约 10%
        #expect(values.value.contains { $0 > 0.1 && $0 < 0.3 })
    }

    @Test func 取消在下一段之前生效() async throws {
        let f = try Fixture()
        let started = AsyncStream<Void>.makeStream()
        let resume = DispatchSemaphore(value: 0)
        let recognizer = FakeRecognizer(texts: ["一", "二", "三"])
        recognizer.onRecognize = { i in
            guard i == 0 else { return }
            started.continuation.yield()
            resume.wait()
        }
        let transcriber = f.transcriber(speech: [1..<5, 9..<12, 20..<30]) { _ in recognizer }

        let task = Task { try await transcriber.transcribe(audio: try resource("two-speakers-zh"), hotwords: []) { _ in } }
        for await _ in started.stream { break }
        task.cancel()
        resume.signal()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(recognizer.received.count == 1)
    }

    @Test func 模型文件缺失时报清楚的中文错误_不创建识别器() async throws {
        let f = try Fixture()
        try FileManager.default.removeItem(at: f.asr.url(of: f.asr.files[1], in: f.root))
        let created = Box(false)
        let transcriber = f.transcriber(speech: [1..<5]) { _ in created.value = true; return FakeRecognizer(texts: []) }

        let error = SherpaModelError.missing(model: "测试模型", file: "sub/tokens.txt")
        await #expect(throws: error) { try await transcriber.prepare { _ in } }
        await #expect(throws: error) {
            try await transcriber.transcribe(audio: try resource("two-speakers-zh"), hotwords: []) { _ in }
        }
        #expect(!created.value)
        #expect(error.localizedDescription == "测试模型模型缺少文件 sub/tokens.txt，请在设置里重新下载")
    }

    @Test func 模型文件大小不对时报不完整_依赖的辅助模型也查() async throws {
        let f = try Fixture()
        try f.place(f.punct.url(of: f.punct.files[0], in: f.root), size: 299)
        let created = Box(false)
        let transcriber = f.transcriber(speech: [1..<5]) { _ in created.value = true; return FakeRecognizer(texts: []) }

        let error = SherpaModelError.incomplete(model: "标点模型", file: "punct.onnx")
        await #expect(throws: error) {
            try await transcriber.transcribe(audio: try resource("two-speakers-zh"), hotwords: []) { _ in }
        }
        #expect(!created.value)
        #expect(error.localizedDescription == "标点模型文件 punct.onnx 不完整，请在设置里重新下载")
    }

    @Test func 静音切段模型不对时报错() async throws {
        let f = try Fixture()
        try f.place(f.vad, size: 100)
        let transcriber = f.transcriber(speech: [1..<5]) { _ in FakeRecognizer(texts: []) }

        await #expect(throws: SherpaModelError.vadMissing) { try await transcriber.prepare { _ in } }
        #expect(SherpaModelError.vadMissing.localizedDescription == "缺少静音切段模型，请重新安装 Faymee")
    }
}

/// 契约测试：用打进 App 的真实 Silero VAD 跑。模型不在时跳过（先跑 scripts/fetch-vad-model.sh）
@Suite(.enabled(if: vadPresent, "需要 Resources/VAD/silero_vad.onnx，见 scripts/fetch-vad-model.sh"))
struct SileroVADContractTests {
    /// two-speakers-zh.m4a 的真值：6 段话，段间 0.6 秒静音（见 SherpaOnnxDiarizerTests）。
    /// 真值的段尾含 `say` 合成时句末的一点静音，VAD 段尾比它早 0.2–0.45 秒
    private let truth: [Range<Double>] = [0.00..<8.47, 9.07..<17.43, 18.03..<25.48, 26.08..<33.58, 34.18..<41.22,
                                          41.82..<48.21]

    @Test func 切出的说话段与真值的六段话对得上() throws {
        let samples = try SherpaOnnxDiarizer.decode(try resource("two-speakers-zh"))

        let speech = try SileroVAD.speech(in: samples, model: repoVADModel, flag: CancelFlag())

        #expect(speech.count == truth.count)
        for (s, t) in zip(speech, truth) {
            let start = Double(s.lowerBound) / 16000, end = Double(s.upperBound) / 16000
            #expect(abs(start - t.lowerBound) < 0.3 && abs(end - t.upperBound) < 0.5, "\(start)–\(end) vs \(t)")
        }
    }

    @Test func 整个公共层走通_每段不超过10秒且句子落在说话段里() async throws {
        let recognizer = FakeRecognizer(texts: (1...6).map { "第\($0)段。" })
        let transcriber = SherpaOfflineTranscriber(
            model: CatalogModel(id: "test/none", roles: [.transcription], family: .sherpaParaformer, source: .system,
                                name: "测试"),
            vadModel: repoVADModel) { _ in recognizer }

        let sentences = try await transcriber.transcribe(audio: try resource("two-speakers-zh"), hotwords: []) { _ in }

        #expect(sentences.map(\.text) == (1...6).map { "第\($0)段。" })
        #expect(recognizer.received.allSatisfy { $0 <= 10 * 16000 })
        for (s, t) in zip(sentences, truth) {
            #expect(abs(s.start - t.lowerBound) < 0.3 && abs(s.end - t.upperBound) < 0.5, "\(s) vs \(t)")
        }
    }
}

/// 真实 Paraformer 的原始结果（不加标点模型的标点），`punctuate` 模拟标点模型改文字
private final class RawParaformer: SegmentRecognizer, @unchecked Sendable {
    private let paraformer: ParaformerRecognizer
    private let punctuate: (String) -> String

    init(punctuate: @escaping (String) -> String) throws {
        paraformer = try ParaformerRecognizer()
        self.punctuate = punctuate
    }

    func recognize(_ samples: ArraySlice<Float>) throws -> SegmentRecognition {
        let raw = paraformer.recognizeRaw(samples)
        return SegmentRecognition(text: punctuate(raw.text), tokens: raw.tokens)
    }
}

/// 契约测试：真实 Silero VAD + 真实 Paraformer（ticket 01 下载到 ~/Library/Application Support/Faymee/Models）走通公共层
@Suite(.serialized, .enabled(if: vadPresent && LocalModel.paraformer.isDownloaded() && LocalModel.punctuation.isDownloaded(),
                             "需要 Silero VAD 和已下载的 Paraformer、标点模型"))
struct SherpaOfflineParaformerContractTests {
    /// two-speakers-zh.m4a 的六段话（见 SherpaOnnxDiarizerTests）
    private let truth: [Range<Double>] = [0.00..<8.47, 9.07..<17.43, 18.03..<25.48, 26.08..<33.58, 34.18..<41.22,
                                          41.82..<48.21]

    @Test func 关键词落在对应的那段话里_句首时间来自真实逐字时间() async throws {
        // 在第一段「大家好」后面加句号：真实逐字时间里「今」在 1.08 秒（「好」后停顿了半秒多），
        // 按字数比例估算会是 0.9 秒左右
        let transcriber = SherpaOfflineTranscriber(
            model: try #require(ModelCatalog.builtIn.model(id: LocalModel.paraformer.id)), vadModel: repoVADModel) { _ in
            try RawParaformer { $0.hasPrefix("大家好") ? "大家好。" + $0.dropFirst(3) : $0 }
        }

        let sentences = try await transcriber.transcribe(audio: try resource("two-speakers-zh"), hotwords: []) { _ in }

        func turn(of phrase: String) -> Int? {
            guard let s = sentences.first(where: { $0.text.contains(phrase) }) else { return nil }
            return truth.firstIndex { $0.lowerBound - 0.3 <= s.start && s.end <= $0.upperBound + 0.3 }
        }
        #expect(turn(of: "登录模块") == 1)
        #expect(turn(of: "支付模块") == 2)
        #expect(turn(of: "对接接口") == 3)
        #expect(turn(of: "推迟") == 3)
        #expect(sentences.first?.text == "大家好。")
        let second = try #require(sentences.dropFirst().first)
        #expect(second.text.hasPrefix("今天"))
        #expect(abs(second.start - 1.08) < 0.05, "\(second.start)")
        #expect(zip(sentences, sentences.dropFirst()).allSatisfy { $0.end <= $1.start })
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private final class WeakBox: @unchecked Sendable {
    weak var value: AnyObject?
}
