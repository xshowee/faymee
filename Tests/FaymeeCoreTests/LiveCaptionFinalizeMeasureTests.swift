import AVFoundation
import Darwin
import Foundation
import Testing
@testable import FaymeeCore

/// 实时字幕定稿的实测（ticket 08）：一段录音按 0.1 秒一块、按实时速度送进真实的实时字幕会话
/// （X-ASR 480ms 第一遍 + 所选定稿模型），记下每句流式结果、定稿结果和各自的时刻，以及进程内存、CPU。
/// 只在手动指定录音时运行，录音和结果都不进仓库：
///
///     FAYMEE_FINALIZE_AUDIO=/path/recording.m4a FAYMEE_FINALIZE_OUT=/some/dir \
///     FAYMEE_FINALIZE_MODEL=paraformer|funasr|none [FAYMEE_FINALIZE_THREADS=4] \
///         swift test --filter LiveCaptionFinalizeMeasure
///
/// 写 `<录音所在目录名>-<模型>.json`：`{lines: [{id, start, end, stream, final, emitted, finalized}],
/// dropped, samples: [{t, footprint, cpu}]}`，时刻都是开始送音频后的秒数
private let env = ProcessInfo.processInfo.environment
private let audioURL = env["FAYMEE_FINALIZE_AUDIO"].map { URL(fileURLWithPath: $0) }
private let outputDir = env["FAYMEE_FINALIZE_OUT"].map { URL(fileURLWithPath: $0) }
private let modelName = env["FAYMEE_FINALIZE_MODEL"] ?? "none"
/// 同 ticket 07 / 评估 loops.py 的热词表
private let hotwords = ["DeerFlow", "LangChain", "Harness", "Agent", "智能体", "工具广场", "模型广场", "端到端研发"]

/// 进程的物理内存占用（同活动监视器的“内存”）
private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

/// 进程累计 CPU 秒数（用户 + 系统）
private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// 流式引擎的每句原样转给会话，同时记下文字和时刻（会话里的句子可能在下次查看前就被定稿替换了）
private final class RecordingTranscriber: StreamingTranscriber, @unchecked Sendable {
    let inner: any StreamingTranscriber
    let began: ContinuousClock.Instant
    private let lock = NSLock()
    private var _sentences: [(text: String, at: Double)] = []
    var sentences: [(text: String, at: Double)] { lock.withLock { _sentences } }

    init(_ inner: any StreamingTranscriber, began: ContinuousClock.Instant) {
        self.inner = inner
        self.began = began
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { try await inner.prepare(progress: progress) }

    func start(format: AVAudioFormat, hotwords: [String]) -> any StreamingTranscription {
        Proxy(inner.start(format: format, hotwords: hotwords), owner: self)
    }

    fileprivate func record(_ text: String) {
        let d = ContinuousClock.now - began
        let at = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        lock.withLock { _sentences.append((text, at)) }
    }

    private final class Proxy: StreamingTranscription, @unchecked Sendable {
        let inner: any StreamingTranscription
        let events: AsyncStream<StreamingTranscriptionEvent>
        init(_ inner: any StreamingTranscription, owner: RecordingTranscriber) {
            self.inner = inner
            let (events, output) = AsyncStream<StreamingTranscriptionEvent>.makeStream()
            self.events = events
            let source = inner.events
            Task {
                for await event in source {
                    if case .sentence(let s) = event { owner.record(s.text) }
                    output.yield(event)
                }
                output.finish()
            }
        }
        func append(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) { inner.append(buffer, at: time) }
        func finish() { inner.finish() }
        func cancel() { inner.cancel() }
    }
}

@MainActor
@Suite(.enabled(if: audioURL != nil && outputDir != nil, "手动实测：设 FAYMEE_FINALIZE_AUDIO 和 FAYMEE_FINALIZE_OUT"))
struct LiveCaptionFinalizeMeasureTests {
    private func finalizer() throws -> LiveCaptionFinalizerModel? {
        let id: String
        switch modelName {
        case "paraformer": id = LocalModel.paraformer.id
        case "funasr": id = LocalModel.funASRNano.id
        default: return nil
        }
        let entry = try #require(ModelCatalog.builtIn.model(id: id))
        guard let threads = env["FAYMEE_FINALIZE_THREADS"].flatMap(Int.init) else {
            return try #require(LiveCaptionFinalizerModel(selected: entry))
        }
        let loader = try #require(SegmentRecognizerLoader(model: entry))
        return LiveCaptionFinalizerModel(id: id) { words in try loader.makeRecognizer(hotwords: words, threads: threads) }
    }

