import AVFoundation
import CryptoKit
import Foundation
import SherpaOnnxC

/// 区分说话人引擎：sherpa-onnx 2.0.1 的离线区分说话人（pyannote segmentation-3.0 分段 + 3D-Speaker CAM++
/// 中文声纹，complete-linkage 层次聚类），纯 CPU，模型从 `modelDirectory` 读。
///
/// sherpa-onnx 的 C API 有几处限制，这里的兜法：
/// - **不能中途取消**（进度回调的返回值被忽略）。取消时等这次调用跑完再抛 `CancellationError`，
///   不提前返回：提前返回的话管线会马上开始下一个任务，两份都在跑、内存翻倍。解码和算声纹是自己的循环，可以随时停
/// - **坏模型会 `_Exit` 整个进程**：`prepare` 先校验两个模型文件的 sha256，对不上就抛错，不交给 sherpa-onnx
/// - **结果不带声纹**：区分完后用同一个声纹模型给每个说话人另算（见 `voiceprints`）
/// - **进度只覆盖声纹阶段**：分段阶段没有回调，按录音时长估算的耗时推进
/// - 内存随录音长度线性增长（1 小时约 2.5GB），不分块，见 ticket 05 的说明
public final class SherpaOnnxDiarizer: SpeakerDiarizer, @unchecked Sendable {
    public struct ModelFile: Sendable, Equatable {
        public let name: String
        /// 字节数
        public let size: Int64
        /// 小写 hex
        public let sha256: String
    }

    /// 文件名、大小、sha256 与 scripts/fetch-diarization-models.sh 保持一致
    public static let segmentationModel = ModelFile(
        name: "pyannote-segmentation-3-0.onnx", size: 5_992_913,
        sha256: "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079")
    public static let embeddingModel = ModelFile(
        name: "3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx", size: 28_281_138,
        sha256: "f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11")
    public static let models = [segmentationModel, embeddingModel]

    /// 自动判断人数时的聚类阈值（余弦距离，越大判出的人越少）。sherpa-onnx 默认 0.5 在 TTS 样例上把 2 人分成 3 人；
    /// 0.7 在 TTS 两人样例和 sherpa-onnx 的真人四人样例上都判对，0.8 起四人样例只剩 3 人。待真实会议校准
    public static let clusteringThreshold: Float = 0.7
    /// 声纹库匹配的推荐阈值（余弦相似度），App 传给 `TranscriptionPipeline.voiceprintThreshold`。sherpa-onnx 的真人测试录音（3 人、单句 2–8 秒）同人最低 0.68、
    /// 异人最高 0.44，取中间。整场平均的声纹比单句稳定，同人分数通常更高。待真实会议校准
    public static let recommendedMatchThreshold: Float = 0.55

