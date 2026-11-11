import AVFoundation

/// 流式转写引擎，供实时字幕用。形状仿照 `Transcriber`：实时字幕会话只依赖这个协议，换引擎只改 App 里的一处
public protocol StreamingTranscriber: AnyObject {
    /// 准备引擎所需资源（下载模型等），已就绪时立即返回
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    /// 开始一次流式转写。立即返回；准备分析器期间送入的音频由实现缓存，不丢。
    /// 启动失败也不抛错，而是从 `events` 发出 `.failed`。音频格式转换在实现内部
    func start(format: AVAudioFormat, hotwords: [String]) -> any StreamingTranscription
}

/// 一次流式转写。时间都是相对这次转写收到的第一块音频开头的秒数（按样本数累计），不是墙钟时间
public protocol StreamingTranscription: AnyObject {
    /// 引擎发出的事件。`finish()` 后吐完剩余的定稿句子再结束；`cancel()` 后尽快结束；出错时发出 `.failed` 后结束
    var events: AsyncStream<StreamingTranscriptionEvent> { get }
    /// 送入一块音频（格式同 `start` 时给的）。不阻塞，可以在任意线程调用
    func append(_ buffer: AVAudioPCMBuffer)
    /// 不再送入音频：把已送入的部分识别完、定稿，然后结束 `events`
    func finish()
    /// 丢弃未定稿的部分，尽快结束 `events`，释放模型
    func cancel()
}

public enum StreamingTranscriptionEvent: Hashable, Sendable {
    /// 还没定稿的文字（会变），整体替换上一次的临时文字；空字符串表示没有临时文字。start 是它开头的时间
    case volatile(String, start: TimeInterval)
    /// 定稿的一句。同时清掉临时文字：后面还有没定稿的部分时，引擎紧接着再发一次 `.volatile`
    case sentence(TranscribedSentence)
    /// 出错原因。之后 `events` 结束
    case failed(String)
}
