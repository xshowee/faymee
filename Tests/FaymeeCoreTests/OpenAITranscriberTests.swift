import AVFoundation
import Foundation
import Testing
@testable import FaymeeCore

private final class FakeReferenceTranscriber: Transcriber, @unchecked Sendable {
    var sentences: [TranscribedSentence] = []
    var error: Error?
    private(set) var calls: [(audio: URL, hotwords: [String])] = []

    init(_ sentences: [TranscribedSentence] = [], error: Error? = nil) {
        self.sentences = sentences
        self.error = error
    }

    func prepare(progress: @escaping (Double) -> Void) async throws {
        progress(1)
    }

    func transcribe(audio: URL, hotwords: [String],
                    progress: @escaping (Double) -> Void) async throws -> [TranscribedSentence] {
        calls.append((audio, hotwords))
        progress(1)
        if let error { throw error }
        return sentences
    }
}

private func makeTestWAV(
    sampleRate: Int = 16_000,
    segments: [(seconds: Double, amplitude: Float)]
) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("faymee-test-\(UUID().uuidString).wav")
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate),
                               channels: 1, interleaved: true)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: .pcmFormatInt16, interleaved: true)
    for segment in segments {
        let totalFrames = Int((segment.seconds * Double(sampleRate)).rounded())
        guard totalFrames > 0 else { continue }
        var remaining = totalFrames
        var sampleIndex = 0
        let chunkFrames = 4096
        while remaining > 0 {
            let count = min(remaining, chunkFrames)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            let data = buffer.int16ChannelData![0]
            for i in 0..<count {
                if segment.amplitude == 0 {
                    data[i] = 0
                } else {
                    let t = Double(sampleIndex) / Double(sampleRate)
                    let value = Double(segment.amplitude) * sin(2.0 * .pi * 220.0 * t) * Double(Int16.max)
                    data[i] = Int16(max(Double(Int16.min), min(Double(Int16.max), value)))
                }
                sampleIndex += 1
            }
            try file.write(from: buffer)
            remaining -= count
        }
    }
    return url
}

private func makeConfig(
    baseURL: String = "https://api.openai.com/v1",
    model: String = "gpt-transcribe",
    apiKey: String = "sk-test",
    requiresHTTPS: Bool = true,
    requiresAPIKey: Bool = true,
    providerID: String = "openai"
) -> OnlineEndpointConfig {
    OnlineEndpointConfig(
        baseURL: baseURL,
        model: model,
        apiKey: apiKey,
        requiresHTTPS: requiresHTTPS,
        requiresAPIKey: requiresAPIKey,
        providerID: providerID
    )
}

@Suite struct OpenAITranscriberTests {
    @Test func prepare校验配置并直接汇报完成而不触发网络请求() async throws {
        let transport = FakeHTTPTransport()
        let invalid = makeConfig(apiKey: "")
        let badTranscriber = OpenAITranscriber(config: invalid, transport: transport)

        var badProgress: [Double] = []
        await #expect(throws: OnlineAPIError.self) {
            try await badTranscriber.prepare { badProgress.append($0) }
        }
        #expect(badProgress.isEmpty)
        #expect(transport.recordedRequests.isEmpty)

