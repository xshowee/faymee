import Foundation
import Testing
@testable import FaymeeCore

@Suite struct DashScopeTranscriberTests {
    private static func makeConfig(
        baseURL: String = OnlineTranscriptionProvider.dashScope.defaultBaseURL,
        model: String = OnlineTranscriptionProvider.dashScope.defaultModel,
        apiKey: String = "sk-dash-test",
        requiresHTTPS: Bool = true,
        requiresAPIKey: Bool = true
    ) -> OnlineEndpointConfig {
        OnlineEndpointConfig(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            requiresHTTPS: requiresHTTPS,
            requiresAPIKey: requiresAPIKey,
            providerID: OnlineTranscriptionProvider.dashScope.providerID
        )
    }

    private static func withTempAudioFile(
        ext: String = "m4a",
        bytes: Data = Data("MOCK-M4A-DATA".utf8),
        _ body: (URL) async throws -> Void
    ) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaymeeDashScopeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("meeting.\(ext)")
        try bytes.write(to: fileURL)
        try await body(fileURL)
    }

    @Test func prepare校验配置完整性并在就绪时将进度推进到1() async throws {
        let invalid = Self.makeConfig(apiKey: "  ")
        let invalidTranscriber = DashScopeTranscriber(
            config: invalid,
            transport: FakeHTTPTransport(),
            pollInterval: .milliseconds(1)
        )
        await #expect(throws: OnlineAPIError.invalidConfiguration("请填写 API Key")) {
            try await invalidTranscriber.prepare { _ in }
        }

        let valid = Self.makeConfig()
        let validTranscriber = DashScopeTranscriber(
            config: valid,
            transport: FakeHTTPTransport(),
            pollInterval: .milliseconds(1)
        )
        var reported: [Double] = []
        try await validTranscriber.prepare { reported.append($0) }
        #expect(reported == [1.0])
    }

    @Test func 四步异步直传转写将毫秒换算为秒并保留标点与推进进度() async throws {
        let fake = FakeHTTPTransport()
        // 1) getPolicy
        try fake.enqueue(json: [
            "request_id": "req-policy",
            "data": [
                "policy": "policy-base64",
                "signature": "sig-base64",
                "upload_host": "https://dashscope-oss.example.com",
                "upload_dir": "dashscope-instant/u1/2026-11-16",
                "oss_access_key_id": "LTAI-test",
                "x_oss_object_acl": "private",
                "x_oss_forbid_overwrite": "true",
            ],
        ])
        // 2) OSS multipart upload
        fake.enqueue(HTTPResponse(status: 200))
        // 3) submit transcription task
        try fake.enqueue(json: [
            "request_id": "req-submit",
            "output": [
                "task_id": "task-101",
                "task_status": "PENDING",
            ],
        ])
        // 4a) poll 1 -> PENDING
        try fake.enqueue(json: [
            "output": [
                "task_id": "task-101",
                "task_status": "PENDING",
            ],
        ])
        // 4b) poll 2 -> RUNNING
        try fake.enqueue(json: [
            "output": [
                "task_id": "task-101",
                "task_status": "RUNNING",
            ],
        ])
        // 4c) poll 3 -> SUCCEEDED (qwen3-asr output.result.transcription_url)
        try fake.enqueue(json: [
            "output": [
                "task_id": "task-101",
                "task_status": "SUCCEEDED",
                "result": [
                    "transcription_url": "https://result-oss.example.com/transcript.json?Signature=abc",
                ],
            ],
        ])
        // 4d) fetch transcription_url
        try fake.enqueue(json: [
            "transcripts": [
                [
                    "channel_id": 0,
                    "sentences": [
                        [
                            "begin_time": 1200,
                            "end_time": 3450,
                            "text": "大家好，欢迎来到 Faymee 项目周会！",
                        ],
                        [
                            "start_time": 4100,
                            "end_time": 7800,
                            "text": "今天我们先同步上线进度。",
                        ],
                    ],
                ],
            ],
        ])

        // 传入不含 /api/v1 的根地址，验证自动补全 /api/v1
        let config = Self.makeConfig(baseURL: "https://dashscope.aliyuncs.com")
        let transcriber = DashScopeTranscriber(
            config: config,
            transport: fake,
            pollInterval: .milliseconds(1)
        )

        var progresses: [Double] = []
        let audioBytes = Data("AUDIO-PAYLOAD".utf8)
        let sentences = try await {
            var output: [TranscribedSentence] = []
            try await Self.withTempAudioFile(ext: "m4a", bytes: audioBytes) { url in
                output = try await transcriber.transcribe(audio: url, hotwords: []) {
                    progresses.append($0)
                }
            }
            return output
        }()

        #expect(sentences == [
            TranscribedSentence(start: 1.2, end: 3.45, text: "大家好，欢迎来到 Faymee 项目周会！"),
            TranscribedSentence(start: 4.1, end: 7.8, text: "今天我们先同步上线进度。"),
        ])

        // 验证进度在 0...1 单调递增并覆盖上传与轮询阶段最终到达 1
        #expect(!progresses.isEmpty)
        #expect(progresses.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(zip(progresses, progresses.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(progresses.contains { $0 > 0 && $0 < 0.45 })
        #expect(progresses.contains { $0 > 0.45 && $0 < 1.0 })
        #expect(progresses.last == 1.0)

        // 验证 7 次请求协议细节
        let reqs = fake.recordedRequests
        #expect(reqs.count == 7)

        // 1) getPolicy
        #expect(reqs[0].request.method == "GET")
        #expect(reqs[0].request.url.absoluteString == "https://dashscope.aliyuncs.com/api/v1/uploads?action=getPolicy&model=qwen3-asr-flash-filetrans")
        #expect(reqs[0].header("Authorization") == "Bearer sk-dash-test")

        // 2) OSS multipart：字段在 file 之前，不带 Bearer 头，生成唯一 key
        let uploadReq = reqs[1]
        #expect(uploadReq.request.method == "POST")
        #expect(uploadReq.request.url.absoluteString == "https://dashscope-oss.example.com")
        #expect(uploadReq.header("Authorization") == nil)
        #expect(uploadReq.multipartPartNames() == [
            "OSSAccessKeyId", "Signature", "policy",
            "x-oss-object-acl", "x-oss-forbid-overwrite",
            "key", "success_action_status", "file",
        ])
        #expect(uploadReq.multipartText(named: "OSSAccessKeyId") == "LTAI-test")
        #expect(uploadReq.multipartText(named: "Signature") == "sig-base64")
        #expect(uploadReq.multipartText(named: "policy") == "policy-base64")
        #expect(uploadReq.multipartText(named: "x-oss-object-acl") == "private")
        #expect(uploadReq.multipartText(named: "x-oss-forbid-overwrite") == "true")
        #expect(uploadReq.multipartText(named: "success_action_status") == "200")
        let ossKey = try #require(uploadReq.multipartText(named: "key"))
        #expect(ossKey.hasPrefix("dashscope-instant/u1/2026-11-16/"))
        #expect(ossKey.hasSuffix(".m4a"))
        let uploadedFile = try #require(uploadReq.multipartFile(named: "file"))
        #expect(uploadedFile.data == audioBytes)

        // 3) 提交异步任务：异步头与 OSS 解析头、file_url
        let submitReq = reqs[2]
        #expect(submitReq.request.method == "POST")
        #expect(submitReq.request.url.absoluteString == "https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription")
        #expect(submitReq.header("Authorization") == "Bearer sk-dash-test")
        #expect(submitReq.header("X-DashScope-Async") == "enable")
        #expect(submitReq.header("X-DashScope-OssResourceResolve") == "enable")
        let submitJSON = try #require(submitReq.bodyJSONObject())
        #expect(submitJSON["model"] as? String == "qwen3-asr-flash-filetrans")
        let submitInput = try #require(submitJSON["input"] as? [String: Any])
        #expect(submitInput["file_url"] as? String == "oss://\(ossKey)")
        #expect(submitInput["context"] == nil)
        #expect(submitJSON["parameters"] == nil)

        // 4) 轮询与结果下载（预签名 URL 不附带 Bearer 头）
        #expect(reqs[3].request.url.absoluteString == "https://dashscope.aliyuncs.com/api/v1/tasks/task-101")
        #expect(reqs[3].header("Authorization") == "Bearer sk-dash-test")
        #expect(reqs[6].request.url.absoluteString == "https://result-oss.example.com/transcript.json?Signature=abc")
        #expect(reqs[6].header("Authorization") == nil)
    }

    @Test func 多次上传使用唯一文件名避免OSS禁止覆盖冲突() async throws {
        let fake = FakeHTTPTransport()
        for idx in 1...2 {
            try fake.enqueue(json: [
                "data": [
                    "policy": "p",
                    "signature": "s",
                    "upload_host": "https://oss.example.com",
                    "upload_dir": "dir",
                    "oss_access_key_id": "ak",
                    "x_oss_object_acl": "private",
                    "x_oss_forbid_overwrite": "true",
                ],
            ])
            fake.enqueue(HTTPResponse(status: 200))
            try fake.enqueue(json: ["output": ["task_id": "t-\(idx)", "task_status": "PENDING"]])
            try fake.enqueue(json: [
                "output": [
                    "task_id": "t-\(idx)",
                    "task_status": "SUCCEEDED",
                    "results": [["transcription_url": "https://oss.example.com/r-\(idx).json"]],
                ],
            ])
            try fake.enqueue(json: ["transcripts": [["sentences": [["begin_time": 0, "end_time": 500, "text": "好"]]]]])
        }

        let transcriber = DashScopeTranscriber(
            config: Self.makeConfig(),
            transport: fake,
            pollInterval: .milliseconds(1)
        )
        try await Self.withTempAudioFile(ext: "wav") { url in
            _ = try await transcriber.transcribe(audio: url, hotwords: []) { _ in }
            _ = try await transcriber.transcribe(audio: url, hotwords: []) { _ in }
        }

        let uploadKeys = fake.recordedRequests
            .filter { $0.request.url.host == "oss.example.com" && $0.request.method == "POST" }
            .compactMap { $0.multipartText(named: "key") }
        #expect(uploadKeys.count == 2)
        #expect(uploadKeys[0] != uploadKeys[1])
    }

    @Test func qwen模型通过corpus传入热词并在服务端400拒收时自动剥离重提() async throws {
        // 1) 正常传 parameters.corpus.text
        let happy = FakeHTTPTransport()
        try happy.enqueue(json: [
            "data": [
                "policy": "p", "signature": "s",
                "upload_host": "https://oss.example.com", "upload_dir": "dir",
                "oss_access_key_id": "ak",
            ],
        ])
        happy.enqueue(HTTPResponse(status: 200))
        try happy.enqueue(json: ["output": ["task_id": "t-qwen-1", "task_status": "PENDING"]])
        try happy.enqueue(json: [
            "output": [
                "task_id": "t-qwen-1",
                "task_status": "SUCCEEDED",
                "result": ["transcription_url": "https://oss.example.com/r1.json"],
            ],
        ])
        try happy.enqueue(json: ["transcripts": [["sentences": [["begin_time": 0, "end_time": 1000, "text": "Faymee 测试。"]]]]])

        let qwenTranscriber = DashScopeTranscriber(
            config: Self.makeConfig(model: "qwen3-asr-flash-filetrans"),
            transport: happy,
            pollInterval: .milliseconds(1)
        )
        let res1 = try await {
            var sentences: [TranscribedSentence] = []
            try await Self.withTempAudioFile(ext: "mp4") { url in
                sentences = try await qwenTranscriber.transcribe(audio: url, hotwords: [" Faymee ", "", "Faymee", "百炼"]) { _ in }
            }
            return sentences
        }()
        #expect(res1 == [TranscribedSentence(start: 0, end: 1, text: "Faymee 测试。")])

        // 不应调用 customization 接口，且 .mp4 应使用 audio/mp4 MIME
        #expect(!happy.recordedRequests.contains { $0.request.url.path.contains("customization") })
        let uploadedMP4 = try #require(happy.recordedRequests[1].multipartFile(named: "file"))
        #expect(uploadedMP4.mimeType == "audio/mp4")

        let submit1 = happy.recordedRequests[2]
        let submit1Body = try #require(submit1.bodyJSONObject())
        let submit1Input = try #require(submit1Body["input"] as? [String: Any])
        #expect(submit1Input["file_url"] as? String != nil)
        #expect(submit1Input["context"] == nil)
        let submit1Params = try #require(submit1Body["parameters"] as? [String: Any])
        let submit1Corpus = try #require(submit1Params["corpus"] as? [String: Any])
        let contextText = try #require(submit1Corpus["text"] as? String)
        #expect(contextText.contains("Faymee"))
        #expect(contextText.contains("百炼"))

        // 2) 服务端拒收 corpus 返回 HTTP 400 -> 自动剥离 parameters.corpus 重提一次
        let fallback = FakeHTTPTransport()
        try fallback.enqueue(json: [
            "data": [
                "policy": "p", "signature": "s",
                "upload_host": "https://oss.example.com", "upload_dir": "dir",
                "oss_access_key_id": "ak",
            ],
        ])
        fallback.enqueue(HTTPResponse(status: 200))
        try fallback.enqueue(json: ["code": "InvalidParameter", "message": "corpus is not supported"], status: 400)
        try fallback.enqueue(json: ["output": ["task_id": "t-qwen-2", "task_status": "PENDING"]])
        try fallback.enqueue(json: [
            "output": [
                "task_id": "t-qwen-2",
                "task_status": "SUCCEEDED",
                "result": ["transcription_url": "https://oss.example.com/r2.json"],
            ],
        ])
        try fallback.enqueue(json: ["transcripts": [["sentences": [["begin_time": 100, "end_time": 900, "text": "重提成功。"]]]]])

        let fallbackTranscriber = DashScopeTranscriber(
            config: Self.makeConfig(model: "qwen3-asr-flash-filetrans"),
            transport: fallback,
            pollInterval: .milliseconds(1)
        )
        let res2 = try await {
            var sentences: [TranscribedSentence] = []
            try await Self.withTempAudioFile { url in
                sentences = try await fallbackTranscriber.transcribe(audio: url, hotwords: ["Faymee"]) { _ in }
            }
            return sentences
        }()
        #expect(res2 == [TranscribedSentence(start: 0.1, end: 0.9, text: "重提成功。")])

        let submitAttempts = fallback.recordedRequests.filter { $0.request.url.path.hasSuffix("/asr/transcription") }
        #expect(submitAttempts.count == 2)
        let firstBody = try #require(submitAttempts[0].bodyJSONObject())
        let firstParams = try #require(firstBody["parameters"] as? [String: Any])
        let firstCorpus = try #require(firstParams["corpus"] as? [String: Any])
        #expect(firstCorpus["text"] as? String == "Faymee")
        let secondBody = try #require(submitAttempts[1].bodyJSONObject())
        let secondInput = try #require(secondBody["input"] as? [String: Any])
        #expect(secondBody["parameters"] == nil)
        #expect(secondInput["context"] == nil)
        #expect(secondInput["file_url"] as? String != nil)
    }

    @Test func paraformer与funAsr同步定制热词表并按指纹缓存与更新() async throws {
        let fake = FakeHTTPTransport()

        func enqueueUploadAndTask(taskID: String, text: String) throws {
            try fake.enqueue(json: [
                "data": [
                    "policy": "p", "signature": "s",
                    "upload_host": "https://oss.example.com", "upload_dir": "dir",
                    "oss_access_key_id": "ak",
                ],
            ])
            fake.enqueue(HTTPResponse(status: 200))
            // Caller inserts customization response right after upload when expected
            _ = (taskID, text)
        }

        // Run 1: policy + upload + create_vocabulary + submit + poll + result
        try enqueueUploadAndTask(taskID: "t1", text: "一")
        try fake.enqueue(json: ["output": ["vocabulary_id": "vocab-001"]])
        try fake.enqueue(json: ["output": ["task_id": "t1", "task_status": "PENDING"]])
        try fake.enqueue(json: [
            "output": [
                "task_id": "t1",
                "task_status": "SUCCEEDED",
                "results": [["transcription_url": "https://oss.example.com/r1.json"]],
            ],
        ])
        try fake.enqueue(json: ["transcripts": [["sentences": [["begin_time": 0, "end_time": 1000, "text": "第一轮。"]]]]])

        // Run 2 (相同热词命中指纹缓存，不请求 customization): policy + upload + submit + poll + result
        try enqueueUploadAndTask(taskID: "t2", text: "二")
        try fake.enqueue(json: ["output": ["task_id": "t2", "task_status": "PENDING"]])
        try fake.enqueue(json: [
            "output": [
                "task_id": "t2",
                "task_status": "SUCCEEDED",
                "results": [["transcription_url": "https://oss.example.com/r2.json"]],
            ],
        ])
        try fake.enqueue(json: ["transcripts": [["sentences": [["begin_time": 0, "end_time": 1000, "text": "第二轮。"]]]]])

        // Run 3 (热词变更，调用 update_vocabulary): policy + upload + update_vocabulary + submit + poll + result
        try enqueueUploadAndTask(taskID: "t3", text: "三")
        try fake.enqueue(json: ["output": ["vocabulary_id": "vocab-001"]])
        try fake.enqueue(json: ["output": ["task_id": "t3", "task_status": "PENDING"]])
        try fake.enqueue(json: [
            "output": [
                "task_id": "t3",
                "task_status": "SUCCEEDED",
                "results": [["transcription_url": "https://oss.example.com/r3.json"]],
            ],
        ])
        try fake.enqueue(json: ["transcripts": [["sentences": [["begin_time": 0, "end_time": 1000, "text": "第三轮。"]]]]])

        let transcriber = DashScopeTranscriber(
            config: Self.makeConfig(model: "paraformer-v2"),
            transport: fake,
            pollInterval: .milliseconds(1)
        )

        try await Self.withTempAudioFile { url in
            let r1 = try await transcriber.transcribe(audio: url, hotwords: ["Faymee", "语音转写"]) { _ in }
            #expect(r1.map(\.text) == ["第一轮。"])

            // 空白与重复整理后等价，应命中缓存
            let r2 = try await transcriber.transcribe(audio: url, hotwords: [" Faymee ", "语音转写", "Faymee"]) { _ in }
            #expect(r2.map(\.text) == ["第二轮。"])

            let r3 = try await transcriber.transcribe(audio: url, hotwords: ["Faymee", "会议纪要"]) { _ in }
            #expect(r3.map(\.text) == ["第三轮。"])
        }

        let customReqs = fake.recordedRequests.filter { $0.request.url.path.hasSuffix("/asr/customization") }
        #expect(customReqs.count == 2)

        let createBody = try #require(customReqs[0].bodyJSONObject())
        #expect(createBody["model"] as? String == "speech-biasing")
        let createInput = try #require(createBody["input"] as? [String: Any])
        #expect(createInput["action"] as? String == "create_vocabulary")
        #expect(createInput["target_model"] as? String == "paraformer-v2")
        let createVocab = try #require(createInput["vocabulary"] as? [[String: Any]])
        #expect(createVocab.compactMap { $0["text"] as? String } == ["Faymee", "语音转写"])

        let updateBody = try #require(customReqs[1].bodyJSONObject())
        #expect(updateBody["model"] as? String == "speech-biasing")
        let updateInput = try #require(updateBody["input"] as? [String: Any])
        #expect(updateInput["action"] as? String == "update_vocabulary")
        #expect(updateInput["vocabulary_id"] as? String == "vocab-001")
        let updateVocab = try #require(updateInput["vocabulary"] as? [[String: Any]])
        #expect(updateVocab.compactMap { $0["text"] as? String } == ["Faymee", "会议纪要"])

        let submitReqs = fake.recordedRequests.filter { $0.request.url.path.hasSuffix("/asr/transcription") }
        #expect(submitReqs.count == 3)
        for submit in submitReqs {
            let body = try #require(submit.bodyJSONObject())
            let input = try #require(body["input"] as? [String: Any])
            let urls = try #require(input["file_urls"] as? [String])
            #expect(urls.count == 1)
            #expect(urls[0].hasPrefix("oss://"))
            let params = try #require(body["parameters"] as? [String: Any])
            #expect(params["vocabulary_id"] as? String == "vocab-001")
        }

        // fun-asr 同样走 file_urls 与 speech-biasing
        let funFake = FakeHTTPTransport()
        try funFake.enqueue(json: [
            "data": [
                "policy": "p", "signature": "s",
                "upload_host": "https://oss.example.com", "upload_dir": "dir",
                "oss_access_key_id": "ak",
            ],
        ])
        funFake.enqueue(HTTPResponse(status: 200))
        try funFake.enqueue(json: ["output": ["vocabulary_id": "vocab-fun"]])
        try funFake.enqueue(json: ["output": ["task_id": "t-fun", "task_status": "PENDING"]])
        try funFake.enqueue(json: [
            "output": [
                "task_id": "t-fun",
                "task_status": "SUCCEEDED",
                "results": [["transcription_url": "https://oss.example.com/rfun.json"]],
            ],
        ])
        try funFake.enqueue(json: ["transcripts": [["sentences": [["begin_time": 0, "end_time": 500, "text": "fun-asr 测试。"]]]]])

        let funTranscriber = DashScopeTranscriber(
            config: Self.makeConfig(model: "fun-asr"),
            transport: funFake,
            pollInterval: .milliseconds(1)
        )
        try await Self.withTempAudioFile { url in
            let out = try await funTranscriber.transcribe(audio: url, hotwords: ["百炼"]) { _ in }
            #expect(out.map(\.text) == ["fun-asr 测试。"])
        }
        let funCreateInput = try #require(funFake.recordedRequests[2].bodyJSONObject()?["input"] as? [String: Any])
        #expect(funCreateInput["target_model"] as? String == "fun-asr")
    }

    @Test func customization返回400或任务提交因vocabulary_id返回400时自动剥离热词完成转写() async throws {
        // 1) customization 接口返回 400 -> 跳过 vocabulary_id 直接提交转写任务
        let custom400 = FakeHTTPTransport()
        try custom400.enqueue(json: [
            "data": [
                "policy": "p", "signature": "s",
                "upload_host": "https://oss.example.com", "upload_dir": "dir",
                "oss_access_key_id": "ak",
            ],
        ])
        custom400.enqueue(HTTPResponse(status: 200))
        try custom400.enqueue(json: ["code": "InvalidParameter", "message": "target_model not supported"], status: 400)
        try custom400.enqueue(json: ["output": ["task_id": "t-c400", "task_status": "PENDING"]])
        try custom400.enqueue(json: [
            "output": [
                "task_id": "t-c400",
                "task_status": "SUCCEEDED",
                "results": [["transcription_url": "https://oss.example.com/r1.json"]],
            ],
        ])
        try custom400.enqueue(json: ["transcripts": [["sentences": [["begin_time": 0, "end_time": 800, "text": "词表降级成功。"]]]]])

        let transcriber1 = DashScopeTranscriber(
            config: Self.makeConfig(model: "custom-paraformer"),
            transport: custom400,
            pollInterval: .milliseconds(1)
        )
        try await Self.withTempAudioFile { url in
            let out = try await transcriber1.transcribe(audio: url, hotwords: ["术语"]) { _ in }
            #expect(out.map(\.text) == ["词表降级成功。"])
        }
        let submitAfterCustom400 = try #require(
            custom400.recordedRequests.first { $0.request.url.path.hasSuffix("/asr/transcription") }?.bodyJSONObject()
        )
        #expect(submitAfterCustom400["parameters"] == nil)

        // 2) customization 成功，但任务提交因 vocabulary_id 返回 400 -> 剥离 vocabulary_id 重提一次
        let submit400 = FakeHTTPTransport()
        try submit400.enqueue(json: [
            "data": [
                "policy": "p", "signature": "s",
                "upload_host": "https://oss.example.com", "upload_dir": "dir",
                "oss_access_key_id": "ak",
            ],
        ])
        submit400.enqueue(HTTPResponse(status: 200))
        try submit400.enqueue(json: ["output": ["vocabulary_id": "vocab-x"]])
        try submit400.enqueue(json: ["code": "InvalidParameter", "message": "vocabulary_id unsupported"], status: 400)
        try submit400.enqueue(json: ["output": ["task_id": "t-s400", "task_status": "PENDING"]])
        try submit400.enqueue(json: [
            "output": [
                "task_id": "t-s400",
                "task_status": "SUCCEEDED",
                "results": [["transcription_url": "https://oss.example.com/r2.json"]],
            ],
        ])
        try submit400.enqueue(json: ["transcripts": [["sentences": [["begin_time": 0, "end_time": 800, "text": "任务重提成功。"]]]]])

        let transcriber2 = DashScopeTranscriber(
            config: Self.makeConfig(model: "paraformer-v2"),
            transport: submit400,
            pollInterval: .milliseconds(1)
        )
        try await Self.withTempAudioFile { url in
            let out = try await transcriber2.transcribe(audio: url, hotwords: ["术语"]) { _ in }
            #expect(out.map(\.text) == ["任务重提成功。"])
        }
        let submitReqs = submit400.recordedRequests.filter { $0.request.url.path.hasSuffix("/asr/transcription") }
        #expect(submitReqs.count == 2)
        let firstParams = try #require(submitReqs[0].bodyJSONObject()?["parameters"] as? [String: Any])
        #expect(firstParams["vocabulary_id"] as? String == "vocab-x")
        #expect(submitReqs[1].bodyJSONObject()?["parameters"] == nil)

        // 3) customization 返回 401 鉴权错误时绝不降级吞错
        let custom401 = FakeHTTPTransport()
        try custom401.enqueue(json: [
            "data": [
                "policy": "p", "signature": "s",
                "upload_host": "https://oss.example.com", "upload_dir": "dir",
                "oss_access_key_id": "ak",
            ],
        ])
        custom401.enqueue(HTTPResponse(status: 200))
        try custom401.enqueue(json: ["message": "Invalid API-key"], status: 401)

        let transcriber3 = DashScopeTranscriber(
            config: Self.makeConfig(model: "paraformer-v2"),
            transport: custom401,
            pollInterval: .milliseconds(1)
        )
        await #expect(throws: OnlineAPIError.unauthorized(401, "Invalid API-key")) {
            try await Self.withTempAudioFile { url in
                _ = try await transcriber3.transcribe(audio: url, hotwords: ["术语"]) { _ in }
            }
        }
    }

    @Test func updateVocabulary返回400时清空过期缓存并重试createVocabulary一次_双400则退回nil() async throws {
        let fake = FakeHTTPTransport()
        func enqueuePolicyAndUpload() throws {
            try fake.enqueue(json: [
                "data": [
                    "policy": "p", "signature": "s",
                    "upload_host": "https://oss.example.com", "upload_dir": "dir",
                    "oss_access_key_id": "ak",
                ],
            ])
            fake.enqueue(HTTPResponse(status: 200))
        }
        func enqueueTaskCycle(taskID: String, text: String) throws {
            try fake.enqueue(json: ["output": ["task_id": taskID, "task_status": "PENDING"]])
            try fake.enqueue(json: [
                "output": [
                    "task_id": taskID,
                    "task_status": "SUCCEEDED",
                    "results": [["transcription_url": "https://oss.example.com/\(taskID).json"]],
                ],
            ])
            try fake.enqueue(json: ["transcripts": [["sentences": [["begin_time": 0, "end_time": 500, "text": text]]]]])
        }

        // 1) 首次创建词表 -> vocab-stale
        try enqueuePolicyAndUpload()
        try fake.enqueue(json: ["output": ["vocabulary_id": "vocab-stale"]])
        try enqueueTaskCycle(taskID: "t1", text: "第一轮。")

        // 2) 热词变更：update_vocabulary 返回 400（过期词表） -> 清空缓存并重试 create_vocabulary -> vocab-fresh
        try enqueuePolicyAndUpload()
        try fake.enqueue(json: ["code": "InvalidParameter", "message": "vocabulary_id not found"], status: 400)
        try fake.enqueue(json: ["output": ["vocabulary_id": "vocab-fresh"]])
        try enqueueTaskCycle(taskID: "t2", text: "重建成功。")

        // 3) 相同热词再次转写应命中新建缓存，不再请求 customization
        try enqueuePolicyAndUpload()
        try enqueueTaskCycle(taskID: "t3", text: "命中新缓存。")

        // 4) 热词再变更：update_vocabulary 返回 400 且重试 create_vocabulary 也返回 400 -> 清空缓存并退回无词表提交
        try enqueuePolicyAndUpload()
        try fake.enqueue(json: ["code": "InvalidParameter", "message": "vocabulary expired"], status: 400)
        try fake.enqueue(json: ["code": "InvalidParameter", "message": "create failed"], status: 400)
        try enqueueTaskCycle(taskID: "t4", text: "双400降级。")

        // 5) 缓存已被清空，再次调用仍会重新发起 create_vocabulary 而不是跳过或用旧 ID
        try enqueuePolicyAndUpload()
        try fake.enqueue(json: ["output": ["vocabulary_id": "vocab-recovered"]])
        try enqueueTaskCycle(taskID: "t5", text: "恢复创建。")

        let transcriber = DashScopeTranscriber(
            config: Self.makeConfig(model: "paraformer-v2"),
            transport: fake,
            pollInterval: .milliseconds(1)
        )
        try await Self.withTempAudioFile { url in
            let r1 = try await transcriber.transcribe(audio: url, hotwords: ["Faymee"]) { _ in }
            #expect(r1.map(\.text) == ["第一轮。"])

            let r2 = try await transcriber.transcribe(audio: url, hotwords: ["Faymee", "百炼"]) { _ in }
            #expect(r2.map(\.text) == ["重建成功。"])

            let r3 = try await transcriber.transcribe(audio: url, hotwords: ["Faymee", "百炼"]) { _ in }
            #expect(r3.map(\.text) == ["命中新缓存。"])

            let r4 = try await transcriber.transcribe(audio: url, hotwords: ["Faymee", "纪要"]) { _ in }
            #expect(r4.map(\.text) == ["双400降级。"])

            let r5 = try await transcriber.transcribe(audio: url, hotwords: ["Faymee", "纪要"]) { _ in }
            #expect(r5.map(\.text) == ["恢复创建。"])
        }

        let customActions = fake.recordedRequests
            .filter { $0.request.url.path.hasSuffix("/asr/customization") }
            .compactMap { ($0.bodyJSONObject()?["input"] as? [String: Any])?["action"] as? String }
        #expect(customActions == [
            "create_vocabulary",
            "update_vocabulary",
            "create_vocabulary",
            "update_vocabulary",
            "create_vocabulary",
            "create_vocabulary",
        ])

        let submitVocabIDs = fake.recordedRequests
            .filter { $0.request.url.path.hasSuffix("/asr/transcription") }
            .map { ($0.bodyJSONObject()?["parameters"] as? [String: Any])?["vocabulary_id"] as? String }
        #expect(submitVocabIDs == ["vocab-stale", "vocab-fresh", "vocab-fresh", nil, "vocab-recovered"])
    }

    @Test func 任务提交400明确为模型不存在时不剥离热词重试_通用参数错误仍重试() async throws {
        // 1) ModelNotFound -> 立即抛出 badRequest，不剥离热词重试
        let missingTransport = FakeHTTPTransport()
        try missingTransport.enqueue(json: [
            "data": [
                "policy": "p", "signature": "s",
                "upload_host": "https://oss.example.com", "upload_dir": "dir",
                "oss_access_key_id": "ak",
            ],
        ])
        missingTransport.enqueue(HTTPResponse(status: 200))
        try missingTransport.enqueue(json: ["code": "ModelNotFound", "message": "Model not found"], status: 400)

        let missingTranscriber = DashScopeTranscriber(
            config: Self.makeConfig(model: "qwen3-nonexistent"),
            transport: missingTransport,
            pollInterval: .milliseconds(1)
        )
        await #expect(throws: OnlineAPIError.badRequest(400, "Model not found")) {
            try await Self.withTempAudioFile { url in
                _ = try await missingTranscriber.transcribe(audio: url, hotwords: ["Faymee"]) { _ in }
            }
        }
        let missingSubmits = missingTransport.recordedRequests.filter { $0.request.url.path.hasSuffix("/asr/transcription") }
        #expect(missingSubmits.count == 1)

        // 2) 参数不支持即便提及 model（如 "Model does not support corpus"）仍应剥离热词重试
        let unsupportedParamTransport = FakeHTTPTransport()
        try unsupportedParamTransport.enqueue(json: [
            "data": [
                "policy": "p", "signature": "s",
                "upload_host": "https://oss.example.com", "upload_dir": "dir",
                "oss_access_key_id": "ak",
            ],
        ])
        unsupportedParamTransport.enqueue(HTTPResponse(status: 200))
        try unsupportedParamTransport.enqueue(
            json: ["code": "InvalidParameter", "message": "Model does not support corpus"],
            status: 400
        )
        try unsupportedParamTransport.enqueue(json: ["output": ["task_id": "t-ok", "task_status": "PENDING"]])
        try unsupportedParamTransport.enqueue(json: [
            "output": [
                "task_id": "t-ok",
                "task_status": "SUCCEEDED",
                "result": ["transcription_url": "https://oss.example.com/ok.json"],
            ],
        ])
        try unsupportedParamTransport.enqueue(json: ["transcripts": [["sentences": [["begin_time": 0, "end_time": 500, "text": "成功。"]]]]])

        let paramTranscriber = DashScopeTranscriber(
            config: Self.makeConfig(model: "qwen3-asr-flash-filetrans"),
            transport: unsupportedParamTransport,
            pollInterval: .milliseconds(1)
        )
        let result = try await {
            var out: [TranscribedSentence] = []
            try await Self.withTempAudioFile { url in
                out = try await paramTranscriber.transcribe(audio: url, hotwords: ["Faymee"]) { _ in }
            }
            return out
        }()
        #expect(result.map(\.text) == ["成功。"])
        let paramSubmits = unsupportedParamTransport.recordedRequests.filter { $0.request.url.path.hasSuffix("/asr/transcription") }
        #expect(paramSubmits.count == 2)
    }

    @Test func 服务端任务FAILED_子任务失败与HTTP异常转换为对应OnlineAPIError() async throws {
        // 1) task_status == FAILED
        let failedTransport = FakeHTTPTransport()
        try failedTransport.enqueue(json: [
            "data": [
                "policy": "p", "signature": "s",
                "upload_host": "https://oss.example.com", "upload_dir": "dir",
                "oss_access_key_id": "ak",
            ],
        ])
        failedTransport.enqueue(HTTPResponse(status: 200))
        try failedTransport.enqueue(json: ["output": ["task_id": "t-fail", "task_status": "PENDING"]])
        try failedTransport.enqueue(json: [
            "output": [
                "task_id": "t-fail",
                "task_status": "FAILED",
                "code": "AudioDecodeError",
                "message": "Unsupported audio codec",
            ],
        ])

        let t1 = DashScopeTranscriber(config: Self.makeConfig(), transport: failedTransport, pollInterval: .milliseconds(1))
        await #expect(throws: OnlineAPIError.remoteTaskFailed("Unsupported audio codec")) {
            try await Self.withTempAudioFile { url in
                _ = try await t1.transcribe(audio: url, hotwords: []) { _ in }
            }
        }

        // 2) subtask_status == FAILED
        let subtaskFailed = FakeHTTPTransport()
        try subtaskFailed.enqueue(json: [
            "data": [
                "policy": "p", "signature": "s",
                "upload_host": "https://oss.example.com", "upload_dir": "dir",
                "oss_access_key_id": "ak",
            ],
        ])
        subtaskFailed.enqueue(HTTPResponse(status: 200))
        try subtaskFailed.enqueue(json: ["output": ["task_id": "t-sub", "task_status": "PENDING"]])
        try subtaskFailed.enqueue(json: [
            "output": [
                "task_id": "t-sub",
                "task_status": "SUCCEEDED",
                "results": [[
                    "subtask_status": "FAILED",
                    "code": "FILE_DOWNLOAD_FAILED",
                    "message": "OSS resource expired",
                ]],
            ],
        ])

        let t2 = DashScopeTranscriber(
            config: Self.makeConfig(model: "paraformer-v2"),
            transport: subtaskFailed,
            pollInterval: .milliseconds(1)
        )
        await #expect(throws: OnlineAPIError.remoteTaskFailed("OSS resource expired")) {
            try await Self.withTempAudioFile { url in
                _ = try await t2.transcribe(audio: url, hotwords: []) { _ in }
            }
        }

        // 3) getPolicy 返回 429 限流
        let rateLimited = FakeHTTPTransport()
        try rateLimited.enqueue(json: ["message": "Rate limit exceeded"], status: 429)
        let t3 = DashScopeTranscriber(config: Self.makeConfig(), transport: rateLimited, pollInterval: .milliseconds(1))
        await #expect(throws: OnlineAPIError.rateLimited("Rate limit exceeded")) {
            try await Self.withTempAudioFile { url in
                _ = try await t3.transcribe(audio: url, hotwords: []) { _ in }
            }
        }
    }

    @Test func 上传阶段与轮询等待阶段取消时立即中止并抛出CancellationError() async throws {
        // 1) 上传阶段阻塞时取消
        let uploadStarted = AsyncStream<Void>.makeStream()
        let uploadCancelTransport = FakeHTTPTransport()
        try uploadCancelTransport.enqueue(json: [
            "data": [
                "policy": "p", "signature": "s",
                "upload_host": "https://oss.example.com", "upload_dir": "dir",
                "oss_access_key_id": "ak",
            ],
        ])
        uploadCancelTransport.enqueue { _ in
            uploadStarted.continuation.yield()
            try await Task.sleep(for: .seconds(10))
            return HTTPResponse(status: 200)
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaymeeDashCancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audioURL = dir.appendingPathComponent("clip.wav")
        try Data("WAV".utf8).write(to: audioURL)

        let uploadTranscriber = DashScopeTranscriber(
            config: Self.makeConfig(),
            transport: uploadCancelTransport,
            pollInterval: .milliseconds(1)
        )
        let uploadTask = Task {
            try await uploadTranscriber.transcribe(audio: audioURL, hotwords: []) { _ in }
        }
        for await _ in uploadStarted.stream { break }
        uploadTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await uploadTask.value
        }
        #expect(uploadCancelTransport.cancelledRequests.count == 1)
        #expect(uploadCancelTransport.cancelledRequests.first?.url.absoluteString == "https://oss.example.com")
        #expect(uploadCancelTransport.recordedRequests.count == 2)

        // 2) 轮询等待间隔期间取消，应立即唤醒退出而不发出后续轮询请求
        let submitDone = AsyncStream<Void>.makeStream()
        let pollCancelTransport = FakeHTTPTransport()
        try pollCancelTransport.enqueue(json: [
            "data": [
                "policy": "p", "signature": "s",
                "upload_host": "https://oss.example.com", "upload_dir": "dir",
                "oss_access_key_id": "ak",
            ],
        ])
        pollCancelTransport.enqueue(HTTPResponse(status: 200))
        pollCancelTransport.enqueue { _ in
            defer { submitDone.continuation.yield() }
            return try HTTPResponse.json(["output": ["task_id": "t-poll-cancel", "task_status": "PENDING"]])
        }

        let pollTranscriber = DashScopeTranscriber(
            config: Self.makeConfig(),
            transport: pollCancelTransport,
            pollInterval: .seconds(10)
        )
        let clock = ContinuousClock()
        let start = clock.now
        let pollTask = Task {
            try await pollTranscriber.transcribe(audio: audioURL, hotwords: []) { _ in }
        }
        for await _ in submitDone.stream { break }
        pollTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await pollTask.value
        }
        // 只应发过 getPolicy、upload、submit 共 3 个请求，且未等待 10 秒轮询间隔
        #expect(pollCancelTransport.recordedRequests.count == 3)
        #expect(clock.now - start < .seconds(2))
    }

    @Test func testConnection使用探测短音频走完百炼四步并在鉴权或404异常时报错() async throws {
        // 1) 成功通路：上传的是合法 32044 字节 WAV 探测音频
        let okTransport = FakeHTTPTransport()
        try okTransport.enqueue(json: [
            "data": [
                "policy": "p", "signature": "s",
                "upload_host": "https://oss.example.com", "upload_dir": "probe",
                "oss_access_key_id": "ak",
            ],
        ])
        okTransport.enqueue(HTTPResponse(status: 200))
        try okTransport.enqueue(json: ["output": ["task_id": "t-probe", "task_status": "PENDING"]])
        try okTransport.enqueue(json: [
            "output": [
                "task_id": "t-probe",
                "task_status": "SUCCEEDED",
                "result": ["transcription_url": "https://oss.example.com/probe-result.json"],
            ],
        ])
        try okTransport.enqueue(json: ["transcripts": [["channel_id": 0, "text": "", "sentences": []]]])

        try await DashScopeTranscriber.testConnection(
            config: Self.makeConfig(),
            transport: okTransport,
            pollInterval: .milliseconds(1)
        )
        #expect(okTransport.recordedRequests.count == 5)
        let uploaded = try #require(okTransport.recordedRequests[1].multipartFile(named: "file"))
        #expect(uploaded.mimeType == "audio/wav")
        #expect(uploaded.data == ProbeAudio.wavData())

        // 2) 401 鉴权失败
        let unauthorizedTransport = FakeHTTPTransport()
        try unauthorizedTransport.enqueue(json: ["message": "Invalid ApiKey"], status: 401)
        await #expect(throws: OnlineAPIError.unauthorized(401, "Invalid ApiKey")) {
            try await DashScopeTranscriber.testConnection(
                config: Self.makeConfig(),
                transport: unauthorizedTransport,
                pollInterval: .milliseconds(1)
            )
        }

        // 3) 404 模型或接口不存在
        let notFoundTransport = FakeHTTPTransport()
        try notFoundTransport.enqueue(json: ["message": "Model not found"], status: 404)
        await #expect(throws: OnlineAPIError.notFound("Model not found")) {
            try await DashScopeTranscriber.testConnection(
                config: Self.makeConfig(),
                transport: notFoundTransport,
                pollInterval: .milliseconds(1)
            )
        }

        // 4) 底层断网错误
        let networkFailTransport = FakeHTTPTransport()
        networkFailTransport.enqueue(error: OnlineAPIError.networkUnavailable("Offline"))
        await #expect(throws: OnlineAPIError.networkUnavailable("Offline")) {
            try await DashScopeTranscriber.testConnection(
                config: Self.makeConfig(),
                transport: networkFailTransport,
                pollInterval: .milliseconds(1)
            )
        }
    }
}

