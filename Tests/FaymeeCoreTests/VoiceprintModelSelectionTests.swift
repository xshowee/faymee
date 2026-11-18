import Foundation
import Testing
@testable import FaymeeCore

/// 测试用的第二个声纹模型：需要下载，单文件，阈值与 ERes2Net base 不同
private let secondModelFile = Data("not-a-real-onnx".utf8)
private let secondModel = LocalModel(id: "test/voiceprint-2", directoryName: "voiceprint-2", files: [
    ModelFile(path: "embedding.onnx", size: Int64(secondModelFile.count),
              sha256: "389bc473344fc28560e8fe81ee6d7231dee8b4f4504eb2415388adca5bb4883e",
              downloadURLs: [URL(string: "https://example.com/embedding.onnx")!]),
])
private let base = ModelCatalog.builtIn.model(id: ModelCatalog.eres2netBaseID)!
private let second = CatalogModel(
    id: secondModel.id, roles: [.voiceprint], family: .sherpaSpeakerEmbedding, source: .download(secondModel),
    name: "第二个声纹模型", parameters: ModelParameters(matchThreshold: 0.55), license: "Apache-2.0")

private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FaymeeVoiceprintModel-\(UUID().uuidString)",
                                                                           isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 放一个大小对的文件（内容不对也行：只看大小，哈希在 prepare 时才算）
private func place(size: Int64, at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(size))
    try handle.close()
}

/// 目录项 → 区分引擎和阈值。不需要真实模型
@Suite struct VoiceprintEngineFactoryTests {
    @Test func 打进App的ERes2Netbase_文件在时用它和0点7的阈值() throws {
        let resources = try temporaryDirectory()
        try place(size: SherpaOnnxDiarizer.embeddingModel.size,
                  at: resources.appendingPathComponent("Diarization/\(SherpaOnnxDiarizer.embeddingModel.path)"))

        let engine = SherpaOnnxDiarizer.engine(for: base, bundleResources: resources, modelsRoot: try temporaryDirectory())

        #expect(engine.diarizer?.voiceprintModel == ModelCatalog.eres2netBaseID)
        #expect(engine.voiceprintThreshold == 0.7)
    }

    @Test func 打进App的模型不在时_没有引擎() throws {
        let engine = SherpaOnnxDiarizer.engine(for: base, bundleResources: try temporaryDirectory(),
                                               modelsRoot: try temporaryDirectory())
        #expect(engine.diarizer == nil)
        #expect(SherpaOnnxDiarizer.engine(for: base, bundleResources: nil, modelsRoot: try temporaryDirectory())
            .diarizer == nil)
    }

    @Test func 需要下载的模型_没下载时没有引擎_下好后用它的id和阈值() throws {
        let root = try temporaryDirectory()
        #expect(SherpaOnnxDiarizer.engine(for: second, bundleResources: nil, modelsRoot: root).diarizer == nil)

        try place(size: secondModel.size, at: secondModel.url(in: root))
        let engine = SherpaOnnxDiarizer.engine(for: second, bundleResources: nil, modelsRoot: root)

        #expect(engine.diarizer?.voiceprintModel == "test/voiceprint-2")
        #expect(engine.voiceprintThreshold == 0.55)
    }

    /// 下载的文件被换掉（大小对、内容不对）时 prepare 报损坏，不交给 sherpa-onnx
    @Test func 需要下载的模型内容不对时准备报损坏() async throws {
        let root = try temporaryDirectory()
        try place(size: secondModel.size, at: secondModel.url(in: root))
        let diarizer = try #require(SherpaOnnxDiarizer.engine(for: second, bundleResources: nil, modelsRoot: root).diarizer)

        await #expect(throws: SherpaOnnxDiarizerError.downloadedModelCorrupted("embedding.onnx")) {
            try await diarizer.prepare { _ in }
        }
    }

    @Test func 不选或选了别的家族_没有引擎() throws {
        let minutes = try #require(ModelCatalog.builtIn.model(id: LocalModel.qwen3_4B.id))
        #expect(SherpaOnnxDiarizer.engine(for: nil, bundleResources: nil, modelsRoot: try temporaryDirectory())
            .diarizer == nil)
        #expect(SherpaOnnxDiarizer.engine(for: minutes, bundleResources: nil, modelsRoot: try temporaryDirectory())
            .diarizer == nil)
    }

    /// 给 ticket 12 加候选兜底：目录里的声纹模型都能建出引擎（单文件、打进 App 的是已知文件）且带自己的阈值
    @Test func 目录里每个声纹模型都带阈值_且能对应到模型文件() {
        for m in ModelCatalog.builtIn.models where m.family == .sherpaSpeakerEmbedding {
            #expect(m.parameters.matchThreshold != nil, "\(m.id) 没有匹配阈值")
            #expect(m.roles == [.voiceprint], "\(m.id)")
            switch m.source {
            case let .download(local): #expect(local.files.count == 1, "\(m.id) 声纹模型应是单个 onnx 文件")
            case let .bundled(directory, fileName):
                #expect(directory == "Diarization", "\(m.id)")
                #expect(SherpaOnnxDiarizer.models.contains { $0.path == fileName }, "\(m.id) 打进 App 的文件没有哈希")
            case .system: Issue.record("\(m.id) 不能是系统自带")
            }
        }
    }
}

