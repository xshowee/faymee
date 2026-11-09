import Foundation
import Testing
@testable import FaymeeCore

private let transcript = Transcript(engine: "fake", createdAt: Date(timeIntervalSince1970: 0), hotwords: [], items: [])

@Suite struct TranscriptionNoticeTests {
    @Test func doneNotifiesWithMeetingTitle() {
        let notice = TranscriptionNotice.make(for: .done(transcript), meetingTitle: "周会", isRecording: false)
        #expect(notice == TranscriptionNotice(title: "转写完成", body: "周会"))
    }

    @Test func failureNotifiesWithReason() {
        let notice = TranscriptionNotice.make(for: .failed("模型加载失败"), meetingTitle: "周会", isRecording: false)
        #expect(notice == TranscriptionNotice(title: "转写失败", body: "周会：模型加载失败"))
    }

    /// 录音时不打扰，完成和失败都不发
    @Test(arguments: [TranscriptionOutcome.done(transcript), .failed("模型加载失败")])
    func silentWhileRecording(_ outcome: TranscriptionOutcome) {
        #expect(TranscriptionNotice.make(for: outcome, meetingTitle: "周会", isRecording: true) == nil)
    }
}
