import FaymeeCore

/// App 用哪个转写引擎。按设置在本机 `SpeechAnalyzer` 与在线适配器之间切换，
/// 并在 OpenAI 兼容纯文本转写时注入本机参考转写器以保留句级时间轴；name 写进每份转写稿，用来区分是哪个引擎转的
enum TranscriptionEngine {
    static let localName = "apple/speechanalyzer"

    @MainActor
    static func make(
        settings: OnlineModelSettings,
        transport: any HTTPTransport
    ) -> (transcriber: any Transcriber, name: String, isReady: Bool) {
        OnlineTranscriptionEngine.makeEngine(
            settings: settings,
            transport: transport,
            local: { (SpeechAnalyzerTranscriber(), localName) },
            reference: { SpeechAnalyzerTranscriber() }
        )
    }
}

/// 实时字幕用哪个流式转写引擎。固定在本机运行，不走在线模型
enum LiveCaptionEngine {
    static func make() -> any StreamingTranscriber { SpeechAnalyzerStreamingTranscriber() }
}