/// 假网络：每次都从头给出整个文件（200）
private struct ServeFile: ModelTransport {
    let data: Data
    func get(_ url: URL, from offset: Int64) async throws -> ModelResponse {
        let data = data
        return ModelResponse(status: 200, contentRange: nil, contentLength: Int64(data.count),
                             body: AsyncThrowingStream { $0.yield(data); $0.finish() })
    }
}

@MainActor
private final class NoMeetings: TranscriptionHost {
    func meeting(_ id: String) -> Meeting? { nil }
    func setTranscription(_ state: TranscriptionState, for id: String) {}
    func setDiarization(_ state: DiarizationState?, for id: String) {}
}

private final class NoTranscriber: Transcriber {
    func prepare(progress: @escaping (Double) -> Void) async throws {}
    func transcribe(audio: URL, hotwords: [String], progress: @escaping (Double) -> Void) async throws
        -> [TranscribedSentence] { [] }
}

/// 设置里「声纹」的选择 → 转写管线的区分引擎和阈值
@MainActor @Suite struct VoiceprintModelBindingTests {
    let suite = "com.faymee.tests.\(UUID())"
    let defaults: UserDefaults
    let selections: ModelSelections
    let downloads: ModelDownloads
    let resources: URL
    private let host = NoMeetings()
    let pipeline: TranscriptionPipeline
    let binding: VoiceprintModelBinding

    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        let catalog = ModelCatalog(models: [base, second])
        selections = ModelSelections(defaults: defaults, catalog: catalog, isExistingInstall: { true })
        downloads = ModelDownloads(catalog: catalog, directory: try temporaryDirectory(),
                                   transport: ServeFile(data: secondModelFile))
        resources = try temporaryDirectory()
        try place(size: SherpaOnnxDiarizer.embeddingModel.size,
                  at: resources.appendingPathComponent("Diarization/\(SherpaOnnxDiarizer.embeddingModel.path)"))
        binding = VoiceprintModelBinding(selections: selections, downloads: downloads, bundleResources: resources)
        let engine = binding.makeEngine()
        pipeline = TranscriptionPipeline(store: MeetingStore(root: try temporaryDirectory()), transcriber: NoTranscriber(),
                                         engine: "fake/1", diarizer: engine.diarizer, host: host)
        pipeline.voiceprintThreshold = engine.voiceprintThreshold
        binding.bind(pipeline)
    }

    /// 选择变化经 Observation 异步送到，等它
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test func 默认用打进App的ERes2Netbase和0点7() {
        #expect(pipeline.voiceprintModel == ModelCatalog.eres2netBaseID)
        #expect(pipeline.voiceprintThreshold == 0.7)
        #expect(pipeline.canDiarize)
    }

    @Test func 切到没下载的模型_区分说话人等下载_下载完成后用新模型和新阈值_切回来恢复() async throws {
        selections.select(second.id, for: .voiceprint)
        try await until { pipeline.voiceprintModel == nil }
        #expect(pipeline.diarizerWaitReason == .modelDownload(id: second.id))
        #expect(pipeline.canDiarize)

        let downloader = try #require(downloads.downloader(for: second))
        downloader.start()
        await downloader.waitUntilFinished()
        #expect(downloader.isReady)

        try await until { pipeline.voiceprintModel == "test/voiceprint-2" }
        #expect(pipeline.voiceprintThreshold == 0.55)
        #expect(pipeline.diarizerWaitReason == nil)
        #expect(pipeline.canDiarize)

        selections.select(base.id, for: .voiceprint)
        try await until { pipeline.voiceprintModel == ModelCatalog.eres2netBaseID }
        #expect(pipeline.voiceprintThreshold == 0.7)
    }

    @Test func 删除所选的下载模型后区分说话人又等下载() async throws {
        selections.select(second.id, for: .voiceprint)
        let downloader = try #require(downloads.downloader(for: second))
        downloader.start()
        await downloader.waitUntilFinished()
        try await until { pipeline.voiceprintModel == "test/voiceprint-2" }

        try await downloader.delete()

        try await until { pipeline.voiceprintModel == nil }
        #expect(pipeline.diarizerWaitReason == .modelDownload(id: second.id))
    }

    @Test func 建管线时所选模型没下载_初值就是等下载() {
        selections.select(second.id, for: .voiceprint)
        let engine = binding.makeEngine()
        #expect(engine.diarizer == nil)
        #expect(engine.waitReason == .modelDownload(id: second.id))
        #expect(engine.voiceprintThreshold == 0.55)
        // 打进 App 的模型文件不在：没有引擎，也不等（没有可下载的东西）
        selections.select(base.id, for: .voiceprint)
        let missing = VoiceprintModelBinding(selections: selections, downloads: downloads, bundleResources: nil)
        #expect(missing.makeEngine().diarizer == nil)
        #expect(missing.makeEngine().waitReason == nil)
    }
}