/// 真实网络契约测试：显式设置 `FAYMEE_ONLINE_CONTRACT=1` 且提供 `DASHSCOPE_API_KEY` 时运行，默认跳过
@Suite(.enabled(
    if: ProcessInfo.processInfo.environment["FAYMEE_ONLINE_CONTRACT"] == "1"
        && !(ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
    "设 FAYMEE_ONLINE_CONTRACT=1 且提供 DASHSCOPE_API_KEY 才跑"
))
struct DashScopeTranscriberContractTests {
    @Test func 真实百炼文件转写连接测试与中文样本转写() async throws {
        let env = ProcessInfo.processInfo.environment
        let apiKey = (env["DASHSCOPE_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = env["FAYMEE_DASHSCOPE_BASE_URL"] ?? OnlineTranscriptionProvider.dashScope.defaultBaseURL
        let model = env["FAYMEE_DASHSCOPE_MODEL"] ?? OnlineTranscriptionProvider.dashScope.defaultModel

        let config = OnlineEndpointConfig(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            requiresHTTPS: true,
            requiresAPIKey: true,
            providerID: OnlineTranscriptionProvider.dashScope.providerID
        )
        let transport = URLSessionHTTPTransport()

        try await DashScopeTranscriber.testConnection(config: config, transport: transport)

        if let sampleURL = Bundle.module.url(forResource: "zh-sample", withExtension: "m4a", subdirectory: "Resources") {
            let transcriber = DashScopeTranscriber(config: config, transport: transport)
            try await transcriber.prepare { _ in }
            let sentences = try await transcriber.transcribe(audio: sampleURL, hotwords: ["飞书"]) { _ in }
            #expect(!sentences.isEmpty)
            #expect(sentences.allSatisfy { 0 <= $0.start && $0.start <= $0.end })
            #expect(zip(sentences, sentences.dropFirst()).allSatisfy { $0.start <= $1.start })
        }
    }
}
