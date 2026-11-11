import AVFoundation
import Speech

/// 实时字幕的暂定引擎：系统 SpeechAnalyzer 的流式输入，打开临时结果。
/// 用的是和会后转写同一份中文模型（`SpeechAnalyzerTranscriber`），不另外下载
public final class SpeechAnalyzerStreamingTranscriber: StreamingTranscriber {
    public init() {}

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await SpeechAnalyzerTranscriber().prepare(progress: progress)
    }

    public func start(format: AVAudioFormat, hotwords: [String]) -> any StreamingTranscription {
        SpeechAnalyzerStreamingTranscription(format: format, hotwords: hotwords)
    }
}

/// AVAudioPCMBuffer 不是 Sendable。送入后只在转写任务里读，调用方不再改它
private struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

private struct StreamingFormatError: LocalizedError {
    var errorDescription: String? { "系统语音识别不支持当前麦克风的音频格式" }
}

private final class SpeechAnalyzerStreamingTranscription: StreamingTranscription, @unchecked Sendable {
    let events: AsyncStream<StreamingTranscriptionEvent>
    private let output: AsyncStream<StreamingTranscriptionEvent>.Continuation
    private let input: AsyncStream<AudioChunk>.Continuation
    private var task: Task<Void, Never>?

    /// 分析器跟不上时最多积压这么多块（采集约 0.1 秒一块，约 1 分钟），再多丢最旧的
    private static let backlog = 600

    init(format: AVAudioFormat, hotwords: [String]) {
        (events, output) = AsyncStream.makeStream()
        let audio: AsyncStream<AudioChunk>
        (audio, input) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(Self.backlog))
        let output = output
        task = Task(priority: .userInitiated) {
            do {
                try await Self.run(audio, format: format, hotwords: hotwords, output: output)
            } catch where !Task.isCancelled && !(error is CancellationError) {
                output.yield(.failed(error.localizedDescription))
            } catch {}
            output.finish()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) { input.yield(AudioChunk(buffer: buffer)) }
    func finish() { input.finish() }

    func cancel() {
        input.finish()
        task?.cancel()
    }

    private static func run(_ audio: AsyncStream<AudioChunk>, format: AVAudioFormat, hotwords: [String],
                            output: AsyncStream<StreamingTranscriptionEvent>.Continuation) async throws {
        // fastResults：临时结果约 1 秒一出（不加时约 12 秒才出一批），定稿仍约十几秒一段
        let module = try await SpeechAnalyzerTranscriber.makeModule(reportingOptions: [.volatileResults, .fastResults])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module],
                                                                                considering: format),
              let converter = Converter(from: format, to: analyzerFormat)
        else { throw StreamingFormatError() }

        let context = AnalysisContext()
        if !hotwords.isEmpty { context.contextualStrings[.general] = hotwords }
        // 用完即释放模型；会话暂停、结束时调用方取消或结束这次转写
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        try await analyzer.setContext(context)
        let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()

        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // 先开始读结果再启动分析
                group.addTask { try await collect(module.results, output: output) }
                try await analyzer.start(inputSequence: inputs)
                // 取消时 AsyncStream 的迭代直接结束
                for await chunk in audio {
                    if let converted = try converter.convert(chunk.buffer) {
                        feed.yield(AnalyzerInput(buffer: converted))
                    }
                }
                feed.finish()
                try Task.checkCancellation()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                try await group.waitForAll()
            }
        } onCancel: {
            feed.finish()
            Task { await analyzer.cancelAndFinishNow() }
        }
        try Task.checkCancellation()
    }

    /// 临时结果原样（拼上还没断完的半句）发出；定稿结果的字和留着的半句一起断句，
    /// 断完的句子发出，末尾没说完的半句留给下一段定稿结果，期间仍作为临时文字显示
    private static func collect(_ results: SpeechTranscriber.Results,
                                output: AsyncStream<StreamingTranscriptionEvent>.Continuation) async throws {
        var open: [TimedToken] = []
        func showVolatile(_ tokens: [TimedToken]) {
            let pending = SentenceSplitter.sentence(tokens)
            output.yield(.volatile(pending?.text ?? "", start: pending?.start ?? 0))
        }
        for try await result in results {
            let tokens = Self.tokens(of: result)
            if result.isFinal {
                let split = SentenceSplitter.splitKeepingOpen(open + tokens)
                for sentence in split.closed { output.yield(.sentence(sentence)) }
                open = split.open
                showVolatile(open)
            } else {
                showVolatile(open + tokens)
            }
        }
        if let last = SentenceSplitter.sentence(open) { output.yield(.sentence(last)) }
    }

    private static func tokens(of result: SpeechTranscriber.Result) -> [TimedToken] {
        var tokens: [TimedToken] = []
        for run in result.text.runs {
            tokens.append(SpeechAnalyzerTranscriber.token(String(result.text[run.range].characters),
                                                          range: run.audioTimeRange, previous: tokens.last,
                                                          result: result.range, length: .infinity))
        }
        return tokens
    }
}

/// 把采集的格式转换成分析器要的格式（如 48 kHz Float32 → 16 kHz Int16）。
/// 重采样有内部状态，同一次转写里一直用同一个转换器
private final class Converter {
    private let converter: AVAudioConverter?
    private let output: AVAudioFormat

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        self.output = output
        if input == output {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
            self.converter = converter
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error, let error { throw error }
        return converted.frameLength > 0 ? converted : nil
    }
}
