import AVFoundation
import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-11T02:00:00Z", strategy: .iso8601)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// 16 kHz 单声道：转成定稿用的样本时原样不变，测试能按样本值认出切了哪段
private let mono16k = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!

/// 0.1 秒一块，样本值都是 value
private func chunk(_ value: Float) -> AVAudioPCMBuffer {
    let b = AVAudioPCMBuffer(pcmFormat: mono16k, frameCapacity: 1600)!
    b.frameLength = 1600
    for i in 0..<1600 { b.floatChannelData![0][i] = value }
    return b
}

/// 假的定稿模型：记下每次收到的音频，返回“首块号-末块号”（样本值就是块号）。
/// blocks 时每次识别都等测试 `release` 一次
final class FakeFinalizeRecognizer: SegmentRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var _clips: [[Float]] = []
    private let gate = DispatchSemaphore(value: 0)
    let blocks: Bool
    /// 按收到的音频给出文字；nil 时给“首块号-末块号”
    var text: (@Sendable ([Float]) -> String)?

    init(blocks: Bool = false) { self.blocks = blocks }

    var clips: [[Float]] { lock.withLock { _clips } }

    func release(_ count: Int = 1) { for _ in 0..<count { gate.signal() } }

    func recognize(_ samples: ArraySlice<Float>) throws -> SegmentRecognition {
        let clip = Array(samples)
        lock.withLock { _clips.append(clip) }
        if blocks { gate.wait() }
        let text = text?(clip) ?? "\(Int(clip.first ?? -1))-\(Int(clip.last ?? -1))"
        return SegmentRecognition(text: text, tokens: nil)
    }
}

/// 定稿器释放时（会话不再持有它）记一笔
private final class Released: SegmentRecognizer, @unchecked Sendable {
    let inner: FakeFinalizeRecognizer
    let onDeinit: @Sendable () -> Void
    init(_ inner: FakeFinalizeRecognizer, onDeinit: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.onDeinit = onDeinit
    }
    deinit { onDeinit() }
    func recognize(_ samples: ArraySlice<Float>) throws -> SegmentRecognition { try inner.recognize(samples) }
}

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var _loads: [[String]] = []
    private var _released = 0
    var loads: [[String]] { lock.withLock { _loads } }
    var released: Int { lock.withLock { _released } }
    func load(_ hotwords: [String]) { lock.withLock { _loads.append(hotwords) } }
    func release() { lock.withLock { _released += 1 } }
}

@MainActor
private final class Fixture {
    let engine = FakeStreamingTranscriber()
    let recognizer: FakeFinalizeRecognizer
    let session: LiveCaptionSession
    let log = Log()
    private var chunks = 0
    private let clock = Clock()

    final class Clock: @unchecked Sendable {
        var now = t0
    }

    init(blocks: Bool = false, hotwords: [String] = []) {
        let recognizer = FakeFinalizeRecognizer(blocks: blocks)
        self.recognizer = recognizer
        let log = log
        let finalizer = LiveCaptionFinalizerModel(id: "fake") { hotwords in
            log.load(hotwords)
            return Released(recognizer) { log.release() }
        }
        let clock = clock
        session = LiveCaptionSession(engine: engine, recordingStartedAt: t0, hotwords: hotwords,
                                     finalizer: finalizer, now: { clock.now })
    }

    func advance(to seconds: TimeInterval) { clock.now = at(seconds) }

    var sentences: [String] { session.lines.compactMap { if case .sentence(let s) = $0 { s.text } else { nil } } }

    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    /// 等准备好，送入 seconds 秒音频（0.1 秒一块，第 i 块在录音里第 i×0.1 秒、样本值为 i），返回开始的转写
    @discardableResult
    func run(seconds: TimeInterval) async throws -> FakeTranscription {
        try await until { session.status == .running }
        feed(seconds: seconds)
        return engine.last
    }

    /// 接着送 seconds 秒音频
    func feed(seconds: TimeInterval) {
        for _ in 0..<Int((seconds * 10).rounded()) {
            session.append(chunk(Float(chunks)), at: at(Double(chunks) / 10))
            chunks += 1
        }
    }

    /// 从录音里 start 秒起送 seconds 秒音频，样本值从 value 起逐块加一
    func feed(seconds: TimeInterval, from start: TimeInterval, value: Int) {
        for k in 0..<Int((seconds * 10).rounded()) {
            session.append(chunk(Float(value + k)), at: at(start + Double(k) / 10))
        }
    }
}

