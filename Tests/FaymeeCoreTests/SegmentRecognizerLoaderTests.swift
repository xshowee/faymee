import Foundation
import Testing
@testable import FaymeeCore

/// 不加载模型的识别器：记下加载时拿到的东西
private final class LoadedRecognizer: SegmentRecognizer, @unchecked Sendable {
    let request: SegmentRecognizerAdapter.Request
    init(_ request: SegmentRecognizerAdapter.Request) { self.request = request }
    func recognize(_ samples: ArraySlice<Float>) throws -> SegmentRecognition {
        SegmentRecognition(text: "", tokens: nil)
    }
}

/// 加载时拿到的东西（加载在转写的后台队列上调用）
private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [SegmentRecognizerAdapter.Request] = []
    func append(_ r: SegmentRecognizerAdapter.Request) { lock.withLock { requests.append(r) } }
    var all: [SegmentRecognizerAdapter.Request] { lock.withLock { requests } }
}

/// 仓库里打进 App 的静音切段模型（scripts/fetch-vad-model.sh 下载，被 git 忽略）
private let repoVADModel = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/VAD/silero_vad.onnx")

/// 同一家族加新模型只加目录项：适配器按目录项自己的 `download`（和依赖的辅助模型）找文件，不按内置模型写死。
/// 用两个假的目录项（与内置的同家族，但目录、文件都不同），文件按大小放好，加载换成记录拿到的位置
@MainActor @Suite struct SegmentRecognizerLoaderTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("FaymeeLoader-\(UUID().uuidString)")

    /// 只有 `#version` 一行的 merges.txt：没有合并规则，每个字节算一个 token
    private static let merges = Data("#version: 0.2\n".utf8)

    private static func file(_ path: String, size: Int64) -> ModelFile {
        ModelFile(path: path, size: size, sha256: "", downloadURLs: [])
    }

    /// 另一个 Fun-ASR-Nano：自己的目录，热词预算 6 token
    private let funASRVariant = CatalogModel(
        id: "test/funasr-nano-variant", roles: [.transcription, .liveFinalize], family: .sherpaFunASRNano,
        source: .download(LocalModel(id: "test/funasr-nano-variant", directoryName: "funasr-nano-variant", files: [
            file("encoder_adaptor.int8.onnx", size: 10),
            file("Qwen3-0.6B/merges.txt", size: Int64(merges.count)),
        ])),
        name: "Fun-ASR-Nano 变体",
        capabilities: ModelCapabilities(punctuation: true, wordTimings: .estimated, hotwords: true),
        parameters: ModelParameters(contextTokens: 512, hotwordTokenBudget: 6))

    /// 另一个标点模型和依赖它的另一个 Paraformer
    private let punctuationVariant = CatalogModel(
        id: "test/punct-variant", roles: [], family: .sherpaPunctuation,
        source: .download(LocalModel(id: "test/punct-variant", directoryName: "punct-variant",
                                     files: [file("model.int8.onnx", size: 7)])),
        name: "标点变体")
    private var paraformerVariant: CatalogModel {
        CatalogModel(
            id: "test/paraformer-variant", roles: [.transcription, .liveFinalize], family: .sherpaParaformer,
            source: .download(LocalModel(id: "test/paraformer-variant", directoryName: "paraformer-variant",
                                         files: [Self.file("model.int8.onnx", size: 5), Self.file("tokens.txt", size: 3)])),
            name: "Paraformer 变体",
            capabilities: ModelCapabilities(punctuation: true, wordTimings: .real, hotwords: false),
            dependencies: [punctuationVariant.id])
    }

    private var catalog: ModelCatalog {
        ModelCatalog(models: ModelCatalog.builtIn.models + [funASRVariant, punctuationVariant, paraformerVariant])
    }

    /// 按大小放好目录项的文件（merges.txt 写真内容，其余是稀疏文件）
    private func place(_ entry: CatalogModel) throws {
        let model = try #require(entry.download)
        for file in model.files {
            let url = model.url(of: file, in: root)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if file.path.hasSuffix("merges.txt") {
                try Self.merges.write(to: url)
            } else {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: UInt64(file.size))
                try handle.close()
            }
        }
    }

    /// 家族的适配器，加载换成记录
    private let recording: (ModelFamily) -> SegmentRecognizerAdapter? = { family in
        family.segmentRecognizer?.replacingLoad { LoadedRecognizer($0) }
    }

    private func loaded(_ recognizer: any SegmentRecognizer) throws -> SegmentRecognizerAdapter.Request {
        let inner = (recognizer as? GuardedRecognizer)?.inner ?? recognizer
        return try #require(inner as? LoadedRecognizer).request
    }

    @Test func 同家族的另一个FunASRNano用自己目录里的文件_热词按自己的tokenizer和预算截() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try place(funASRVariant)
        let loader = try #require(SegmentRecognizerLoader(model: funASRVariant, catalog: catalog,
                                                          modelDirectory: root, adapter: recording))

        let recognizer = try loader.makeRecognizer(hotwords: ["ab", "cd", "ef"], threads: 3)

        #expect(recognizer is GuardedRecognizer)
        #expect(try loaded(recognizer) == SegmentRecognizerAdapter.Request(
            directory: root.appendingPathComponent("funasr-nano-variant"), punctuationDirectory: nil,
            name: "Fun-ASR-Nano 变体", contextTokens: 512,
            // 「ab, cd」是 6 个字节 = 6 个 token，再加「, ef」就超了
            hotwords: ["ab", "cd"], threads: 3))
    }

    @Test func 同家族的另一个Paraformer用自己的文件和自己依赖的标点模型() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try place(paraformerVariant)
        let loader = try #require(SegmentRecognizerLoader(model: paraformerVariant, catalog: catalog,
                                                          modelDirectory: root, adapter: recording))
        // 自己依赖的标点模型没下载：报它缺文件
        #expect(throws: SherpaModelError.missing(model: "标点变体", file: "model.int8.onnx")) {
            try loader.makeRecognizer(hotwords: [], threads: 2)
        }

        try place(punctuationVariant)
        let request = try loaded(try loader.makeRecognizer(hotwords: ["忽略"], threads: 2))
        #expect(request.directory == root.appendingPathComponent("paraformer-variant"))
        #expect(request.punctuationDirectory == root.appendingPathComponent("punct-variant"))
        #expect(request.hotwords == [])
    }

    @Test(.enabled(if: (try? SileroVAD.check(repoVADModel)) != nil, "需要 Silero VAD"))
    func 会后转写按目录项自己的文件加载() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try place(funASRVariant)
        let requests = Requests()
        let transcriber = try #require(LocalTranscriptionEngine.transcriber(
            for: funASRVariant, catalog: catalog, modelDirectory: root, vadModel: repoVADModel,
            adapter: { $0.segmentRecognizer?.replacingLoad { requests.append($0); return LoadedRecognizer($0) } }))
        let audio = try #require(Bundle.module.url(forResource: "two-speakers-zh", withExtension: "m4a",
                                                   subdirectory: "Resources"))

        _ = try await transcriber.transcribe(audio: audio, hotwords: ["ab"]) { _ in }

        #expect(requests.all.map(\.directory) == [root.appendingPathComponent("funasr-nano-variant")])
        #expect(requests.all.first?.hotwords == ["ab"])
    }

    @Test func 实时字幕定稿按目录项自己的文件加载() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try place(paraformerVariant)
        try place(punctuationVariant)
        let finalizer = try #require(LiveCaptionFinalizerModel(selected: paraformerVariant, catalog: catalog,
                                                               directory: root, adapter: recording))
        #expect(finalizer.id == "test/paraformer-variant")
        let request = try loaded(try finalizer.makeRecognizer([]))
        #expect(request.directory == root.appendingPathComponent("paraformer-variant"))
        #expect(request.threads == LiveCaptionFinalizerModel.threads)
    }

    @Test func 热词页按目录项自己的tokenizer算用得上几个() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(HotwordUsage(model: funASRVariant, hotwords: ["ab", "cd", "ef"], modelDirectory: root) == .unknown)
        try place(funASRVariant)
        #expect(HotwordUsage(model: funASRVariant, hotwords: ["ab", "cd", "ef"], modelDirectory: root)
                == .partial(model: "Fun-ASR-Nano 变体", used: 2, total: 3))
        #expect(HotwordUsage(model: funASRVariant, hotwords: ["ab", "cd"], modelDirectory: root) == .all)
    }
}
