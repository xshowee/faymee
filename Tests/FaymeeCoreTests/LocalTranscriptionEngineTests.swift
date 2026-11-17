import Foundation
import Testing
@testable import FaymeeCore

/// 会后转写按设置里「会后转写」选中的目录项建转写器（家族 → 适配器）；所选模型没下载完时排队等下载
@MainActor @Suite struct LocalTranscriptionEngineTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FaymeeLocalTranscription-\(UUID().uuidString)")
    private let suite = "FaymeeLocalTranscriptionTests-\(UUID().uuidString)"

    /// 按大小放好模型的每个文件（稀疏文件，不是真模型）
    private func placeFiles(of model: LocalModel) throws {
        for file in model.files {
            let url = model.url(of: file, in: dir)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.size))
            try handle.close()
        }
    }

    private func make(selecting id: String) -> (transcriber: any Transcriber, name: String,
                                                waitReason: TranscriptionWaitReason?) {
        let selections = ModelSelections(defaults: UserDefaults(suiteName: suite)!, isExistingInstall: { true })
        selections.select(id, for: .transcription)
        let downloads = ModelDownloads(directory: dir, transport: URLSessionModelTransport())
        return LocalTranscriptionEngine.make(selections: selections, downloads: downloads, vadModel: nil)
    }

    private func cleanUp() {
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func 选择框里每个会后转写模型都有适配器() {
        for model in ModelCatalog.builtIn.models(for: .transcription) {
            #expect(LocalTranscriptionEngine.transcriber(for: model, modelDirectory: dir, vadModel: nil) != nil,
                    "\(model.id)")
        }
    }

    @Test func 选了SpeechAnalyzer时用它_总是就绪() {
        defer { cleanUp() }
        let engine = make(selecting: ModelCatalog.speechAnalyzerID)
        #expect(engine.transcriber is SpeechAnalyzerTranscriber)
        #expect(engine.name == "apple/speechanalyzer")
        #expect(engine.waitReason == nil)
    }

    @Test func 选了没下载的FunASRNano_排队等下载这个模型_转写稿记目录项id() async throws {
        defer { cleanUp() }
        let engine = make(selecting: LocalModel.funASRNano.id)
        #expect(engine.name == "sherpa-onnx/funasr-nano-int8-2025-12-30")
        #expect(engine.waitReason == .modelDownload(id: "sherpa-onnx/funasr-nano-int8-2025-12-30"))
        // 建的是 Fun-ASR-Nano 的转写器：准备时按它的文件清单检查
        await #expect(throws: SherpaModelError.missing(model: "Fun-ASR-Nano", file: "encoder_adaptor.int8.onnx")) {
            try await engine.transcriber.prepare(progress: { _ in })
        }

        try placeFiles(of: .funASRNano)
        #expect(make(selecting: LocalModel.funASRNano.id).waitReason == nil)
    }

    @Test func 选了Paraformer_标点模型也下好了才就绪() async throws {
        defer { cleanUp() }
        try placeFiles(of: .paraformer)
        let engine = make(selecting: LocalModel.paraformer.id)
        #expect(engine.name == "sherpa-onnx/paraformer-zh-2023-09-14")
        #expect(engine.waitReason == .modelDownload(id: "sherpa-onnx/paraformer-zh-2023-09-14"))
        await #expect(throws: SherpaModelError.missing(model: "标点模型", file: "model.int8.onnx")) {
            try await engine.transcriber.prepare(progress: { _ in })
        }

        try placeFiles(of: .punctuation)
        #expect(make(selecting: LocalModel.paraformer.id).waitReason == nil)
    }
}
