import AVFoundation
import Foundation

/// OpenAI 兼容语音转写适配器（支持 OpenAI、Groq 及自定义 `/audio/transcriptions` 接口）
public final class OpenAITranscriber: Transcriber, @unchecked Sendable {
    private let config: OnlineEndpointConfig
    private let transport: any HTTPTransport
    private let referenceTranscriber: (any Transcriber)?

    public init(config: OnlineEndpointConfig, transport: any HTTPTransport,
                referenceTranscriber: (any Transcriber)? = nil) {
        self.config = config
        self.transport = transport
        self.referenceTranscriber = referenceTranscriber
    }

    public func prepare(progress: @escaping (Double) -> Void) async throws {
        try Task.checkCancellation()
        try config.validateReady()
        progress(1)
    }

    private static let maxPromptTokens = 224
    private static let maxUploadBytes: Int64 = 24 * 1024 * 1024
    private static let chunkDurationSeconds: TimeInterval = 1200

    public func transcribe(audio: URL, hotwords: [String],
                           progress: @escaping (Double) -> Void) async throws -> [TranscribedSentence] {
        try Task.checkCancellation()
        try config.validateReady()
        progress(0)

        let context = RequestContext(
            endpointURL: try Self.transcriptionsURL(for: config),
            headers: Self.authHeaders(for: config),
            model: config.trimmedModel,
            prompt: Self.buildPrompt(from: hotwords),
            hotwords: hotwords,
            transport: transport,
            referenceTranscriber: referenceTranscriber
        )
        var capabilities = RequestCapabilities(useVerboseJSON: true, includePrompt: context.prompt != nil)

        let attributes = try FileManager.default.attributesOfItem(atPath: audio.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        let sentences: [TranscribedSentence]
        if fileSize <= Self.maxUploadBytes {
            sentences = try await Self.transcribeFile(
                audioURL: audio,
                context: context,
                capabilities: &capabilities,
                progress: progress
            )
        } else {
            sentences = try await Self.transcribeChunked(
                audioURL: audio,
                context: context,
                capabilities: &capabilities,
                progress: progress
            )
        }
        progress(1)
        return sentences
    }

    private struct RequestContext {
        var endpointURL: URL
        var headers: [String: String]
        var model: String
        var prompt: String?
        var hotwords: [String]
        var transport: any HTTPTransport
        var referenceTranscriber: (any Transcriber)?
    }

    private static func transcribeFile(
        audioURL: URL,
        context: RequestContext,
        capabilities: inout RequestCapabilities,
        progress: (Double) -> Void
    ) async throws -> [TranscribedSentence] {
        progress(0.1)
        let response = try await sendWithFallbacks(
            audioURL: audioURL,
            context: context,
            capabilities: &capabilities
        )
        return try await resolveResponse(
            response,
            audioURL: audioURL,
            context: context,
            capabilities: &capabilities,
            progress: progress
        )
    }

    private static func transcribeChunked(
        audioURL: URL,
        context: RequestContext,
        capabilities: inout RequestCapabilities,
        progress: @escaping (Double) -> Void
    ) async throws -> [TranscribedSentence] {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("faymee-openai-chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let asset = AVURLAsset(url: audioURL)
        let totalDuration = try await asset.load(.duration).seconds
        guard totalDuration.isFinite, totalDuration > 0 else {
            throw OnlineAPIError.invalidConfiguration("无法读取录音时长")
        }

        var plan: [(index: Int, startOffset: TimeInterval, duration: TimeInterval)] = []
        var offset: TimeInterval = 0
        var index = 0
        while offset < totalDuration {
            let remaining = totalDuration - offset
            if index > 0 && remaining < 0.05 { break }
            plan.append((index, offset, min(chunkDurationSeconds, remaining)))
            offset += chunkDurationSeconds
            index += 1
        }

        var combined: [TranscribedSentence] = []
        var globalCursor: TimeInterval = 0
        let totalChunks = Double(plan.count)

        for (idx, item) in plan.enumerated() {
            try Task.checkCancellation()
            let chunkBase = Double(idx) / totalChunks
            let chunkSpan = 1.0 / totalChunks
            let exportSpan = chunkSpan * 0.25
            let uploadBase = chunkBase + exportSpan
            let uploadSpan = chunkSpan - exportSpan

            let chunkURL = tempDir.appendingPathComponent(String(format: "chunk-%03d.m4a", item.index))
            defer { try? FileManager.default.removeItem(at: chunkURL) }

            try await exportCompactMonoM4A(
                asset: asset,
                start: item.startOffset,
                duration: item.duration,
                to: chunkURL
            )
            progress(uploadBase)

            let chunkSentences = try await transcribeFile(
                audioURL: chunkURL,
                context: context,
                capabilities: &capabilities,
                progress: { local in
                    progress(uploadBase + uploadSpan * min(1, max(0, local)))
                }
            )
            for s in chunkSentences {
                let shiftedStart = max(globalCursor, s.start + item.startOffset)
                let shiftedEnd = max(shiftedStart, s.end + item.startOffset)
                combined.append(TranscribedSentence(start: shiftedStart, end: shiftedEnd, text: s.text))
                globalCursor = shiftedEnd
            }
            progress(chunkBase + chunkSpan)
        }
        return combined
    }

    private static func exportCompactMonoM4A(
        asset: AVAsset,
        start: TimeInterval,
        duration: TimeInterval,
        to outputURL: URL
    ) async throws {
        try Task.checkCancellation()
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw OnlineAPIError.invalidConfiguration("音频文件中没有可用的音轨")
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let readerOutput = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcmSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw OnlineAPIError.invalidConfiguration("无法初始化音频切段读取器")
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw OnlineAPIError.invalidConfiguration("无法初始化音频切段编码器")
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw reader.error ?? OnlineAPIError.invalidConfiguration("无法读取待切分音频")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? OnlineAPIError.invalidConfiguration("无法写入切分音频")
        }

        let pump = ChunkExportPump(reader: reader, readerOutput: readerOutput, writer: writer, writerInput: writerInput)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pump.start(continuation: continuation)
            }
        } onCancel: {
            pump.cancel()
        }
    }

    /// 用 1 秒合成探测音频走完真实 `/audio/transcriptions` 请求（先试 `verbose_json`，不支持时退回 `json`）
    public static func testConnection(config: OnlineEndpointConfig, transport: any HTTPTransport) async throws {
        try Task.checkCancellation()
        try config.validateReady()
        let endpointURL = try transcriptionsURL(for: config)
        let headers = authHeaders(for: config)
        let model = config.trimmedModel

        try await ProbeAudio.withTemporaryWAV { wavURL in
            var response = try await sendTranscriptionRequest(
                endpointURL: endpointURL,
                headers: headers,
                model: model,
                audioURL: wavURL,
                responseFormat: .verboseJSON,
                prompt: nil,
                transport: transport
            )
            if response.status == 400 {
                response = try await sendTranscriptionRequest(
                    endpointURL: endpointURL,
                    headers: headers,
                    model: model,
                    audioURL: wavURL,
                    responseFormat: .json,
                    prompt: nil,
                    transport: transport
                )
            }
            try response.checkSuccess()
            try validateJSONTranscriptionEnvelope(response.data)
        }
    }

    private enum ResponseFormat: String {
        case verboseJSON = "verbose_json"
        case json = "json"
    }

    private struct RequestCapabilities: Equatable {
        var useVerboseJSON: Bool
        var includePrompt: Bool
    }

    private static func sendWithFallbacks(
        audioURL: URL,
        context: RequestContext,
        capabilities: inout RequestCapabilities
    ) async throws -> HTTPResponse {
        var queue = [capabilities]
        var attempted: [RequestCapabilities] = []
        var lastResponse: HTTPResponse?

        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard !attempted.contains(current) else { continue }
            attempted.append(current)

            let response = try await sendTranscriptionRequest(
                endpointURL: context.endpointURL,
                headers: context.headers,
                model: context.model,
                audioURL: audioURL,
                responseFormat: current.useVerboseJSON ? .verboseJSON : .json,
                prompt: current.includePrompt ? context.prompt : nil,
                transport: context.transport
            )
            if (200..<300).contains(response.status) {
                capabilities = current
                return response
            }
            if response.status == 400 {
                lastResponse = response
                for next in nextFallbacks(after: current, responseData: response.data)
                    where !attempted.contains(next) && !queue.contains(next) {
                    queue.append(next)
                }
                continue
            }
            try response.checkSuccess()
        }

        if let lastResponse {
            try lastResponse.checkSuccess()
        }
        throw OnlineAPIError.badRequest(400, nil)
    }

    private static func nextFallbacks(after current: RequestCapabilities,
                                      responseData: Data) -> [RequestCapabilities] {
        let body = String(data: responseData, encoding: .utf8) ?? ""
        let mentionsPrompt = body.localizedCaseInsensitiveContains("prompt")
        let mentionsFormat = body.localizedCaseInsensitiveContains("verbose_json")
            || body.localizedCaseInsensitiveContains("response_format")
            || body.localizedCaseInsensitiveContains("timestamp")

        switch (current.useVerboseJSON, current.includePrompt) {
        case (true, true):
            if mentionsPrompt && !mentionsFormat {
                return [
                    RequestCapabilities(useVerboseJSON: true, includePrompt: false),
                    RequestCapabilities(useVerboseJSON: false, includePrompt: false),
                ]
            }
            var candidates = [RequestCapabilities(useVerboseJSON: false, includePrompt: true)]
            if !mentionsFormat {
                candidates.append(RequestCapabilities(useVerboseJSON: true, includePrompt: false))
            }
            candidates.append(RequestCapabilities(useVerboseJSON: false, includePrompt: false))
            return candidates
        case (true, false):
            return [RequestCapabilities(useVerboseJSON: false, includePrompt: false)]
        case (false, true):
            return [RequestCapabilities(useVerboseJSON: false, includePrompt: false)]
        case (false, false):
            return []
        }
    }

    private static func buildPrompt(from hotwords: [String]) -> String? {
        var seen = Set<String>()
        var terms: [String] = []
        for raw in hotwords {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            terms.append(trimmed)
        }
        guard !terms.isEmpty else { return nil }

        var selected: [String] = []
        for term in terms {
            let candidate = (selected + [term]).joined(separator: ", ")
            if estimatedPromptTokens(candidate) <= maxPromptTokens {
                selected.append(term)
            } else {
                break
            }
        }
        if selected.isEmpty, let first = terms.first {
            var prefix = ""
            for ch in first {
                let candidate = prefix + String(ch)
                if estimatedPromptTokens(candidate) <= maxPromptTokens {
                    prefix = candidate
                } else {
                    break
                }
            }
            return prefix.isEmpty ? nil : prefix
        }
        return selected.joined(separator: ", ")
    }

    private static func estimatedPromptTokens(_ text: String) -> Int {
        var tokens = 0
        var latinRun = 0
        func flushRun() {
            if latinRun > 0 {
                tokens += (latinRun + 3) / 4
                latinRun = 0
            }
        }
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                flushRun()
                tokens += 2
            } else if scalar.properties.isWhitespace {
                flushRun()
            } else {
                latinRun += 1
            }
        }
        flushRun()
        return tokens
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            true
        default:
            false
        }
    }

    private static func sendTranscriptionRequest(
        endpointURL: URL,
        headers: [String: String],
        model: String,
        audioURL: URL,
        responseFormat: ResponseFormat,
        prompt: String?,
        transport: any HTTPTransport
    ) async throws -> HTTPResponse {
        try Task.checkCancellation()
        var parts: [MultipartPart] = [
            .text(name: "model", value: model),
            .text(name: "response_format", value: responseFormat.rawValue),
        ]
        if responseFormat == .verboseJSON {
            parts.append(.text(name: "timestamp_granularities[]", value: "segment"))
        }
        if let prompt, !prompt.isEmpty {
            parts.append(.text(name: "prompt", value: prompt))
        }
        parts.append(.file(
            name: "file",
            fileURL: audioURL,
            fileName: audioURL.lastPathComponent,
            mimeType: mimeType(for: audioURL)
        ))
        return try await transport.send(HTTPRequest(
            method: "POST",
            url: endpointURL,
            headers: headers,
            body: .multipart(parts)
        ))
    }

    private static func validateJSONTranscriptionEnvelope(_ data: Data) throws {
        guard !data.isEmpty else {
            throw OnlineAPIError.emptyResponse
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["text"] is String || json["segments"] is [[String: Any]]
        else {
            throw OnlineAPIError.invalidResponse("服务端响应格式不是有效的转写结果")
        }
    }

    private static func transcriptionsURL(for config: OnlineEndpointConfig) throws -> URL {
        guard let baseURL = URL(string: config.trimmedBaseURL) else {
            throw OnlineAPIError.invalidConfiguration("请输入有效的接口地址")
        }
        return baseURL.appendingPathComponent("audio").appendingPathComponent("transcriptions")
    }

    private static func authHeaders(for config: OnlineEndpointConfig) -> [String: String] {
        let key = config.trimmedAPIKey
        return key.isEmpty ? [:] : ["Authorization": "Bearer \(key)"]
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "m4a", "mp4": "audio/mp4"
        case "mp3", "mpeg", "mpga": "audio/mpeg"
        case "ogg": "audio/ogg"
        case "flac": "audio/flac"
        case "webm": "audio/webm"
        default: "application/octet-stream"
        }
    }

    private static func resolveResponse(
        _ initialResponse: HTTPResponse,
        audioURL: URL,
        context: RequestContext,
        capabilities: inout RequestCapabilities,
        progress: (Double) -> Void
    ) async throws -> [TranscribedSentence] {
        var response = initialResponse
        guard !response.data.isEmpty else {
            throw OnlineAPIError.emptyResponse
        }

        if capabilities.useVerboseJSON, let segments = try parseVerboseSegments(from: response.data) {
            return segments
        }

        // verbose_json 200 缺有效分段时间戳时，先检查是否已包含可用纯文本；若连文本也缺失则改用 json 重试一次
        var plainText = try extractPlainText(from: response.data)
        if plainText == nil && capabilities.useVerboseJSON {
            capabilities.useVerboseJSON = false
            response = try await sendWithFallbacks(
                audioURL: audioURL,
                context: context,
                capabilities: &capabilities
            )
            guard !response.data.isEmpty else {
                throw OnlineAPIError.emptyResponse
            }
            plainText = try extractPlainText(from: response.data)
        }

        guard let text = plainText else {
            throw OnlineAPIError.invalidResponse("转写响应缺少文本内容")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        progress(0.6)
        return try await TranscriptTimelineAlignment.align(
            onlineText: trimmed,
            audioURL: audioURL,
            hotwords: context.hotwords,
            referenceTranscriber: context.referenceTranscriber
        )
    }

    private static func parseVerboseSegments(from data: Data) throws -> [TranscribedSentence]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OnlineAPIError.invalidResponse("无法解析转写响应 JSON")
        }
        guard let rawSegments = json["segments"] as? [[String: Any]], !rawSegments.isEmpty else {
            return nil
        }

        var result: [TranscribedSentence] = []
        var cursor: TimeInterval = 0
        for item in rawSegments {
            guard let rawText = item["text"] as? String else { continue }
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let rawStart = numericValue(item["start"]),
                  let rawEnd = numericValue(item["end"]),
                  rawStart.isFinite, rawEnd.isFinite, rawEnd >= 0
            else {
                return nil
            }
            let start = max(cursor, max(0, rawStart))
            let end = max(start, rawEnd)
            result.append(TranscribedSentence(start: start, end: end, text: trimmed))
            cursor = end
        }
        guard !result.isEmpty else { return nil }
        if result.count > 1 && result.allSatisfy({ $0.end == 0 }) {
            return nil
        }
        return result
    }

    private static func extractPlainText(from data: Data) throws -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OnlineAPIError.invalidResponse("无法解析转写响应 JSON")
        }
        if let text = json["text"] as? String {
            return text
        }
        if let rawSegments = json["segments"] as? [[String: Any]] {
            let texts = rawSegments.compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !texts.isEmpty {
                return texts.joined(separator: " ")
            }
        }
        return nil
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        return nil
    }
}

