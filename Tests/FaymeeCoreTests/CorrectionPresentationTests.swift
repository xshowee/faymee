import Foundation
import Testing
@testable import FaymeeCore

/// 纠错的界面文字：转写稿顶部的状态行、设置里开关下的说明（spec「开关与引擎」「界面」）
@Suite struct CorrectionPresentationTests {
    private func transcript(corrected: Int) -> Transcript {
        let items = (0..<3).map { i in
            TranscriptItem.sentence(TranscriptSentence(id: "s\(i)", start: 0, end: 1, text: "改后",
                                                       correction: i < corrected ? "改前" : nil))
        }
        return Transcript(engine: "e", createdAt: Date(timeIntervalSince1970: 0), hotwords: [], items: items)
    }

    @Test func 纠错完成后状态行显示已纠错N句和撤销全部() {
        let status = CorrectionStatus(state: CorrectionState(status: .done), transcript: transcript(corrected: 2))
        #expect(status == .corrected(count: 2))
        #expect(status.text == "已纠错 2 句")
        #expect(status.actionTitle == "撤销全部")
    }

    @Test func 没改任何句子或全部撤销后不显示() {
        #expect(CorrectionStatus(state: CorrectionState(status: .done), transcript: transcript(corrected: 0)) == .hidden)
        #expect(CorrectionStatus(state: nil, transcript: transcript(corrected: 0)) == .hidden)
    }

    @Test func 失败时显示纠错失败和重试() {
        let status = CorrectionStatus(state: CorrectionState(status: .failed, error: "内存不足"),
                                      transcript: transcript(corrected: 0))
        #expect(status == .failed(reason: "内存不足"))
        #expect(status.text == "纠错失败")
        #expect(status.actionTitle == "重试")
    }

    @Test func 排队和进行中不在状态行显示_由会议列表的进度说明() {
        #expect(CorrectionStatus(state: CorrectionState(status: .queued), transcript: transcript(corrected: 0)) == .hidden)
        #expect(CorrectionStatus(state: CorrectionState(status: .running), transcript: transcript(corrected: 1)) == .hidden)
    }

    @Test func 设置里的说明随纪要引擎变化() {
        #expect(CorrectionCaption.text(.local(modelName: "Qwen3.5 4B"))
                == "用纪要模型（本机 Qwen3.5 4B）改正听错的字词；接通电源时才开始")
        #expect(CorrectionCaption.text(.online(provider: "百炼", model: "qwen-plus"))
                == "用纪要模型（在线 · 百炼 qwen-plus）改正识别错误")
        #expect(CorrectionCaption.text(.notReady) == "纪要模型就绪后才能纠错")
    }
}
