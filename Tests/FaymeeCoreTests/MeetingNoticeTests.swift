import Foundation
import Testing
@testable import FaymeeCore

private let transcript = Transcript(engine: "fake", createdAt: Date(timeIntervalSince1970: 0), hotwords: [], items: [])

@Suite struct MeetingNoticeTests {
    @Test func doneNotifiesWithMeetingTitle() {
        let notice = MeetingNotice.transcription(.done(transcript), meetingTitle: "周会", isRecording: false)
        #expect(notice == MeetingNotice(title: "转写完成", body: "周会"))
    }

    @Test func failureNotifiesWithReason() {
        let notice = MeetingNotice.transcription(.failed("模型加载失败"), meetingTitle: "周会", isRecording: false)
        #expect(notice == MeetingNotice(title: "转写失败", body: "周会：模型加载失败"))
    }

    /// 录音时不打扰，完成和失败都不发
    @Test(arguments: [TranscriptionOutcome.done(transcript), .failed("模型加载失败")])
    func silentWhileRecording(_ outcome: TranscriptionOutcome) {
        #expect(MeetingNotice.transcription(outcome, meetingTitle: "周会", isRecording: true) == nil)
    }

    // MARK: - 转写完成后纪要会怎样

    /// 纪要马上就能开始（只等这场转写收尾，或什么都不等）：不发转写通知，纪要完成时再发一条
    @Test(arguments: [MinutesWaitReason?.none, .transcription])
    func noTranscriptionNoticeWhenMinutesStartRightAway(_ wait: MinutesWaitReason?) {
        #expect(MeetingNotice.transcription(.done(transcript), meetingTitle: "周会", isRecording: false,
                                            minutes: .queued(waitingFor: wait)) == nil)
    }

    @Test func onBatteryTellsMinutesWaitForPower() {
        let notice = MeetingNotice.transcription(.done(transcript), meetingTitle: "周会", isRecording: false,
                                                 minutes: .queued(waitingFor: .power))
        #expect(notice == MeetingNotice(title: "转写完成", body: "周会\n接通电源后生成纪要"))
        #expect(notice?.action == nil)
    }

    /// 点通知打开设置里的模型下载
    @Test func withoutModelTellsToDownloadAndOpensDownload() {
        let notice = MeetingNotice.transcription(.done(transcript), meetingTitle: "周会", isRecording: false,
                                                 minutes: .queued(waitingFor: .model))
        #expect(notice == MeetingNotice(title: "转写完成", body: "周会\n生成纪要需要先下载模型",
                                        action: .openModelDownload))
    }

    /// 纪要不会自动生成（开关关、内容太少）时照旧，不附说明
    @Test func notQueuedNotifiesAsBefore() {
        let notice = MeetingNotice.transcription(.done(transcript), meetingTitle: "周会", isRecording: false,
                                                 minutes: .notQueued)
        #expect(notice == MeetingNotice(title: "转写完成", body: "周会"))
        #expect(notice?.action == nil)
    }

    @Test(arguments: [MinutesFollowUp.notQueued, .queued(waitingFor: .model), .queued(waitingFor: .power)])
    func silentWhileRecordingWhateverMinutesDo(_ followUp: MinutesFollowUp) {
        #expect(MeetingNotice.transcription(.done(transcript), meetingTitle: "周会", isRecording: true,
                                            minutes: followUp) == nil)
    }

    @Test func failureIgnoresMinutes() {
        let notice = MeetingNotice.transcription(.failed("模型加载失败"), meetingTitle: "周会", isRecording: false,
                                                 minutes: .queued(waitingFor: .model))
        #expect(notice == MeetingNotice(title: "转写失败", body: "周会：模型加载失败"))
    }

    @Test func actionRoundTripsThroughUserInfo() {
        let notice = MeetingNotice(title: "转写完成", body: "周会", action: .openModelDownload)
        #expect(MeetingNotice.Action(userInfo: notice.userInfo) == .openModelDownload)
        #expect(MeetingNotice(title: "转写完成", body: "周会").userInfo.isEmpty)
        #expect(MeetingNotice.Action(userInfo: [:]) == nil)
    }

    // MARK: - 纪要

    /// 只数待办节里没删除的条目，别的节不算
    @Test func minutesDoneCountsActions() {
        let notice = MeetingNotice.minutes(.done(minutes(actions: ["发报价单", "约客户", "已删的"], deleted: 1)),
                                           meetingTitle: "周会", isRecording: false)
        #expect(notice == MeetingNotice(title: "纪要已生成：2 条待办", body: "周会"))
    }

    @Test func minutesDoneWithoutActions() {
        let notice = MeetingNotice.minutes(.done(minutes(actions: [])), meetingTitle: "周会", isRecording: false)
        #expect(notice == MeetingNotice(title: "纪要已生成：没有待办", body: "周会"))
    }

    @Test func minutesFailureNotifiesWithReason() {
        let notice = MeetingNotice.minutes(.failed("模型输出无法解析"), meetingTitle: "周会", isRecording: false)
        #expect(notice == MeetingNotice(title: "纪要生成失败", body: "周会：模型输出无法解析"))
    }

    @Test(arguments: [MinutesOutcome.done(minutes(actions: ["发报价单"])), .failed("模型输出无法解析")])
    func minutesSilentWhileRecording(_ outcome: MinutesOutcome) {
        #expect(MeetingNotice.minutes(outcome, meetingTitle: "周会", isRecording: true) == nil)
    }
}

/// 一份纪要：概要一条，待办按 actions，最后 deleted 条标为已删除
private func minutes(actions: [String], deleted: Int = 0) -> Minutes {
    let ref = [MinutesRef(id: "s1", start: 0)]
    let items = actions.enumerated().map { i, text in
        MinutesItem(id: "a\(i + 1)", text: text, refs: ref, deleted: i >= actions.count - deleted)
    }
    return Minutes(model: "fake", template: "general", createdAt: Date(timeIntervalSince1970: 0),
                   source: MinutesSource(transcriptCreatedAt: Date(timeIntervalSince1970: 0), textHash: "sha256:x"),
                   sections: [
                       MinutesSection(kind: .overview, title: "概要", items: [MinutesItem(id: "o1", text: "讨论", refs: ref)]),
                       MinutesSection(kind: .decisions, title: "决议", items: []),
                       MinutesSection(kind: .actions, title: "待办", items: items),
                   ])
}