private final class ChunkExportPump: @unchecked Sendable {
    private let reader: AVAssetReader
    private let readerOutput: AVAssetReaderOutput
    private let writer: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    private let queue = DispatchQueue(label: "com.faymee.openai.chunk-export", qos: .utility)
    private let lock = NSLock()

    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var finished = false
    private var sessionStarted = false

    init(
        reader: AVAssetReader,
        readerOutput: AVAssetReaderOutput,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput
    ) {
        self.reader = reader
        self.readerOutput = readerOutput
        self.writer = writer
        self.writerInput = writerInput
    }

    func start(continuation: CheckedContinuation<Void, Error>) {
        let alreadyCancelled = lock.withLock { () -> Bool in
            self.continuation = continuation
            return cancelled
        }
        if alreadyCancelled {
            queue.async { [self] in
                abortCancelled()
            }
            return
        }

        writerInput.requestMediaDataWhenReady(on: queue) { [self] in
            pumpSamples()
        }
    }

    func cancel() {
        let shouldDispatch = lock.withLock { () -> Bool in
            cancelled = true
            return !finished && continuation != nil
        }
        if shouldDispatch {
            queue.async { [self] in
                abortCancelled()
            }
        }
    }

    private func pumpSamples() {
        while writerInput.isReadyForMoreMediaData {
            let state = lock.withLock { (cancelled: cancelled, finished: finished) }
            if state.finished { return }
            if state.cancelled {
                abortCancelled()
                return
            }

            if let sample = readerOutput.copyNextSampleBuffer() {
                if !sessionStarted {
                    sessionStarted = true
                    writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
                }
                if !writerInput.append(sample) {
                    reader.cancelReading()
                    let error = writer.error ?? OnlineAPIError.invalidConfiguration("写入切段音频失败")
                    writer.cancelWriting()
                    complete(.failure(error))
                    return
                }
            } else {
                writerInput.markAsFinished()
                if reader.status == .failed {
                    let error = reader.error ?? OnlineAPIError.invalidConfiguration("读取切段音频失败")
                    writer.cancelWriting()
                    complete(.failure(error))
                } else {
                    writer.finishWriting { [self] in
                        if lock.withLock({ cancelled }) {
                            complete(.failure(CancellationError()))
                        } else if let error = writer.error {
                            complete(.failure(error))
                        } else {
                            complete(.success(()))
                        }
                    }
                }
                return
            }
        }
    }

    private func abortCancelled() {
        guard !lock.withLock({ finished }) else { return }
        reader.cancelReading()
        writer.cancelWriting()
        complete(.failure(CancellationError()))
    }

    private func complete(_ result: Result<Void, Error>) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !finished else { return nil }
            finished = true
            let c = continuation
            continuation = nil
            return c
        }
        cont?.resume(with: result)
    }
}
