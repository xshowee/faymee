import AVFoundation

/// 流式转写引擎，供实时字幕用。形状仿照 `Transcriber`：实时字幕会话只依赖这个协议，换引擎只改 App 里的一处
public protocol StreamingTranscriber: AnyObject {
    /// 准备引擎所需资源（下载模型等），已就绪时立即返回
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    /// 开始一次流式转写。立即返回；准备分析器期间送入的音频由实现缓存，不丢。
    /// 启动失败也不抛错，而是从 `events` 发出 `.failed`。音频格式转换在实现内部
    func start(format: AVAudioFormat, hotwords: [String]) -> any StreamingTranscription
}

/// 一次流式转写。事件里的时间都在调用方送音频时给的时间线上（见 `append`）：实现按样本数计时，
/// 再按每块实际送进识别器的音频的位置换算（`StreamingAudioTimeline`），中途丢过音频也对得上
public protocol StreamingTranscription: AnyObject {
    /// 引擎发出的事件。`finish()` 后吐完剩余的定稿句子再结束；`cancel()` 后尽快结束；出错时发出 `.failed` 后结束
    var events: AsyncStream<StreamingTranscriptionEvent> { get }
    /// 送入一块音频（格式同 `start` 时给的）。time 是它开头在调用方时间线上的位置（秒），
    /// 实时字幕用录音里的秒数（按墙钟换算）。不阻塞，可以在任意线程调用
    func append(_ buffer: AVAudioPCMBuffer, at time: TimeInterval)
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

/// 把识别器按样本数计的时间（从这次转写送入的第一块音频开头算起）换算到调用方的时间线上。
///
/// 送进识别器的音频可能中途丢过一段（分路缓冲满了丢最旧的、积压太多丢最旧的、录音停滞后重启），
/// 识别器察觉不到，之后按样本数算出的时间会偏早。所以记下每块实际送进去的音频在调用方时间线上的位置：
/// 和按样本数推算的位置差得超过 `tolerance` 就从这块重新对齐。只记对齐的点，连续送几个小时也只有几条
struct StreamingAudioTimeline: Sendable {
    /// 每块的位置取采集线程收到它的时刻，有零点几秒的抖动，差这么多以内不算丢了音频
    static let tolerance: TimeInterval = 0.5

    /// 从识别器时间 engine 起，对应调用方时间线上的 time。按 engine 递增
    private var anchors: [(engine: TimeInterval, time: TimeInterval)] = []
    /// 已送进识别器的秒数
    private var fed: TimeInterval = 0

    /// 一块 duration 秒的音频送进了识别器，它开头在调用方时间线上的位置是 time
    mutating func record(duration: TimeInterval, at time: TimeInterval) {
        if anchors.isEmpty || abs(self.time(at: fed) - time) > Self.tolerance {
            anchors.append((fed, time))
        }
        fed += duration
    }

    /// 识别器时间对应的调用方时间。还没送过音频时原样返回
    func time(at engineTime: TimeInterval) -> TimeInterval {
        // 结果一般落在最近送入的音频里，从后往前找
        guard let anchor = anchors.last(where: { $0.engine <= engineTime }) ?? anchors.first else { return engineTime }
        return anchor.time + (engineTime - anchor.engine)
    }
}
