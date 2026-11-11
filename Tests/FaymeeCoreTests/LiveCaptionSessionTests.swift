import AVFoundation
import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-11T02:00:00Z", strategy: .iso8601)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private let mic = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
private let usbMic = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

private func buffer(_ format: AVAudioFormat = mic) -> AVAudioPCMBuffer {
    let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    b.frameLength = 4800
    return b
}

private struct EngineError: LocalizedError {
    var errorDescription: String? { "本机无法使用系统语音识别" }
}

@MainActor
private final class Fixture {
    let engine = FakeStreamingTranscriber()
    let session: LiveCaptionSession
    private let clock = Clock()

    final class Clock: @unchecked Sendable {
        var now = t0
    }

    init(hotwords: [String] = [], prepareErrors: [Error] = [], blocksPrepare: Bool = false,
         prepareProgress: Double? = nil) {
        engine.prepareErrors = prepareErrors
        engine.blocksPrepare = blocksPrepare
        engine.prepareProgress = prepareProgress
        let clock = clock
        session = LiveCaptionSession(engine: engine, recordingStartedAt: t0, hotwords: hotwords, now: { clock.now })
    }

    var sentences: [String] { session.lines.compactMap { if case .sentence(let s) = $0 { s.text } else { nil } } }

    func pause(at seconds: TimeInterval) {
        clock.now = at(seconds)
        session.pause()
    }

    func resume(at seconds: TimeInterval) {
        clock.now = at(seconds)
        session.resume()
    }

    func advance(to seconds: TimeInterval) { clock.now = at(seconds) }

    func retry(at seconds: TimeInterval) {
        clock.now = at(seconds)
        session.retry()
    }

    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    /// 等准备好，在墙钟 seconds 秒送入第一块音频，返回开始的转写
    @discardableResult
    func run(at seconds: TimeInterval = 0, format: AVAudioFormat = mic) async throws -> FakeTranscription {
        try await until { session.status == .running }
        let count = engine.sessions.count
        session.append(buffer(format), at: at(seconds))
        try #require(engine.sessions.count == count + 1)
        return engine.last
    }
}

@MainActor @Suite struct LiveCaptionSessionTests {
    @Test func 临时文字被定稿句子替换() async throws {
        let f = Fixture()
        let t = try await f.run()

        t.volatile("今天我们", 1)
        try await f.until { f.session.volatile?.text == "今天我们" }
        #expect(f.session.lines.isEmpty)

        t.sentence(1, 3, "今天我们讨论预算。")
        try await f.until { !f.session.lines.isEmpty }
        #expect(f.sentences == ["今天我们讨论预算。"])
        #expect(f.session.volatile == nil)
    }

    @Test func 字幕时间以录音开始为零点_按收到音频的时刻换算() async throws {
        let f = Fixture()
        let t = try await f.run(at: 65)

        t.volatile("好", 2)
        t.sentence(2, 4.5, "好的。")
        try await f.until { !f.session.lines.isEmpty }

        #expect(f.session.lines == [.sentence(LiveCaption(id: f.session.lines[0].id, start: 67, end: 69.5, text: "好的。"))])
    }

    @Test func 暂停再恢复插入分隔行和大约的分钟数() async throws {
        let f = Fixture()
        let before = try await f.run(at: 60)
        before.sentence(2, 5, "合盖前。")
        before.volatile("还没说完", 6)
        try await f.until { f.session.volatile != nil }

        f.pause(at: 120)
        #expect(before.cancelled)
        #expect(f.session.status == .paused)
        #expect(f.session.volatile == nil)
        // 暂停时不跑引擎，送来的音频也不要
        f.session.append(buffer(), at: at(130))
        #expect(f.engine.sessions.count == 1)
        // 已取消的转写迟到的事件丢掉
        before.sentence(6, 8, "迟到的一句。")
        before.end()

        f.resume(at: 120 + 7 * 60 + 20)
        let after = try await f.run(at: 561)
        after.sentence(1, 3, "开盖后。")
        try await f.until { f.sentences.count == 2 }

        #expect(f.sentences == ["合盖前。", "开盖后。"])
        guard f.session.lines.count == 3, case .gap(let gap) = f.session.lines[1] else {
            Issue.record("没有分隔行：\(f.session.lines)")
            return
        }
        #expect(gap.start == 120)
        #expect(gap.minutes == 7)
        #expect(gap.text == "中间约 7 分钟没有字幕")
        // 新的转写从 0 计时，按恢复后第一块音频重新换算，不回到录音开头
        guard case .sentence(let last) = f.session.lines[2] else { return }
        #expect(last.start == 562)
    }

