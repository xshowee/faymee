import AVFoundation
import Speech

public enum SpeechAnalyzerTranscriberError: LocalizedError {
    case unavailable
    case unsupportedLocale

    public var errorDescription: String? {
        switch self {
        case .unavailable: "本机无法使用系统语音识别"
        case .unsupportedLocale: "系统语音识别不支持中文（普通话）"
        }
    }
}

/// 用系统自带的 SpeechAnalyzer + SpeechTranscriber 转写中文（普通话），全程在本机完成。
/// 暂定引擎，与 sherpa-onnx 的对比见 ticket 09
public final class SpeechAnalyzerTranscriber: Transcriber {
    public init() {}

    public func prepare(progress: @escaping (Double) -> Void) async throws {
        let module = try await Self.makeModule()
        // 已装好时返回 nil。不能用 AssetInventory.status 判断：资源装好但本 App 未登记过时它也报 .supported
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let observation = request.progress.observe(\.fractionCompleted, options: [.initial]) { p, _ in
                progress(p.fractionCompleted)
            }
            defer { observation.invalidate() }
            try await withTaskCancellationHandler {
                try await request.downloadAndInstall()
            } onCancel: {
                request.progress.cancel()
            }
        }
        progress(1)
    }

    public func transcribe(audio: URL, hotwords: [String],
                           progress: @escaping (Double) -> Void) async throws -> [TranscribedSentence] {
        let module = try await Self.makeModule()
        let file = try AVAudioFile(forReading: audio)
        let length = Double(file.length) / file.processingFormat.sampleRate

        let context = AnalysisContext()
        if !hotwords.isEmpty { context.contextualStrings[.general] = hotwords }
        // 低优先级运行，不影响整理和界面；用完即释放模型（中文资源约 360 MB）
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .utility, modelRetention: .whileInUse))
        try await analyzer.setContext(context)

        let sentences = try await withTaskCancellationHandler {
            // 先开始读结果再启动分析，避免依赖结果序列的缓冲
            async let collected = Self.collect(module.results, length: length, progress: progress)
            do {
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
            return try await collected
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
        // 取消后结果序列会正常结束，只是不完整；不能把半份结果当成功返回
        try Task.checkCancellation()
        return sentences
    }

    /// 会后转写只要最终结果和逐字时间：不要中间结果，也不要候选。实时字幕另加临时结果，模型是同一份
    static func makeModule(reportingOptions: Set<SpeechTranscriber.ReportingOption> = []) async throws
        -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw SpeechAnalyzerTranscriberError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN"))
        else { throw SpeechAnalyzerTranscriberError.unsupportedLocale }
        return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: reportingOptions,
                                 attributeOptions: [.audioTimeRange])
    }

    private static func collect(_ results: SpeechTranscriber.Results, length: TimeInterval,
                                progress: @escaping (Double) -> Void) async throws -> [TranscribedSentence] {
        // 一句话可能跨两段结果，所以先收齐所有段的逐字结果再统一断句
        var tokens: [TimedToken] = []
        for try await result in results {
            var previous: TimedToken?
            for run in result.text.runs {
                let token = token(String(result.text[run.range].characters), range: run.audioTimeRange,
                                  previous: previous, result: result.range, length: length)
                tokens.append(token)
                previous = token
            }
            // 结果按时间顺序约 20 秒出一段，用已出结果的末尾估算进度
            if length > 0 { progress(min(1, result.range.end.seconds / length)) }
        }
        return SentenceSplitter.split(tokens)
    }

    /// 一小段文字的时间，截到录音时长以内。
    /// 没有逐字时间的片段（如引擎补的标点）记成长度为 0，紧接同一段结果里的前一个字，段首则放在这段开头。
    /// 不能退回整段结果的时间：那会让它横跨约 20 秒，断句、合盖空白判断和高亮都会错
    static func token(_ text: String, range: CMTimeRange?, previous: TimedToken?,
                      result: CMTimeRange, length: TimeInterval) -> TimedToken {
        if let range {
            return TimedToken(text: text, start: min(range.start.seconds, length), end: min(range.end.seconds, length))
        }
        let at = previous?.end ?? min(result.start.seconds, length)
        return TimedToken(text: text, start: at, end: at)
    }
}