    @Test func 实时送一段录音_记下定稿() async throws {
        let url = try #require(audioURL), output = try #require(outputDir)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let t0 = Date()
        let clock = ContinuousClock()
        let began = clock.now
        let engine = RecordingTranscriber(SherpaStreamingTranscriber(model: .xASR480), began: began)
        let session = LiveCaptionSession(engine: engine, recordingStartedAt: t0,
                                         hotwords: hotwords, finalizer: try finalizer())
        for _ in 0..<100 where session.status != .running { try await Task.sleep(for: .milliseconds(50)) }
        try #require(session.status == .running)

        struct Line { var start, end: Double; var stream: String; var final: String?; var emitted: Double; var finalized: Double? }
        var lines: [Int: Line] = [:]
        var samples: [[String: Double]] = []
        func elapsed() -> Double {
            let d = clock.now - began
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        func observe() {
            let now = elapsed()
            // 不暂停时句子 id 从 1 起逐句加一，id 为 k 的就是引擎发的第 k 句（会话只留最近 200 句，不能按位置对）
            let streamed = engine.sentences
            for line in session.lines {
                guard case .sentence(let s) = line, s.id - 1 < streamed.count else { continue }
                let k = s.id - 1
                if lines[s.id] == nil {
                    lines[s.id] = Line(start: s.start, end: s.end, stream: streamed[k].text, final: nil,
                                       emitted: streamed[k].at, finalized: nil)
                }
                // 定稿时刻记第一次被替换；文字记最后的（后一句定稿时可能去掉末尾重复的字）
                if var l = lines[s.id], s.text != (l.final ?? l.stream) {
                    l.final = s.text
                    if l.finalized == nil { l.finalized = now }
                    lines[s.id] = l
                }
            }
        }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        var index = 0
        let cpuStart = cpuSeconds()
        while file.framePosition < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk))
            let position = Double(file.framePosition) / format.sampleRate
            try file.read(into: buffer, frameCount: chunk)
            session.append(buffer, at: t0.addingTimeInterval(position))
            observe()
            if index % 10 == 0 {
                samples.append(["t": elapsed(), "footprint": Double(footprint()), "cpu": cpuSeconds() - cpuStart])
            }
            index += 1
            let next = began + .milliseconds(100 * index)
            while clock.now + .milliseconds(20) < next {
                try await clock.sleep(for: .milliseconds(20))
                observe()
            }
            try await clock.sleep(until: next)
        }
        // 送完后等最后几句定稿
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(100))
            observe()
        }
        let dropped = session.finalizeDropped
        session.stop()

        let rows = lines.sorted { $0.key < $1.key }.map { id, l -> [String: Any] in
            var row: [String: Any] = ["id": id, "start": l.start, "end": l.end, "stream": l.stream, "emitted": l.emitted]
            if let f = l.final { row["final"] = f }
            if let f = l.finalized { row["finalized"] = f }
            return row
        }
        let result: [String: Any] = ["model": modelName, "threads": env["FAYMEE_FINALIZE_THREADS"] ?? "default",
                                     "audioSeconds": Double(file.length) / format.sampleRate,
                                     "dropped": dropped, "lines": rows, "samples": samples]
        let name = url.deletingLastPathComponent().lastPathComponent
        let suffix = env["FAYMEE_FINALIZE_THREADS"].map { "-t\($0)" } ?? ""
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("\(name)-\(modelName)\(suffix).json"))
    }
}
