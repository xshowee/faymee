import Foundation

/// 本机会后转写引擎：设置里「会后转写」选中的目录项 → 转写器（按家族选适配器）。
/// 写进转写稿的引擎名是目录项 id；所选模型（含辅助模型）没下载完时引擎不就绪，排队原因是等下载这个模型。
/// 整段识别家族经 `SegmentRecognizerLoader` 按目录项自己的文件加载（家族 → 适配器见 `ModelFamily.segmentRecognizer`）
public enum LocalTranscriptionEngine {
    /// 目录项的转写器；家族还没接上适配器时为 nil（这样的目录项先设成隐藏）
    /// - Parameters:
    ///   - modelDirectory: 模型根目录（`LocalModel.defaultDirectory`）
    ///   - vadModel: 静音切段模型，App 里传 `SileroVAD.bundledModel`
    public static func transcriber(for model: CatalogModel, catalog: ModelCatalog = .builtIn,
                                   modelDirectory: URL, vadModel: URL?) -> (any Transcriber)? {
        if model.family == .speechAnalyzer { return SpeechAnalyzerTranscriber() }
        return SegmentRecognizerLoader(model: model, catalog: catalog, modelDirectory: modelDirectory).map {
            SherpaOfflineTranscriber(loader: $0, catalog: catalog, modelDirectory: modelDirectory, vadModel: vadModel)
        }
    }

    /// 按现在的选择建本机转写引擎。`waitReason` 为 nil 表示就绪（系统自带的总是就绪）。
    /// 选择不可能为空（「会后转写」没有“不用”）；万一所选家族没有适配器，退回 SpeechAnalyzer
    @MainActor
    public static func make(selections: ModelSelections, downloads: ModelDownloads, vadModel: URL?)
        -> (transcriber: any Transcriber, name: String, waitReason: TranscriptionWaitReason?) {
        if let model = selections.selected(for: .transcription),
           let transcriber = transcriber(for: model, catalog: selections.catalog,
                                         modelDirectory: downloads.directory, vadModel: vadModel) {
            return (transcriber, model.id, downloads.isReady(model) ? nil : .modelDownload(id: model.id))
        }
        return (SpeechAnalyzerTranscriber(), ModelCatalog.speechAnalyzerID, nil)
    }
}