    /// 文件都在且大小对。不算哈希（`prepare` 才算），App 用它决定有没有可用的引擎
    public static func modelsPresent(in directory: URL) -> Bool {
        models.allSatisfy { m in
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(m.name).path)
            return (attributes?[.size] as? NSNumber)?.int64Value == m.size
        }
    }

    public let engine = "sherpa-onnx-2.0.1/pyannote-segmentation-3.0"
    public let voiceprintModel = "3dspeaker-campplus-zh-cn-16k-common"

    private let directory: URL
    private let threads: Int32
    private let lock = NSLock()
    private var verified = false
    /// 串行：同一时刻只跑一次区分（每次要占 CPU 和与录音时长成正比的内存）
    private let queue = DispatchQueue(label: "com.faymee.sherpa-diarizer", qos: .utility)

    public init(modelDirectory: URL, threads: Int = 4) {
        directory = modelDirectory
        self.threads = Int32(threads)
    }

    /// 校验模型文件（存在、大小、sha256），通过一次后不再算
    public func prepare(progress: @escaping (Double) -> Void) async throws {
        if lock.withLock({ verified }) { return progress(1) }
        let directory = directory
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                c.resume(with: Result { try Self.models.forEach { try Self.verify($0, in: directory) } })
            }
        }
        lock.withLock { verified = true }
        progress(1)
    }

    public func diarize(audio: URL, speakerCount: Int?,
                        progress: @escaping (Double) -> Void) async throws -> DiarizationResult {
        try await prepare { _ in }
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                queue.async {
                    c.resume(with: Result {
                        try self.run(audio: audio, speakerCount: speakerCount, flag: flag,
                                     progress: Progress(progress))
                    })
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    // MARK: - 区分

    private static let sampleRate = 16000
    // 进度分配：解码 0–5%，分段（估算）5–30%，聚类前的声纹（sherpa 回调）30–90%，每人声纹 90–100%
    private static let decodeShare = 0.05, segmentationEnd = 0.3, clusteringEnd = 0.9
    /// 分段阶段每秒录音的预估耗时（M3 Pro 4 线程实测 10 分钟 0.017、1 小时 0.022）
    private static let segmentationSecondsPerSecond = 0.022

    private func run(audio: URL, speakerCount: Int?, flag: CancelFlag,
                     progress: Progress) throws -> DiarizationResult {
        try flag.check()
        let samples = try Self.decode(audio, flag: flag) { progress.report($0 * Self.decodeShare) }
        try flag.check()
        guard !samples.isEmpty else {
            progress.report(1)
            return DiarizationResult(segments: [], voiceprints: [:])
        }
        let segments = try segment(samples, speakerCount: speakerCount, progress: progress)
        // 跑完了才知道被取消过：结果作废
        try flag.check()
        let voiceprints = try self.voiceprints(for: segments, samples: samples, flag: flag) {
            progress.report(Self.clusteringEnd + $0 * (1 - Self.clusteringEnd))
        }
        progress.report(1)
        return DiarizationResult(segments: segments, voiceprints: voiceprints)
    }

    private func segment(_ samples: [Float], speakerCount: Int?, progress: Progress) throws -> [SpeakerSegment] {
        let segModel = strdup(directory.appendingPathComponent(Self.segmentationModel.name).path)
        let embModel = strdup(directory.appendingPathComponent(Self.embeddingModel.name).path)
        let cpu = strdup("cpu")
        defer { free(segModel); free(embModel); free(cpu) }

        var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
        config.segmentation.pyannote.model = UnsafePointer(segModel)
        config.segmentation.num_threads = threads
        config.segmentation.provider = UnsafePointer(cpu)
        config.embedding.model = UnsafePointer(embModel)
        config.embedding.num_threads = threads
        config.embedding.provider = UnsafePointer(cpu)
        config.clustering.num_clusters = Int32(clamping: speakerCount ?? 0)
        config.clustering.threshold = Self.clusteringThreshold
        config.min_duration_on = 0.3
        config.min_duration_off = 0.5
        // 每次新建：释放时连同按录音长度分配的内存一起还掉。加载两个模型只要零点几秒
        guard let sd = SherpaOnnxCreateOfflineSpeakerDiarization(&config) else {
            throw SherpaOnnxDiarizerError.engineUnavailable
        }
        defer { SherpaOnnxDestroyOfflineSpeakerDiarization(sd) }

        // 分段阶段没有回调：按预估耗时推进到 segmentationEnd 之前，第一次回调后由回调接手（进度只增不减）
        let duration = Double(samples.count) / Double(Self.sampleRate)
        let expected = max(1, duration * Self.segmentationSecondsPerSecond)
        let started = Date()
        let ticker = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        ticker.schedule(deadline: .now() + 0.5, repeating: 0.5)
        ticker.setEventHandler {
            let fraction = min(0.95, Date().timeIntervalSince(started) / expected)
            progress.report(Self.decodeShare + fraction * (Self.segmentationEnd - Self.decodeShare))
        }
        ticker.resume()
        defer { ticker.cancel() }

        let context = Unmanaged.passUnretained(progress).toOpaque()
        let callback: SherpaOnnxOfflineSpeakerDiarizationProgressCallback = { done, total, arg in
            guard let arg, total > 0 else { return 0 }
            let progress = Unmanaged<Progress>.fromOpaque(arg).takeUnretainedValue()
            progress.report(SherpaOnnxDiarizer.segmentationEnd
                + Double(done) / Double(total) * (SherpaOnnxDiarizer.clusteringEnd - SherpaOnnxDiarizer.segmentationEnd))
            return 0
        }
        return try Self.segments(of: samples.withUnsafeBufferPointer {
            SherpaOnnxOfflineSpeakerDiarizationProcessWithCallback(sd, $0.baseAddress, Int32($0.count), callback, context)
        })
    }

    /// 把 sherpa-onnx 的区分结果转成按开始时间排序的说话片段，并释放结果。
    /// 结果为 NULL（处理失败）时抛错，不当成“没有说话人”：空结果会覆盖原来的说话人和名字。
    /// 有结果但 0 个片段（全程静音）是正常的空结果
    static func segments(of result: OpaquePointer?) throws -> [SpeakerSegment] {
        guard let result else { throw SherpaOnnxDiarizerError.processingFailed }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }

        let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        guard count > 0 else { return [] }
        guard let sorted = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else {
            throw SherpaOnnxDiarizerError.processingFailed
        }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(sorted) }
        return (0..<count).map {
            SpeakerSegment(start: TimeInterval(sorted[$0].start), end: TimeInterval(sorted[$0].end),
                           speaker: Int(sorted[$0].speaker))
        }
    }

    // MARK: - 声纹

    /// 每个说话人最多用这么多秒的片段算声纹（挑最长的），1 小时会议也只要几秒
    private static let voiceprintBudget: TimeInterval = 300
    /// 短于此的片段不单独算声纹（太短的声纹不稳），除非这个人只有这么短的片段
    private static let minimumVoiceprintSegment: TimeInterval = 1

    /// 每个说话人的声纹：挑他最长的若干片段各算一次，单位化后按片段时长加权平均。
    /// 一个片段都算不出来（全都太短）的人没有声纹
    private func voiceprints(for segments: [SpeakerSegment], samples: [Float], flag: CancelFlag,
                             progress: (Double) -> Void) throws -> [Int: Voiceprint] {
        guard !segments.isEmpty else { return [:] }
        let model = strdup(directory.appendingPathComponent(Self.embeddingModel.name).path)
        let cpu = strdup("cpu")
        defer { free(model); free(cpu) }
        var config = SherpaOnnxSpeakerEmbeddingExtractorConfig()
        config.model = UnsafePointer(model)
        config.num_threads = threads
        config.provider = UnsafePointer(cpu)
        guard let extractor = SherpaOnnxCreateSpeakerEmbeddingExtractor(&config) else {
            throw SherpaOnnxDiarizerError.engineUnavailable
        }
        defer { SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor) }
        let dim = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))

        let bySpeaker = Dictionary(grouping: segments, by: \.speaker)
        let chosen = bySpeaker.mapValues(Self.voiceprintSegments)
        let total = max(1, chosen.values.reduce(0) { $0 + $1.count })
        var done = 0
        var out: [Int: Voiceprint] = [:]
        for (speaker, pieces) in chosen {
            var sum = [Float](repeating: 0, count: dim)
            var weight: Float = 0
            for piece in pieces {
                try flag.check()
                let lo = max(0, Int(piece.start * Double(Self.sampleRate)))
                let hi = min(samples.count, Int(piece.end * Double(Self.sampleRate)))
                if hi > lo, let v = Self.embedding(samples[lo..<hi], extractor: extractor, dim: dim) {
                    let w = Float(piece.end - piece.start)
                    for i in 0..<dim { sum[i] += v[i] * w }
                    weight += w
                }
                done += 1
                progress(Double(done) / Double(total))
            }
            if weight > 0 { out[speaker] = Voiceprint(sum.map { $0 / weight }) }
        }
        return out
    }

    /// 算声纹用的片段：去掉短于 minimumVoiceprintSegment 的（全都短就全用），从长到短取到 voiceprintBudget 秒
    private static func voiceprintSegments(_ segments: [SpeakerSegment]) -> [SpeakerSegment] {
        let long = segments.filter { $0.end - $0.start >= minimumVoiceprintSegment }
        var budget = voiceprintBudget
        var out: [SpeakerSegment] = []
        for s in (long.isEmpty ? segments : long).sorted(by: { $0.end - $0.start > $1.end - $1.start }) {
            guard budget > 0 else { break }
            out.append(s)
            budget -= s.end - s.start
        }
        return out
    }

    /// 一段音频的单位化声纹。太短、模型算不出（IsReady 为假）或结果有 NaN 时为 nil
    private static func embedding(_ samples: ArraySlice<Float>, extractor: OpaquePointer, dim: Int) -> [Float]? {
        guard let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else { return nil }
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        samples.withUnsafeBufferPointer {
            SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), $0.baseAddress, Int32($0.count))
        }
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) != 0,
              let p = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream) else { return nil }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(p) }
        let v = Array(UnsafeBufferPointer(start: p, count: dim))
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return v.map { $0 / norm }
    }

    // MARK: - 解码

    /// 整段录音解码成 16 kHz 单声道 float32（[-1, 1]）。按块读、按块转换，不把原始格式的整段读进内存
    static func decode(_ url: URL, flag: CancelFlag = CancelFlag(),
                       progress: (Double) -> Void = { _ in }) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SherpaOnnxDiarizerError.unreadableAudio(error.localizedDescription)
        }
        guard file.length > 0 else { return [] }
        let input = file.processingFormat
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 1 << 15),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 1 << 15)
        else { throw SherpaOnnxDiarizerError.unreadableAudio("不支持的音频格式 \(input)") }
        converter.downmix = true

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * Double(sampleRate) / input.sampleRate) + 1024)
        var readError: Error?
        while true {
            try flag.check()
            outBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
                guard readError == nil, file.framePosition < file.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuffer)
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = inBuffer.frameLength > 0 ? .haveData : .endOfStream
                return inBuffer.frameLength > 0 ? inBuffer : nil
            }
            if status == .error || readError != nil {
                throw SherpaOnnxDiarizerError.unreadableAudio((readError ?? error)?.localizedDescription ?? "解码失败")
            }
            if let data = outBuffer.floatChannelData, outBuffer.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(outBuffer.frameLength)))
            }
            progress(Double(file.framePosition) / Double(file.length))
            if status == .endOfStream { break }
        }
        guard samples.count < Int(Int32.max) else {
            throw SherpaOnnxDiarizerError.unreadableAudio("录音太长")
        }
        return samples
    }

    private static func verify(_ model: ModelFile, in directory: URL) throws {
        let url = directory.appendingPathComponent(model.name)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SherpaOnnxDiarizerError.modelMissing(model.name)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == model.size, hex == model.sha256 else {
            throw SherpaOnnxDiarizerError.modelCorrupted(model.name)
        }
    }
}

