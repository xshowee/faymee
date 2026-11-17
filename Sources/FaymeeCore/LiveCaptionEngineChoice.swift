import Foundation

/// 实时字幕用哪个流式引擎：设置里“实时字幕”选中的目录项。所选模型要下载而还没下载完时，
/// 暂时退回 SpeechAnalyzer（系统自带，不用下载），会中不至于没有字幕；设置里据 `fallback` 说明正在用 SpeechAnalyzer
public struct LiveCaptionEngineChoice {
    public let engine: any StreamingTranscriber
    /// 实际在用的模型 id
    public let modelID: String
    /// 选中了却没用上（没下载完）的模型；用上了所选模型时为 nil
    public let fallback: CatalogModel?

    /// directory 是模型的下载目录（`LocalModel.defaultDirectory`）
    public init(selected: CatalogModel?, directory: URL) {
        if let selected, selected.family == .sherpaOnlineTransducer, let model = selected.download {
            if model.isDownloaded(in: directory) {
                engine = SherpaStreamingTranscriber(model: model, directory: directory)
                modelID = selected.id
                fallback = nil
                return
            }
            fallback = selected
        } else {
            fallback = nil
        }
        engine = SpeechAnalyzerStreamingTranscriber()
        modelID = ModelCatalog.speechAnalyzerID
    }
}
