import Foundation
import Testing
@testable import FaymeeCore

/// 实时字幕按设置里选中的目录项建引擎；所选模型没下载时退回 SpeechAnalyzer
struct LiveCaptionEngineChoiceTests {
    private let catalog = ModelCatalog.builtIn
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

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

    @Test func 选了SpeechAnalyzer时用SpeechAnalyzer() throws {
        let choice = LiveCaptionEngineChoice(selected: catalog.model(id: ModelCatalog.speechAnalyzerID), directory: dir)

        #expect(choice.engine is SpeechAnalyzerStreamingTranscriber)
        #expect(choice.modelID == ModelCatalog.speechAnalyzerID)
        #expect(choice.fallback == nil)
    }

    @Test func 选了X_ASR且已下载时用X_ASR() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try placeFiles(of: .xASR960)

        let choice = LiveCaptionEngineChoice(selected: catalog.model(id: LocalModel.xASR960.id), directory: dir)

        let engine = try #require(choice.engine as? SherpaStreamingTranscriber)
        #expect(engine.model == .xASR960)
        #expect(choice.modelID == LocalModel.xASR960.id)
        #expect(choice.fallback == nil)
    }

    @Test func 选了X_ASR但没下载完时退回SpeechAnalyzer并说明() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        // 少一个文件（比如下载到一半）
        try placeFiles(of: LocalModel(id: LocalModel.xASR480.id, directoryName: LocalModel.xASR480.directoryName,
                                      files: Array(LocalModel.xASR480.files.dropLast())))
        let selected = try #require(catalog.model(id: LocalModel.xASR480.id))

        let choice = LiveCaptionEngineChoice(selected: selected, directory: dir)

        #expect(choice.engine is SpeechAnalyzerStreamingTranscriber)
        #expect(choice.modelID == ModelCatalog.speechAnalyzerID)
        #expect(choice.fallback == selected)
    }

    @Test func 没有选中项时用SpeechAnalyzer() {
        let choice = LiveCaptionEngineChoice(selected: nil, directory: dir)

        #expect(choice.engine is SpeechAnalyzerStreamingTranscriber)
        #expect(choice.fallback == nil)
    }
}