public enum SherpaOnnxDiarizerError: LocalizedError, Equatable {
    case modelMissing(String)
    case modelCorrupted(String)
    /// sherpa-onnx 创建引擎失败（返回 NULL）
    case engineUnavailable
    /// sherpa-onnx 处理录音失败（返回 NULL）
    case processingFailed
    case unreadableAudio(String)

    public var errorDescription: String? {
        switch self {
        case let .modelMissing(name): "缺少区分说话人模型 \(name)，请重新安装 Faymee"
        case let .modelCorrupted(name): "区分说话人模型 \(name) 已损坏，请重新安装 Faymee"
        case .engineUnavailable: "区分说话人引擎启动失败"
        case .processingFailed: "区分说话人引擎处理录音失败"
        case let .unreadableAudio(reason): "读不了录音：\(reason)"
        }
    }
}

/// 取消标记：任务取消时由 withTaskCancellationHandler 置位，跑在 DispatchQueue 上的循环轮询它
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }

    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

/// 进度只增不减：分段阶段的估算和声纹阶段的真实回调来自不同线程，可能交错
private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    private let sink: (Double) -> Void

    init(_ sink: @escaping (Double) -> Void) { self.sink = sink }

    func report(_ v: Double) {
        let v = min(1, max(0, v))
        guard lock.withLock({ () -> Bool in
            guard v > value else { return false }
            value = v
            return true
        }) else { return }
        sink(v)
    }
}