        let valid = makeConfig()
        let goodTranscriber = OpenAITranscriber(config: valid, transport: transport)
        var goodProgress: [Double] = []
        try await goodTranscriber.prepare { goodProgress.append($0) }
        #expect(goodProgress == [1.0])
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test func 小文件单次上传并返回verbose_json服务端时间戳且自定义免密不带鉴权头() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: [
            "text": "大家好。今天讨论方案。",
            "segments": [
                ["id": 0, "start": 0.2, "end": 1.8, "text": " 大家好。"],
                ["id": 1, "start": 1.7, "end": 3.5, "text": "   "],
                ["id": 2, "start": 1.6, "end": 3.8, "text": " 今天讨论方案。"],
            ],
        ])

        let ref = FakeReferenceTranscriber([TranscribedSentence(start: 0, end: 1, text: "不应调用")])
        let config = makeConfig(
            baseURL: "http://192.168.1.20:8000/v1/",
            model: "whisper-large-v3",
            apiKey: "",
            requiresHTTPS: false,
            requiresAPIKey: false,
            providerID: "openai-compatible"
        )
        let transcriber = OpenAITranscriber(config: config, transport: transport, referenceTranscriber: ref)

        var progresses: [Double] = []
        let sentences = try await ProbeAudio.withTemporaryWAV { wavURL in
            try await transcriber.transcribe(audio: wavURL, hotwords: []) { progresses.append($0) }
        }

        #expect(sentences == [
            TranscribedSentence(start: 0.2, end: 1.8, text: "大家好。"),
            TranscribedSentence(start: 1.8, end: 3.8, text: "今天讨论方案。"),
        ])
        #expect(ref.calls.isEmpty)
        #expect(progresses.last == 1.0)
        #expect(zip(progresses, progresses.dropFirst()).allSatisfy { $0 <= $1 })

        #expect(transport.recordedRequests.count == 1)
        let req = try #require(transport.recordedRequests.first)
        #expect(req.request.method == "POST")
        #expect(req.request.url.absoluteString == "http://192.168.1.20:8000/v1/audio/transcriptions")
        #expect(req.header("Authorization") == nil)
        #expect(req.multipartText(named: "model") == "whisper-large-v3")
        #expect(req.multipartText(named: "response_format") == "verbose_json")
        #expect(req.multipartText(named: "timestamp_granularities[]") == "segment")
        #expect(req.multipartText(named: "prompt") == nil)

        let uploaded = try #require(req.multipartFile(named: "file"))
        #expect(uploaded.fileName.hasSuffix(".wav"))
        #expect(uploaded.data == ProbeAudio.wavData())
    }

    @Test func 连接测试支持verbose_json与400退回json并携带Bearer鉴权() async throws {
        let verboseTransport = FakeHTTPTransport()
        try verboseTransport.enqueue(json: [
            "text": "ok",
            "segments": [["start": 0.0, "end": 1.0, "text": "ok"]],
        ])
        let openAIConfig = makeConfig(apiKey: "sk-live-test")

        try await OpenAITranscriber.testConnection(config: openAIConfig, transport: verboseTransport)

        #expect(verboseTransport.recordedRequests.count == 1)
        let r0 = try #require(verboseTransport.recordedRequests.first)
        #expect(r0.request.url.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(r0.header("Authorization") == "Bearer sk-live-test")
        #expect(r0.multipartText(named: "model") == "gpt-transcribe")
        #expect(r0.multipartText(named: "response_format") == "verbose_json")
        #expect(r0.multipartText(named: "timestamp_granularities[]") == "segment")
        #expect(r0.multipartFile(named: "file")?.data == ProbeAudio.wavData())

        // 400 退回 json 模式（即使返回 {"text": ""} 合法 JSON 也算探测连通）
        let fallbackTransport = FakeHTTPTransport()
        try fallbackTransport.enqueue(json: ["error": ["message": "verbose_json unsupported"]], status: 400)
        try fallbackTransport.enqueue(json: ["text": ""])

        try await OpenAITranscriber.testConnection(config: openAIConfig, transport: fallbackTransport)

        #expect(fallbackTransport.recordedRequests.count == 2)
        #expect(fallbackTransport.recordedRequests[0].multipartText(named: "response_format") == "verbose_json")
        #expect(fallbackTransport.recordedRequests[1].multipartText(named: "response_format") == "json")
        #expect(fallbackTransport.recordedRequests[1].multipartText(named: "timestamp_granularities[]") == nil)
        #expect(fallbackTransport.recordedRequests[1].multipartFile(named: "file")?.data == ProbeAudio.wavData())
    }

    @Test func 连接测试在鉴权失败_404_断网和无效响应时返回对应OnlineAPIError() async throws {
        let invalidTransport = FakeHTTPTransport()
        await #expect(throws: OnlineAPIError.self) {
            try await OpenAITranscriber.testConnection(config: makeConfig(apiKey: ""), transport: invalidTransport)
        }
        #expect(invalidTransport.recordedRequests.isEmpty)

        let unauthorizedTransport = FakeHTTPTransport()
        try unauthorizedTransport.enqueue(json: ["error": ["message": "Invalid API key"]], status: 401)
        await #expect(throws: OnlineAPIError.unauthorized(401, "Invalid API key")) {
            try await OpenAITranscriber.testConnection(config: makeConfig(), transport: unauthorizedTransport)
        }

        let notFoundTransport = FakeHTTPTransport()
        try notFoundTransport.enqueue(json: ["error": ["message": "Model not found"]], status: 404)
        await #expect(throws: OnlineAPIError.notFound("Model not found")) {
            try await OpenAITranscriber.testConnection(config: makeConfig(), transport: notFoundTransport)
        }

        let offlineTransport = FakeHTTPTransport()
        offlineTransport.enqueue(error: OnlineAPIError.networkUnavailable("Offline"))
        await #expect(throws: OnlineAPIError.networkUnavailable("Offline")) {
            try await OpenAITranscriber.testConnection(config: makeConfig(), transport: offlineTransport)
        }

        let htmlTransport = FakeHTTPTransport()
        htmlTransport.enqueue(text: "<html><body>Not an API</body></html>", status: 200)
        await #expect(throws: OnlineAPIError.invalidResponse("服务端响应格式不是有效的转写结果")) {
            try await OpenAITranscriber.testConnection(config: makeConfig(), transport: htmlTransport)
        }

        let emptyTransport = FakeHTTPTransport()
        emptyTransport.enqueue(HTTPResponse(status: 200, data: Data()))
        await #expect(throws: OnlineAPIError.emptyResponse) {
            try await OpenAITranscriber.testConnection(config: makeConfig(), transport: emptyTransport)
        }
    }

    @Test func 热词放入prompt并按约224token安全上限从头截断() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: [
            "segments": [["start": 0.0, "end": 1.0, "text": "正常。"]],
        ])

        let manyHotwords = (1...200).map { "专有术语\($0)" }
        let transcriber = OpenAITranscriber(config: makeConfig(), transport: transport)

        let sentences = try await ProbeAudio.withTemporaryWAV { wavURL in
            try await transcriber.transcribe(audio: wavURL, hotwords: ["  ", ""] + manyHotwords) { _ in }
        }

        #expect(sentences == [TranscribedSentence(start: 0.0, end: 1.0, text: "正常。")])
        let req = try #require(transport.recordedRequests.first)
        let prompt = try #require(req.multipartText(named: "prompt"))
        #expect(prompt.hasPrefix("专有术语1, 专有术语2"))
        #expect(!prompt.contains("专有术语200"))
        #expect(prompt.count < 400)
    }

    @Test func 服务端对prompt报400时自动去掉prompt重试成功() async throws {
        let transport = FakeHTTPTransport()
        try transport.enqueue(json: ["error": ["message": "Unsupported parameter: prompt"]], status: 400)
        try transport.enqueue(json: [
            "segments": [["start": 0.0, "end": 1.0, "text": "降级成功。"]],
        ])

        let transcriber = OpenAITranscriber(config: makeConfig(), transport: transport)
        let sentences = try await ProbeAudio.withTemporaryWAV { wavURL in
            try await transcriber.transcribe(audio: wavURL, hotwords: ["Faymee", "飞书"]) { _ in }
        }

        #expect(sentences == [TranscribedSentence(start: 0.0, end: 1.0, text: "降级成功。")])
        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests[0].multipartText(named: "prompt") == "Faymee, 飞书")
        #expect(transport.recordedRequests[0].multipartText(named: "response_format") == "verbose_json")
        #expect(transport.recordedRequests[1].multipartText(named: "prompt") == nil)
        #expect(transport.recordedRequests[1].multipartText(named: "response_format") == "verbose_json")
    }

    @Test func verbose_json报400时退回json并保留热词且用参考转写器DP单调对齐与插值() async throws {
        let wavURL = try makeTestWAV(segments: [(8.0, 0.2)])
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let transport = FakeHTTPTransport()
        try transport.enqueue(
            json: ["error": ["message": "response_format 'verbose_json' is not compatible with model 'gpt-transcribe'"]],
            status: 400
        )
        // 在线文本包含：参考转写器写错的英文/同音词 "Faymee" 和 "0.5"，以及一个无标点长停顿后的句子
        try transport.enqueue(json: [
            "text": "我们先看Faymee 0.5项目。“进度如何？” 下周发布！",
        ])

        // 参考转写器识别出“非米05”并在 3.2s..4.8s 有一段 1.6s 静音停顿
        let ref = FakeReferenceTranscriber([
            TranscribedSentence(start: 0.4, end: 3.2, text: "我们先看非米项目进度如何"),
            TranscribedSentence(start: 4.8, end: 6.4, text: "下周发布"),
        ])

        let transcriber = OpenAITranscriber(config: makeConfig(), transport: transport, referenceTranscriber: ref)
        let sentences = try await transcriber.transcribe(audio: wavURL, hotwords: ["Faymee"]) { _ in }

        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests[0].multipartText(named: "response_format") == "verbose_json")
        #expect(transport.recordedRequests[1].multipartText(named: "response_format") == "json")
        #expect(transport.recordedRequests[1].multipartText(named: "prompt") == "Faymee")
        #expect(ref.calls.count == 1)

        // 应按句末标点与引文配对切成 3 句，且小数 0.5 不应断开
        #expect(sentences.map(\.text) == [
            "我们先看Faymee 0.5项目。",
            "“进度如何？”",
            "下周发布！",
        ])
        // 时间单调不重叠、落在 [0, 8.0] 内，且“下周发布！”保持在停顿之后（>= 4.7）
        #expect(sentences.allSatisfy { 0 <= $0.start && $0.start <= $0.end && $0.end <= 8.0 })
        #expect(zip(sentences, sentences.dropFirst()).allSatisfy { $0.end <= $1.start })
        #expect(sentences[0].start >= 0.35 && sentences[0].end <= 2.6)
        #expect(sentences[1].start >= sentences[0].end && sentences[1].end <= 3.3)
        #expect(sentences[2].start >= 4.7 && sentences[2].end <= 6.5)
    }

    @Test func verbose_json返回200但缺分段时间戳时按参考转写器在停顿与句末标点处补齐时间() async throws {
        let wavURL = try makeTestWAV(segments: [(6.0, 0.2)])
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let transport = FakeHTTPTransport()
        // 兼容网关忽略 verbose_json 直接返回无时间戳的 segments 或纯 text
        try transport.enqueue(json: [
            "text": "第一句话没有句号 第二句话有句号。第三句；第四句？",
            "segments": [
                ["text": "第一句话没有句号 第二句话有句号。第三句；第四句？"],
            ],
        ])

        let ref = FakeReferenceTranscriber([
            TranscribedSentence(start: 0.2, end: 1.6, text: "第一句话没有句号"),
            TranscribedSentence(start: 2.6, end: 5.4, text: "第二句话有句号第三句第四句"),
        ])

        let transcriber = OpenAITranscriber(config: makeConfig(), transport: transport, referenceTranscriber: ref)
        let sentences = try await transcriber.transcribe(audio: wavURL, hotwords: []) { _ in }

        #expect(ref.calls.count == 1)
        #expect(sentences.map(\.text) == [
            "第一句话没有句号",
            "第二句话有句号。",
            "第三句；",
            "第四句？",
        ])
        #expect(sentences.allSatisfy { 0 <= $0.start && $0.start <= $0.end && $0.end <= 6.0 })
        #expect(zip(sentences, sentences.dropFirst()).allSatisfy { $0.end <= $1.start })
        #expect(sentences[0].end <= 1.7)
        #expect(sentences[1].start >= 2.5)
    }

    @Test func 单条起止均为0的segments回退到本地时间轴对齐() async throws {
        let wavURL = try makeTestWAV(segments: [(4.0, 0.2)])
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let transport = FakeHTTPTransport()
        try transport.enqueue(json: [
            "text": "第一句话。第二句话。",
            "segments": [
                ["start": 0, "end": 0, "text": "第一句话。第二句话。"],
            ],
        ])

        let ref = FakeReferenceTranscriber([
            TranscribedSentence(start: 0.4, end: 1.6, text: "第一句话"),
            TranscribedSentence(start: 2.2, end: 3.6, text: "第二句话"),
        ])

        let transcriber = OpenAITranscriber(config: makeConfig(), transport: transport, referenceTranscriber: ref)
        let sentences = try await transcriber.transcribe(audio: wavURL, hotwords: []) { _ in }

        #expect(ref.calls.count == 1)
        #expect(sentences.map(\.text) == ["第一句话。", "第二句话。"])
        try #require(sentences.count == 2)
        #expect(sentences.allSatisfy { $0.end > $0.start })
        #expect(sentences[0].start >= 0.35 && sentences[0].end <= 1.7)
        #expect(sentences[1].start >= 2.1 && sentences[1].end <= 3.7)
    }

    @Test func 英文ASCII句号切分句子并保留小数版本号() async throws {
        let wavURL = try makeTestWAV(segments: [(4.0, 0.2)])
        defer { try? FileManager.default.removeItem(at: wavURL) }

        // 1) 参考转写对齐路径
        let refTransport = FakeHTTPTransport()
        try refTransport.enqueue(json: ["text": "Hello world. Next v2.3 sentence."])
        let ref = FakeReferenceTranscriber([
            TranscribedSentence(start: 0.2, end: 3.8, text: "Hello world Next v23 sentence"),
        ])
        let withRef = OpenAITranscriber(config: makeConfig(), transport: refTransport, referenceTranscriber: ref)
        let refSentences = try await withRef.transcribe(audio: wavURL, hotwords: []) { _ in }
        #expect(refSentences.map(\.text) == ["Hello world.", "Next v2.3 sentence."])

        // 2) 静音比例回退路径
        let fallbackTransport = FakeHTTPTransport()
        try fallbackTransport.enqueue(json: ["text": "Hello world. Next v2.3 sentence."])
        let withoutRef = OpenAITranscriber(config: makeConfig(), transport: fallbackTransport, referenceTranscriber: nil)
        let fallbackSentences = try await withoutRef.transcribe(audio: wavURL, hotwords: []) { _ in }
        #expect(fallbackSentences.map(\.text) == ["Hello world.", "Next v2.3 sentence."])
    }

    @Test func 参考转写器缺失或报错时回退到音频静音检测与字数比例对齐() async throws {
        // 录音结构：1s 静音 | 3s 说话(1..4) | 1.5s 静音(4..5.5) | 3.5s 说话(5.5..9) | 1s 静音(9..10)
        let silenceAudio = try makeTestWAV(segments: [
            (1.0, 0.0),
            (3.0, 0.2),
            (1.5, 0.0),
            (3.5, 0.2),
            (1.0, 0.0),
        ])
        defer { try? FileManager.default.removeItem(at: silenceAudio) }

        // 场景 A：参考转写器抛错，且在线文本无句末标点只有逗号，应沿静音边界拆句并跳过前后静音
        let transportA = FakeHTTPTransport()
        try transportA.enqueue(json: ["text": "大家好，我们先过一下上周的待办，然后看看下周的发布计划"])
        let failingRef = FakeReferenceTranscriber(error: SpeechAnalyzerTranscriberError.unavailable)
        let transcriberA = OpenAITranscriber(
            config: makeConfig(),
            transport: transportA,
            referenceTranscriber: failingRef
        )

        let sentencesA = try await transcriberA.transcribe(audio: silenceAudio, hotwords: []) { _ in }
        #expect(failingRef.calls.count == 1)
        #expect(sentencesA.map(\.text) == ["大家好，我们先过一下上周的待办，", "然后看看下周的发布计划"])
        try #require(sentencesA.count == 2)
        #expect(sentencesA[0].start >= 0.9 && sentencesA[0].end <= 4.1)
        #expect(sentencesA[1].start >= 5.4 && sentencesA[1].end <= 9.1)

        // 场景 B：参考转写器为 nil 且多句跨多个有效语段，按停顿与字数比例分配且不跨越中间静音
        let transportB = FakeHTTPTransport()
        try transportB.enqueue(json: ["text": "第一句讨论进度。第二句确定方案。第三句安排测试。"])
        let transcriberB = OpenAITranscriber(config: makeConfig(), transport: transportB, referenceTranscriber: nil)
        let sentencesB = try await transcriberB.transcribe(audio: silenceAudio, hotwords: []) { _ in }
        #expect(sentencesB.map(\.text) == ["第一句讨论进度。", "第二句确定方案。", "第三句安排测试。"])
        try #require(sentencesB.count == 3)
        #expect(sentencesB[0].start >= 0.9 && sentencesB[0].end <= 4.1)
        #expect(sentencesB[1].start >= 5.4 && sentencesB[1].end <= sentencesB[2].start)
        #expect(sentencesB[2].end <= 9.1)

        // 场景 C：连续无静音音频 + 参考转写器返回空锚点，严格按非标点字符数比例分配 [0, 10]
        let continuousAudio = try makeTestWAV(segments: [(10.0, 0.2)])
        defer { try? FileManager.default.removeItem(at: continuousAudio) }
        let transportC = FakeHTTPTransport()
        try transportC.enqueue(json: ["text": "你好。我是小明今天讨论方案。"]) // 2 字 vs 10 字 = 1:5
        let emptyRef = FakeReferenceTranscriber([])
        let transcriberC = OpenAITranscriber(config: makeConfig(), transport: transportC, referenceTranscriber: emptyRef)
        let sentencesC = try await transcriberC.transcribe(audio: continuousAudio, hotwords: []) { _ in }
        #expect(sentencesC.count == 2)
        #expect(abs(sentencesC[0].start - 0.0) < 0.05)
        #expect(abs(sentencesC[0].end - (10.0 * 2.0 / 12.0)) < 0.1)
        #expect(abs(sentencesC[1].start - sentencesC[0].end) < 0.01)
        #expect(abs(sentencesC[1].end - 10.0) < 0.05)
    }

    @Test func 参考转写器取消时直接传播CancellationError而不回退() async throws {
        let wavURL = try makeTestWAV(segments: [(2.0, 0.2)])
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let transport = FakeHTTPTransport()
        try transport.enqueue(json: ["text": "你好。"])
        let cancellingRef = FakeReferenceTranscriber(error: CancellationError())
        let transcriber = OpenAITranscriber(
            config: makeConfig(),
            transport: transport,
            referenceTranscriber: cancellingRef
        )

        await #expect(throws: CancellationError.self) {
            _ = try await transcriber.transcribe(audio: wavURL, hotwords: []) { _ in }
        }
    }

    @Test func 超过24MB长录音自动切段为20分钟单声道m4a并累加偏移与清理临时目录() async throws {
        // 1250 秒 16kHz 16-bit 单声道 PCM WAV ≈ 40 MB（> 24 MB 且跨越 1200 秒边界，切成 2 段）
        let largeWAV = try makeLargeMonoWAV(seconds: 1250, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: largeWAV) }
        let fileSize = (try FileManager.default.attributesOfItem(atPath: largeWAV.path)[.size] as? NSNumber)?.int64Value ?? 0
        #expect(fileSize > 24 * 1024 * 1024)

        let capturedDirs = LockedArray<URL>()
        let transport = FakeHTTPTransport { request in
            if case let .multipart(parts) = request.body {
                for case let .file(_, fileURL, _, _) in parts {
                    #expect(FileManager.default.fileExists(atPath: fileURL.path))
                    capturedDirs.append(fileURL.deletingLastPathComponent())
                }
            }
            let callIndex = capturedDirs.count
            if callIndex == 1 {
                return try HTTPResponse.json([
                    "segments": [
                        ["start": 1.5, "end": 4.0, "text": "第一段第一句。"],
                        ["start": 1198.0, "end": 1200.0, "text": "第一段末尾。"],
                    ],
                ])
            } else {
                return try HTTPResponse.json([
                    "segments": [
                        ["start": 0.5, "end": 3.0, "text": "第二段开头。"],
                    ],
                ])
            }
        }

        let transcriber = OpenAITranscriber(config: makeConfig(), transport: transport)
        var progresses: [Double] = []
        let sentences = try await transcriber.transcribe(audio: largeWAV, hotwords: []) { progresses.append($0) }

        #expect(transport.recordedRequests.count == 2)
        for req in transport.recordedRequests {
            let uploaded = try #require(req.multipartFile(named: "file"))
            #expect(uploaded.fileName.hasSuffix(".m4a"))
            #expect(uploaded.mimeType == "audio/mp4")
            #expect(uploaded.data.count > 0 && uploaded.data.count < 24 * 1024 * 1024)
        }

        // 验证切段后的单声道紧凑 m4a 音频流真实可读
        let chunkTempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspect-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: chunkTempFile) }
        try #require(transport.recordedRequests[0].multipartFile(named: "file")).data.write(to: chunkTempFile)
        let chunkAudio = try AVAudioFile(forReading: chunkTempFile)
        #expect(chunkAudio.processingFormat.channelCount == 1)
        let chunkDuration = Double(chunkAudio.length) / chunkAudio.processingFormat.sampleRate
        #expect(abs(chunkDuration - 1200) < 1.0)

        #expect(sentences == [
            TranscribedSentence(start: 1.5, end: 4.0, text: "第一段第一句。"),
            TranscribedSentence(start: 1198.0, end: 1200.0, text: "第一段末尾。"),
            TranscribedSentence(start: 1200.5, end: 1203.0, text: "第二段开头。"),
        ])
        #expect(progresses.count >= 4)
        #expect(progresses.last == 1.0)
        #expect(zip(progresses, progresses.dropFirst()).allSatisfy { $0 <= $1 })

        let dirs = Set(capturedDirs.all())
        try #require(!dirs.isEmpty)
        for dir in dirs {
            #expect(dir.standardizedFileURL != FileManager.default.temporaryDirectory.standardizedFileURL)
            #expect(!FileManager.default.fileExists(atPath: dir.path))
        }
    }

    @Test func 超过24MB切段在失败与取消时同样清理临时目录() async throws {
        let largeWAV = try makeLargeMonoWAV(seconds: 1250, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: largeWAV) }

        // 1) 第二段请求报 500 失败后，临时目录被彻底清理
        let failedDirs = LockedArray<URL>()
        let failingTransport = FakeHTTPTransport { request in
            if case let .multipart(parts) = request.body {
                for case let .file(_, fileURL, _, _) in parts {
                    failedDirs.append(fileURL.deletingLastPathComponent())
                }
            }
            if failedDirs.count == 1 {
                return try HTTPResponse.json(["segments": [["start": 0.0, "end": 1.0, "text": "一。"]]])
            }
            return try HTTPResponse.json(["error": ["message": "Server busy"]], status: 500)
        }
        let failingTranscriber = OpenAITranscriber(config: makeConfig(), transport: failingTransport)
        await #expect(throws: OnlineAPIError.serverError(500, "Server busy")) {
            _ = try await failingTranscriber.transcribe(audio: largeWAV, hotwords: []) { _ in }
        }
        let failDirs = Set(failedDirs.all())
        try #require(!failDirs.isEmpty)
        for dir in failDirs {
            #expect(dir.standardizedFileURL != FileManager.default.temporaryDirectory.standardizedFileURL)
            #expect(!FileManager.default.fileExists(atPath: dir.path))
        }

        // 2) 上传期间取消任务，临时目录同样被彻底清理
        let cancelledDirs = LockedArray<URL>()
        let started = AsyncStream<Void>.makeStream()
        let cancellingTransport = FakeHTTPTransport { request in
            if case let .multipart(parts) = request.body {
                for case let .file(_, fileURL, _, _) in parts {
                    cancelledDirs.append(fileURL.deletingLastPathComponent())
                }
            }
            started.continuation.yield()
            try await Task.sleep(for: .seconds(10))
            return try HTTPResponse.json(["segments": []])
        }
        let cancellingTranscriber = OpenAITranscriber(config: makeConfig(), transport: cancellingTransport)
        let task = Task {
            try await cancellingTranscriber.transcribe(audio: largeWAV, hotwords: []) { _ in }
        }
        for await _ in started.stream { break }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        let cancelDirs = Set(cancelledDirs.all())
        try #require(!cancelDirs.isEmpty)
        for dir in cancelDirs {
            #expect(dir.standardizedFileURL != FileManager.default.temporaryDirectory.standardizedFileURL)
            #expect(!FileManager.default.fileExists(atPath: dir.path))
        }
    }

    @Test func 参考转写零命中时回退静音比例对齐与空转写及错误码处理() async throws {
        // 1) 参考转写器返回与在线文本零重合字符，应回退第二层按静音/比例分配时间轴
        let wav = try makeTestWAV(segments: [(1.0, 0.0), (2.0, 0.2), (1.0, 0.0)])
        defer { try? FileManager.default.removeItem(at: wav) }

        let zeroMatchTransport = FakeHTTPTransport()
        try zeroMatchTransport.enqueue(json: ["text": "你好。再见。"])
        let unrelatedRef = FakeReferenceTranscriber([TranscribedSentence(start: 0, end: 1, text: "xyz")])
        let t1 = OpenAITranscriber(config: makeConfig(), transport: zeroMatchTransport, referenceTranscriber: unrelatedRef)
        let s1 = try await t1.transcribe(audio: wav, hotwords: []) { _ in }
        try #require(s1.count == 2)
        #expect(s1[0].start >= 0.9 && s1[1].end <= 3.1)

        // 2) 纯静音空文本返回空数组
        let emptyTextTransport = FakeHTTPTransport()
        try emptyTextTransport.enqueue(json: ["text": "   ", "segments": []])
        let t2 = OpenAITranscriber(config: makeConfig(), transport: emptyTextTransport)
        let s2 = try await t2.transcribe(audio: wav, hotwords: []) { _ in }
        #expect(s2.isEmpty)

        // 3) 401/429/空响应抛出对应 OnlineAPIError
        let rateLimitedTransport = FakeHTTPTransport()
        try rateLimitedTransport.enqueue(json: ["error": ["message": "Rate limit exceeded"]], status: 429)
        let t3 = OpenAITranscriber(config: makeConfig(), transport: rateLimitedTransport)
        await #expect(throws: OnlineAPIError.rateLimited("Rate limit exceeded")) {
            _ = try await t3.transcribe(audio: wav, hotwords: []) { _ in }
        }
    }
}

