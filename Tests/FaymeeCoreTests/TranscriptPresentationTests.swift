import Foundation
import Testing
@testable import FaymeeCore

private func status(_ state: TranscriptionState?, activity: TranscriptionActivity? = nil,
                    wait: TranscriptionWaitReason? = nil) -> TranscriptionStatus {
    TranscriptionStatus(state: state, activity: activity, waitReason: wait)
}

@Suite struct TranscriptionStatusTests {
    @Test func 从未转写时提供转写按钮() {
        let s = status(nil)
        #expect(s == .notTranscribed)
        #expect(s.text == nil)
        #expect(s.actionTitle == "转写")
        #expect(!s.opensSettings)
        #expect(s.progress == nil)
    }

    @Test(arguments: [
        (TranscriptionWaitReason?.none, "排队中", String?.none, false),
        (.onlineConfig, "等待配置在线转写", "前往设置", true),
    ])
    func 排队中显示在等什么_等待在线配置时提供前往设置(_ wait: TranscriptionWaitReason?, _ text: String,
                                              _ action: String?, _ opensSettings: Bool) {
        let s = status(TranscriptionState(status: .queued), wait: wait)
        #expect(s == .queued(wait))
        #expect(s.text == text)
        #expect(s.actionTitle == action)
        #expect(s.opensSettings == opensSettings)
        #expect(s.progress == nil)
    }

    @Test func 准备与转写中按管线进度显示() {
        let preparing = status(TranscriptionState(status: .running), activity: .preparing(0.42))
        #expect(preparing == .preparing(0.42))
        #expect(preparing.text == "正在准备转写引擎（42%）")
        #expect(preparing.progress == 0.42)
        #expect(preparing.actionTitle == nil)
        #expect(!preparing.opensSettings)

        let transcribing = status(TranscriptionState(status: .running), activity: .transcribing(0.5))
        #expect(transcribing == .transcribing(0.5))
        #expect(transcribing.text == "转写中 50%")
        #expect(transcribing.progress == 0.5)
        #expect(transcribing.actionTitle == nil)

        let noProgress = status(TranscriptionState(status: .running))
        #expect(noProgress == .transcribing(nil))
        #expect(noProgress.text == "转写中…")
        #expect(noProgress.progress == nil)
    }

    @Test func 区分说话人中转写状态不重复显示() {
        let s = status(TranscriptionState(status: .done), activity: .diarizing(0.6))
        #expect(s == .diarizing)
        #expect(s.text == nil)
        #expect(s.actionTitle == nil)
        #expect(!s.opensSettings)
        #expect(s.progress == nil)
    }

    @Test func 失败显示原因和重试_完成时不显示() {
        let failed = status(TranscriptionState(status: .failed, error: "接口超时"))
        #expect(failed == .failed("接口超时"))
        #expect(failed.text == "接口超时")
        #expect(failed.actionTitle == "重试")
        #expect(!failed.opensSettings)
        #expect(status(TranscriptionState(status: .failed)).text == "转写失败")

        let done = status(TranscriptionState(status: .done))
        #expect(done == .done)
        #expect(done.text == nil)
        #expect(done.actionTitle == nil)
        #expect(!done.opensSettings)
    }

    @Test(arguments: [
        ("", String?.none),
        ("apple/speechanalyzer", nil),
        ("apple/other", nil),
        ("dashscope/qwen3-asr-flash-filetrans", "dashscope/qwen3-asr-flash-filetrans"),
        ("openai/gpt-transcribe", "openai/gpt-transcribe"),
        ("openai-compatible/whisper-large-v3", "openai-compatible/whisper-large-v3"),
    ])
    func 在线转写来源标识_本机或空返回空_在线原样返回(_ engine: String, _ expected: String?) {
        let transcript = Transcript(engine: engine, createdAt: Date(timeIntervalSince1970: 0), hotwords: [], items: [])
        #expect(transcript.onlineEngineLabel == expected)
    }

    @Test func 在线引擎生成的转写稿复制全文与本机完全一致且不含模型水印() {
        let items: [TranscriptItem] = [
            .sentence(TranscriptSentence(id: "s1", start: 5, end: 9, text: "我们先过一下上周的待办")),
            .sentence(TranscriptSentence(id: "s2", start: 65, end: 70, text: "周三前发给客户")),
        ]
        let local = Transcript(engine: "apple/speechanalyzer", createdAt: Date(timeIntervalSince1970: 0),
                               hotwords: [], items: items)
        let online = Transcript(engine: "dashscope/qwen3-asr-flash-filetrans", createdAt: Date(timeIntervalSince1970: 0),
                                hotwords: [], items: items)

        let text = online.plainText(meeting: nil)
        #expect(text == local.plainText(meeting: nil))
        #expect(!text.contains("dashscope"))
        #expect(!text.contains("qwen3-asr-flash-filetrans"))
    }
}