@MainActor @Suite struct LiveCaptionFinalizeTests {
    /// 句子前后各多 0.3 秒的音频交给定稿模型，结果替换这一句
    @Test func 句子的音频前后各多0点3秒重转_结果替换这一句() async throws {
        let f = Fixture()
        let t = try await f.run(seconds: 5)

        t.sentence(1, 2, "流式结果。")
        try await f.until { f.sentences == ["7-22"] }
        #expect(f.recognizer.clips.count == 1)
        #expect(f.recognizer.clips[0].count == 16 * 1600)
    }

    @Test func 定稿模型在会话开始时加载一次_带上热词表() async throws {
        let f = Fixture(hotwords: ["支付模块", "DeerFlow"])
        try await f.until { f.log.loads.count == 1 }
        #expect(f.log.loads == [["支付模块", "DeerFlow"]])
    }

    /// 定稿跟不上时：手上这句照常定稿，排队的超过 5 句丢最旧的，那句保留流式结果
    @Test func 积压超过5句时丢最旧的请求_那句保留流式结果() async throws {
        let f = Fixture(blocks: true)
        let t = try await f.run(seconds: 30)

        t.sentence(1, 2, "一。")
        try await f.until { f.recognizer.clips.count == 1 }
        for i in 2...7 { t.sentence(Double(i * 2), Double(i * 2 + 1), "\(i)。") }
        try await f.until { f.sentences.count == 7 }
        f.recognizer.release(7)

        try await f.until { f.recognizer.clips.count == 6 }
        try await f.until { f.sentences.last == "137-152" }
        #expect(f.sentences == ["7-22", "2。", "57-72", "77-92", "97-112", "117-132", "137-152"])
    }

    /// 结果按句子 id 替换：期间来了新句子、插了分隔行，晚到的结果也只换它那一句
    @Test func 晚到的结果只替换对应的那一句() async throws {
        let f = Fixture(blocks: true)
        let t = try await f.run(seconds: 5)

        t.sentence(1, 2, "第一句。")
        try await f.until { f.recognizer.clips.count == 1 }
        t.sentence(3, 4, "第二句。")
        try await f.until { f.sentences.count == 2 }
        f.advance(to: 10)
        f.session.pause()
        f.advance(to: 20)
        f.session.resume()

        f.recognizer.release()
        try await f.until { f.sentences.first == "7-22" }
        // 第二句排着队时暂停了：请求丢掉，保留流式结果
        #expect(f.sentences == ["7-22", "第二句。"])
        #expect(f.session.lines.count == 3)
        if case .gap = f.session.lines[2] {} else { Issue.record("分隔行不该被替换") }
    }

    /// 超过 10 秒的句子在安静处切成 ≤ 10 秒的几段分别识别，再接起来
    @Test func 超过10秒的句子切成几段识别再接起来() async throws {
        let f = Fixture()
        let t = try await f.run(seconds: 20)
        f.recognizer.text = { clip in "\(clip.count)个样本。" }

        t.sentence(1, 15, "很长的一句。")
        try await f.until { f.sentences.count == 1 && f.sentences != ["很长的一句。"] }

        let counts = f.recognizer.clips.map(\.count)
        try #require(counts.count == 2)
        #expect(counts.allSatisfy { $0 <= 160_000 })
        #expect(counts.reduce(0, +) == 146 * 1600)
        #expect(f.sentences == ["\(counts[0])个样本。\(counts[1])个样本。"])
    }

    /// 句子时间和流式引擎一样换算：中途丢过一段音频（分路缓冲满等）也切得准
    @Test func 中途丢过音频时按录音里的时间切() async throws {
        let f = Fixture()
        let t = try await f.run(seconds: 5)
        // 5–15 秒的音频丢了，之后的块按收到的时刻接着送
        f.feed(seconds: 5, from: 15, value: 100)

        t.sentence(16, 17, "丢音频之后的一句。")
        try await f.until { f.sentences == ["107-122"] }
    }

