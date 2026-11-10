import FaymeeCore

/// App 用哪个转写引擎。换引擎只改这里；name 写进每份转写稿，用来区分是哪个引擎转的
enum TranscriptionEngine {
    static func make() -> (transcriber: any Transcriber, name: String) {
        (SpeechAnalyzerTranscriber(), "apple/speechanalyzer")
    }
}