    /// 恢复后没出字幕又停了（如开盖片刻又合上），合成一行，从第一次暂停算到最后一次恢复
    @Test func 两次暂停之间没有字幕时分隔行合并成一行() async throws {
        let f = Fixture()
        let t = try await f.run(at: 0)
        t.sentence(0, 2, "第一句。")
        try await f.until { !f.session.lines.isEmpty }

        f.pause(at: 10)
        f.resume(at: 70)
        f.pause(at: 80)
        f.resume(at: 200)

        #expect(f.session.lines.count == 2)
        guard case .gap(let gap) = f.session.lines.last else { return }
        #expect(gap.start == 10)
        #expect(gap.duration == 190)
        #expect(gap.text == "中间约 3 分钟没有字幕")
    }

    @Test func 停了不到半分钟显示不到1分钟() async throws {
        let f = Fixture()
        try await f.run(at: 0)

        f.pause(at: 10)
        f.resume(at: 35)

        guard case .gap(let gap) = f.session.lines.last else {
            Issue.record("没有分隔行")
            return
        }
        #expect(gap.text == "中间不到 1 分钟没有字幕")
    }

    @Test func 超过200句丢掉最旧的_顶上剩下的分隔行一并丢掉() async throws {
        let f = Fixture()
        let first = try await f.run(at: 0)
        for i in 1...3 { first.sentence(Double(i), Double(i) + 0.5, "第\(i)句") }
        try await f.until { f.sentences.count == 3 }
        f.pause(at: 10)
        f.resume(at: 100)

        let second = try await f.run(at: 100)
        for i in 4...203 { second.sentence(Double(i), Double(i) + 0.5, "第\(i)句") }
        try await f.until { f.sentences.last == "第203句" }

        #expect(f.sentences.count == 200)
        #expect(f.sentences.first == "第4句")
        #expect(f.session.lines.count == 200)
        // 编号不因丢弃而变，界面据此保持滚动位置
        #expect(Set(f.session.lines.map(\.id)).count == 200)
    }

    @Test func 出错后进入出错状态_重试后恢复() async throws {
        let f = Fixture()
        let first = try await f.run(at: 0)
        first.sentence(0, 2, "出错前。")
        try await f.until { !f.session.lines.isEmpty }

        first.fail("语音识别权限被关闭")
        // 自动重试一次：重新准备，下一块音频开新的转写
        try await f.until { f.engine.prepareCalls == 2 }
        let second = try await f.run(at: 5)
        f.advance(to: 6)
        second.fail("语音识别权限被关闭")
        try await f.until { f.session.status == .failed("语音识别权限被关闭") }
        f.session.append(buffer(), at: at(8))
        #expect(f.engine.sessions.count == 2)
        // 出错不清字幕
        #expect(f.sentences == ["出错前。"])

        f.retry(at: 190)
        let third = try await f.run(at: 190)
        third.sentence(0, 2, "重试后。")
        try await f.until { f.sentences.count == 2 }
        #expect(f.session.status == .running)
        #expect(f.sentences == ["出错前。", "重试后。"])
        // 出错到重试之间没有字幕，同样插分隔行
        guard f.session.lines.count == 3, case .gap(let gap) = f.session.lines[1],
              case .sentence(let last) = f.session.lines[2] else {
            Issue.record("\(f.session.lines)")
            return
        }
        #expect(gap.start == 6)
        #expect(gap.minutes == 3)
        #expect(last.start == 190)
    }

