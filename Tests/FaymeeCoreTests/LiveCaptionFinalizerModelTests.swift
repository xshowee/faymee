import Foundation
import Testing
@testable import FaymeeCore

/// 定稿模型按设置里“实时字幕定稿”选中的目录项建；“不用”或没下载完（含依赖）时不定稿
struct LiveCaptionFinalizerModelTests {
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

    @Test func 不用时不定稿() {
        #expect(LiveCaptionFinalizerModel(selected: nil, directory: dir) == nil)
    }

    @Test func 不是定稿用的模型不定稿() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try placeFiles(of: .xASR480)
        #expect(LiveCaptionFinalizerModel(selected: catalog.model(id: LocalModel.xASR480.id), directory: dir) == nil)
    }

    @Test(arguments: [LocalModel.paraformer, LocalModel.funASRNano])
    func 已下载时用所选模型定稿(model: LocalModel) throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try placeFiles(of: model)
        try placeFiles(of: .punctuation)

        let finalizer = LiveCaptionFinalizerModel(selected: catalog.model(id: model.id), directory: dir)
        #expect(finalizer?.id == model.id)
    }

    @Test func Paraformer的标点模型没下载时不定稿() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try placeFiles(of: .paraformer)
        #expect(LiveCaptionFinalizerModel(selected: catalog.model(id: LocalModel.paraformer.id), directory: dir) == nil)
    }

    @Test func 没下载完时不定稿() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try placeFiles(of: LocalModel(id: LocalModel.funASRNano.id, directoryName: LocalModel.funASRNano.directoryName,
                                      files: Array(LocalModel.funASRNano.files.dropLast())))
        #expect(LiveCaptionFinalizerModel(selected: catalog.model(id: LocalModel.funASRNano.id), directory: dir) == nil)
    }
}
