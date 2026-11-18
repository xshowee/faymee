import FaymeeCore

/// App 用哪个转写引擎。按设置在本机模型（设置里「会后转写」选中的目录项，见 `LocalTranscriptionEngine`）
/// 与在线适配器之间切换，并在 OpenAI 兼容纯文本转写时注入本机参考转写器以保留句级时间轴。
/// 参考转写器固定用 SpeechAnalyzer（不用下载、有真实逐字时间），不随设置变化。
/// name 写进每份转写稿，用来区分是哪个引擎转的（本机是目录项 id）
enum TranscriptionEngine {
    @MainActor
    static func make(
        settings: OnlineModelSettings,
        transport: any HTTPTransport,
        selections: ModelSelections,
        downloads: ModelDownloads
    ) -> (transcriber: any Transcriber, name: String, waitReason: TranscriptionWaitReason?) {
        OnlineTranscriptionEngine.makeEngine(
            settings: settings,
            transport: transport,
            local: {
                LocalTranscriptionEngine.make(selections: selections, downloads: downloads,
                                              vadModel: SileroVAD.bundledModel)
            },
            reference: { SpeechAnalyzerTranscriber() }
        )
    }
}

/// 实时字幕用哪个流式转写引擎：设置里“实时字幕”选中的本机模型，没下载完时退回 SpeechAnalyzer。
/// 固定在本机运行，不走在线模型。每场录音开始时选一次，录音中改设置从下一场起生效
enum LiveCaptionEngine {
    @MainActor
    static func make(selections: ModelSelections) -> LiveCaptionEngineChoice {
        LiveCaptionEngineChoice(selected: selections.selected(for: .liveCaptions),
                                directory: LocalModel.defaultDirectory)
    }
}