    @Test func 偶发出错自动重试一次_不显示出错() async throws {
        let f = Fixture()
        let first = try await f.run(at: 0)
        first.fail("识别中断")
        try await f.until { f.engine.prepareCalls == 2 }
        let second = try await f.run(at: 5)
        // 重试后正常出过字，再出错时又能自动重试一次
        second.sentence(0, 1, "恢复了。")
        try await f.until { !f.session.lines.isEmpty }
        second.fail("识别中断")
        try await f.until { f.engine.prepareCalls == 3 }
        try await f.run(at: 9)

        #expect(f.engine.prepareCalls == 3)
        #expect(f.session.status == .running)
    }

    @Test func 准备资源失败两次进入出错状态() async throws {
        let f = Fixture(prepareErrors: [EngineError(), EngineError()])

        try await f.until { f.session.status == .failed("本机无法使用系统语音识别") }
        #expect(f.engine.prepareCalls == 2)
    }

    @Test func 准备资源时显示进度_期间的音频不送给引擎() async throws {
        let f = Fixture(blocksPrepare: true, prepareProgress: 0.4)
        try await f.until { f.session.status == .preparing(0.4) }

        f.session.append(buffer(), at: at(1))
        #expect(f.engine.sessions.isEmpty)

        f.engine.prepareGate?.resume()
        try await f.run(at: 30)
    }

    @Test func 准备期间被暂停_准备好后仍是暂停() async throws {
        let f = Fixture(blocksPrepare: true)
        try await f.until { f.engine.prepareGate != nil }

        f.pause(at: 5)
        f.engine.prepareGate?.resume()
        try await f.until { f.session.status == .paused }

        f.resume(at: 65)
        try await f.run(at: 65)
        // 字幕还没出过，也照样插分隔行
        guard case .gap(let gap) = f.session.lines.first else {
            Issue.record("没有分隔行")
            return
        }
        #expect(gap.minutes == 1)
    }

    @Test func 换音频格式时开新的转写_字幕连续不插分隔行() async throws {
        let f = Fixture(hotwords: ["飞书"])
        let builtIn = try await f.run(at: 0)
        builtIn.sentence(1, 3, "内置麦克风。")
        try await f.until { f.sentences.count == 1 }
        f.session.append(buffer(), at: at(1))
        #expect(builtIn.appended == 2)

        // 插上 USB 麦克风：新格式的第一块音频到来
        let usb = try await f.run(at: 30, format: usbMic)
        #expect(builtIn.finished)
        #expect(!builtIn.cancelled)
        #expect(usb.format == usbMic)
        #expect(usb.hotwords == ["飞书"])
        #expect(usb.appended == 1)
        // 旧的转写收尾吐出的定稿句子照常显示
        builtIn.sentence(20, 22, "拔线前最后一句。")
        builtIn.end()
        try await f.until { f.sentences.count == 2 }
        usb.sentence(1, 2, "外接麦克风。")
        try await f.until { f.sentences.count == 3 }

        #expect(f.sentences == ["内置麦克风。", "拔线前最后一句。", "外接麦克风。"])
        #expect(f.session.lines.allSatisfy { if case .sentence = $0 { true } else { false } })
        guard case .sentence(let last) = f.session.lines.last else { return }
        #expect(last.start == 31)
    }

    @Test func 收尾中的旧转写在暂停时一并取消() async throws {
        let f = Fixture()
        let builtIn = try await f.run(at: 0)
        try await f.run(at: 30, format: usbMic)

        f.pause(at: 40)

        #expect(builtIn.cancelled)
        #expect(f.engine.sessions.allSatisfy { $0.cancelled })
    }

    @Test func 录音结束后不再开始转写() async throws {
        let f = Fixture()
        let t = try await f.run(at: 0)

        f.session.stop()
        f.session.append(buffer(), at: at(1))
        f.resume(at: 2)

        #expect(t.cancelled)
        #expect(f.engine.sessions.count == 1)
    }
}
