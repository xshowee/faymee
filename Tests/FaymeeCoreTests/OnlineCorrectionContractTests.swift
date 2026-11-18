import Foundation
import Testing
@testable import FaymeeCore

private let env = ProcessInfo.processInfo.environment
private let deepSeekKey = env["FAYMEE_DEEPSEEK_API_KEY"] ?? ""

/// 记下真实响应，用来看服务端报的思考 token 数
private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let base = URLSessionHTTPTransport()
    private let lock = NSLock()
    private var responses: [HTTPResponse] = []

    var reasoningTokens: [Int] {
        lock.withLock { responses }.map { response in
            let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            let details = (json?["usage"] as? [String: Any])?["completion_tokens_details"] as? [String: Any]
            return details?["reasoning_tokens"] as? Int ?? 0
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await base.send(request)
        lock.withLock { responses.append(response) }
        return response
    }
}

/// 在线整句改写纠错的真实请求契约测试（可选）：设 `FAYMEE_ONLINE_CONTRACT=1` 和 `FAYMEE_DEEPSEEK_API_KEY` 才跑。
/// 只发这里写的合成文字。检查的是请求被接受（JSON 模式、关思考）、服务端没有思考、输出能解析、
/// 过护栏后口吃和口语词原样保留，
/// 不比较纠错准确率（spec「测试决定」最后一条）
@Suite(.enabled(if: env["FAYMEE_ONLINE_CONTRACT"] == "1" && !deepSeekKey.isEmpty,
                "设 FAYMEE_ONLINE_CONTRACT=1 和 FAYMEE_DEEPSEEK_API_KEY 才跑"))
struct OnlineCorrectionContractTests {
    /// 合成的周会片段：放进近音错字、复读残留、标记、重复整句、漏字，以及要保留的口吃和口语词
    private let texts = [
        "嗯我们今天主要过一下智能体项目的进度",
        "上周我们定了要做端到端的评测",
        "现在的问题是工具调用这块比较对动",
        "我我我觉得还是要先把评测集补齐",
        "那个评测集现在有两百条左右",
        "龚老师那边说下周可以再给一批",
        "好的那我们就先这样吧吧吧吧吧吧",
        "然后是工会上的那台测试机",
        "测试机 [breath] 下周要还回去",
        "测试机下周要还回去",
        "测试机下周要还回去",
        "我们要做一个端道的方案把数据都接上",
        "智能体的规划能力也要单独评一下",
        "这个我们下周再讨论",
    ]

    private var transcript: Transcript {
        let items = texts.enumerated().map { i, text in
            TranscriptItem.sentence(TranscriptSentence(id: "s\(i + 1)", start: Double(i * 6), end: Double(i * 6 + 5),
                                                       text: text))
        }
        return Transcript(engine: "apple/speechanalyzer", createdAt: Date(timeIntervalSince1970: 0), hotwords: [],
                          items: items)
    }

    @Test func DeepSeek整句改写的输出能解析_过护栏后口吃和口语词原样保留() async throws {
        let config = OnlineEndpointConfig(
            baseURL: env["FAYMEE_DEEPSEEK_BASE_URL"] ?? OnlineMinutesProvider.deepSeek.defaultBaseURL,
            model: env["FAYMEE_DEEPSEEK_MODEL"] ?? OnlineMinutesProvider.deepSeek.defaultModel,
            apiKey: deepSeekKey,
            requiresHTTPS: true,
            requiresAPIKey: true,
            providerID: OnlineMinutesProvider.deepSeek.providerID
        )
        let transport = RecordingTransport()
        let generator = OnlineMinutesEngine.makeGenerator(provider: .deepSeek, config: config, transport: transport)
        let review = try await correctTranscript(transcript, title: "智能体项目周会", hotwords: ["龚老师"],
                                                 method: .sentenceRewrite, generator: generator)
        for (id, text) in review.texts.sorted(by: { $0.key < $1.key }) {
            print("纠错 \(id): \(texts[Int(id.dropFirst())! - 1]) → \(text)")
        }
        print("纠错 建议: \(review.suggestions)")
        print("纠错 挡掉: \(review.rejections)")
        print("纠错 思考 token: \(transport.reasoningTokens)")

        // 纠错关思考：deepseek-flash 默认思考，思考吃光输出上限时正文为空（FAYMEE_DEEPSEEK_MODEL=deepseek-flash）
        #expect(!transport.reasoningTokens.isEmpty && transport.reasoningTokens.allSatisfy { $0 == 0 })

        #expect(review.rejections[CorrectionRule.unparseable.rawValue] == nil)
        // 口吃、口语词所在的句子：改了也只能是换字词或补字，不会删掉「我我我」「嗯」「那个」
        for (id, kept) in [("s1", "嗯"), ("s4", "我我我"), ("s5", "那个")] {
            #expect(review.texts[id].map { $0.contains(kept) } ?? true)
        }
    }
}