/// 真实网络契约测试：仅在显式设置 `FAYMEE_ONLINE_CONTRACT=1` 且提供 `FAYMEE_OPENAI_API_KEY`（或 `OPENAI_API_KEY`）时运行
@Suite(.enabled(
    if: ProcessInfo.processInfo.environment["FAYMEE_ONLINE_CONTRACT"] == "1"
        && !(ProcessInfo.processInfo.environment["FAYMEE_OPENAI_API_KEY"]
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ?? "").isEmpty,
    "设 FAYMEE_ONLINE_CONTRACT=1 与 FAYMEE_OPENAI_API_KEY（或 OPENAI_API_KEY）才跑"
))
struct OpenAITranscriberContractTests {
    @Test func 真实OpenAI兼容接口连接测试与短中文样本转写() async throws {
        let env = ProcessInfo.processInfo.environment
        let apiKey = (env["FAYMEE_OPENAI_API_KEY"] ?? env["OPENAI_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = (env["FAYMEE_OPENAI_BASE_URL"] ?? OnlineTranscriptionProvider.openAI.defaultBaseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (env["FAYMEE_OPENAI_MODEL"] ?? OnlineTranscriptionProvider.openAI.defaultModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let config = OnlineEndpointConfig(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            requiresHTTPS: baseURL.lowercased().hasPrefix("https://"),
            requiresAPIKey: true,
            providerID: "openai"
        )
        let transport = URLSessionHTTPTransport()
        try await OpenAITranscriber.testConnection(config: config, transport: transport)

        if let sampleURL = Bundle.module.url(forResource: "zh-sample", withExtension: "m4a", subdirectory: "Resources") {
            let transcriber = OpenAITranscriber(config: config, transport: transport)
            let sentences = try await transcriber.transcribe(audio: sampleURL, hotwords: ["飞书"]) { _ in }
            #expect(!sentences.isEmpty)
            #expect(sentences.allSatisfy { !$0.text.isEmpty && 0 <= $0.start && $0.start <= $0.end })
            #expect(zip(sentences, sentences.dropFirst()).allSatisfy { $0.end <= $1.start })
        }
    }
}

private final class LockedArray<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    var count: Int { lock.withLock { items.count } }

    func append(_ item: Element) {
        lock.withLock { items.append(item) }
    }

    func all() -> [Element] {
        lock.withLock { items }
    }
}

private func makeLargeMonoWAV(seconds: Int, sampleRate: Int = 16_000) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("faymee-large-\(UUID().uuidString).wav")
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate),
                               channels: 1, interleaved: true)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: .pcmFormatInt16, interleaved: true)
    // 预生成 1 秒 220Hz（整数周期）缓冲区循环写入，快速构造 >24MB 合法音频
    let oneSecondBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate))!
    oneSecondBuffer.frameLength = AVAudioFrameCount(sampleRate)
    let samples = oneSecondBuffer.int16ChannelData![0]
    for i in 0..<sampleRate {
        let t = Double(i) / Double(sampleRate)
        samples[i] = Int16(0.15 * sin(2.0 * .pi * 220.0 * t) * Double(Int16.max))
    }
    for _ in 0..<seconds {
        try file.write(from: oneSecondBuffer)
    }
    return url
}