    /// 前后两句紧挨着时，各多带的 0.3 秒会让前一句的定稿带上后一句开头的字（真实会议里 X-ASR 的句子常常首尾相接）：
    /// 后一句定稿时，从前一句去掉和它开头相同的字（最多 4 个，同会后转写）
    @Test func 紧挨着的两句_前一句定稿末尾重复后一句开头的字时去掉() async throws {
        let f = Fixture()
        let t = try await f.run(seconds: 10)
        f.recognizer.text = { clip in
            switch Int(clip.first ?? 0) {
            case 7: "大家好，今天开会，所以。"
            case 18: "所以先说预算。"
            default: "后来的。"
            }
        }

        t.sentence(1, 2.1, "大家好今天开会。")
        t.sentence(2.1, 3, "所以先说预算。")
        // 隔开 0.6 秒以上：两句的音频不重叠，不动
        t.sentence(4, 5, "后来的。")
        try await f.until { f.sentences.last == "后来的。" && f.sentences.first == "大家好，今天开会。" }
        #expect(f.sentences == ["大家好，今天开会。", "所以先说预算。", "后来的。"])
    }

    /// 两句的音频重叠可达约 1 秒，重复的字比会后转写的多（实测 5、6 个字）
    @Test func 重复6个字也去掉() async throws {
        let f = Fixture()
        let t = try await f.run(seconds: 10)
        f.recognizer.text = { clip in Int(clip.first ?? 0) == 7 ? "你知道吗，我们现在都没。" : "我们现在都没有给他。" }

        t.sentence(1, 2.1, "你知道吗。")
        t.sentence(2.1, 3, "我们现在都没有给他。")
        try await f.until { f.sentences == ["你知道吗。", "我们现在都没有给他。"] }
    }

    @Test func 前一句没有定稿时不去掉重复的字() async throws {
        let f = Fixture()
        let t = try await f.run(seconds: 10)
        f.recognizer.text = { clip in Int(clip.first ?? 0) == 7 ? "" : "所以先说预算。" }

        t.sentence(1, 2.1, "大家好所以。")
        t.sentence(2.1, 3, "所以先说预算。")
        try await f.until { f.recognizer.clips.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.sentences == ["大家好所以。", "所以先说预算。"])
    }

    /// 开始（或恢复）后的第一句：往前补的 0.3 秒还没有音频，从有音频的地方切，照常定稿
    @Test func 第一句往前补边没有音频时从头切() async throws {
        let f = Fixture()
        let t = try await f.run(seconds: 5)

        t.sentence(0.1, 1, "第一句。")
        try await f.until { f.sentences == ["0-12"] }
    }

    /// 只留最近约 1 分钟的音频：句子开头已经不在了就不定稿
    @Test func 句子的音频已经不在缓存里时保留流式结果() async throws {
        let f = Fixture()
        let t = try await f.run(seconds: 80)

        t.sentence(2, 3, "很早的一句。")
        t.sentence(75, 76, "刚说的一句。")
        try await f.until { f.sentences.last == "747-762" }
        #expect(f.sentences == ["很早的一句。", "747-762"])
        #expect(f.recognizer.clips.count == 1)
    }

    @Test func 定稿结果为空时保留流式结果() async throws {
        let f = Fixture()
        let t = try await f.run(seconds: 5)
        f.recognizer.text = { _ in "" }

        t.sentence(1, 2, "嗯。")
        t.sentence(3, 4, "好的。")
        try await f.until { f.recognizer.clips.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.sentences == ["嗯。", "好的。"])
    }

    /// 暂停期间定稿模型留着（不反复加载），恢复后的句子照常定稿；暂停前缓存的音频不用
    @Test func 暂停后定稿模型留着_恢复后照常定稿() async throws {
        let f = Fixture()
        let t = try await f.run(seconds: 5)
        f.session.pause()
        f.session.resume()
        t.end()

        f.feed(seconds: 5)
        let t2 = f.engine.last
        #expect(t2 !== t)
        t2.sentence(1, 2, "暂停前的一句。")
        t2.sentence(6, 7, "恢复后的一句。")
        try await f.until { f.sentences.last == "57-72" }
        #expect(f.sentences == ["暂停前的一句。", "57-72"])
        #expect(f.log.loads.count == 1)
    }

    /// 录音结束：手上这句识别完就释放定稿模型，结果不再替换
    @Test func 录音结束时释放定稿模型() async throws {
        let f = Fixture(blocks: true)
        let t = try await f.run(seconds: 5)
        t.sentence(1, 2, "第一句。")
        try await f.until { f.recognizer.clips.count == 1 }
        t.sentence(3, 4, "第二句。")
        try await f.until { f.sentences.count == 2 }

        f.session.stop()
        #expect(f.log.released == 0)
        f.recognizer.release()
        try await f.until { f.log.released == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.sentences == ["第一句。", "第二句。"])
        #expect(f.recognizer.clips.count == 1)
    }
}
