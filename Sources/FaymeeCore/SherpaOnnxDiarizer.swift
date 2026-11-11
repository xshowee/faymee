import AVFoundation
import CryptoKit
import Foundation
import SherpaOnnxC

/// 区分说话人引擎：逐句声纹聚类。用 sherpa-onnx 2.0.1 的声纹提取（3D-Speaker ERes2Net base 中文模型，
/// 512 维）给转写稿每句算一个声纹，再用 `SentenceClustering` 把句子归成人。纯 CPU，模型从 `modelDirectory` 读。
/// 不用 sherpa-onnx 的 pyannote 分段 + 整段聚类：真实远场会议上它既拆碎又混人（ticket 12、13）
///
/// - 坏模型会让 sherpa-onnx `_Exit` 整个进程：`prepare` 先校验模型文件的 sha256，对不上就抛错，不交给 sherpa-onnx
/// - 解码和逐句算声纹都是自己的循环，取消后最多再算完一句就抛 `CancellationError`
/// - 每句一个说话片段（就是这句的起止时间）；太短算不出声纹的句子没有片段，归属为未知
/// - 内存主要是整段录音解码后的样本（1 小时约 230MB）和聚类的相似度矩阵（1000 个长句约 8MB）
public final class SherpaOnnxDiarizer: SpeakerDiarizer, @unchecked Sendable {
    public struct ModelFile: Sendable, Equatable {
        public let name: String
        /// 字节数
        public let size: Int64
        /// 小写 hex
        public let sha256: String
    }

    /// 文件名、大小、sha256 与 scripts/fetch-diarization-models.sh 保持一致
    public static let embeddingModel = ModelFile(
        name: "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx", size: 39_593_761,
        sha256: "1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b")
    public static let models = [embeddingModel]

    /// 声纹库匹配的推荐阈值（余弦相似度），App 传给 `TranscriptionPipeline.voiceprintThreshold`。
    /// 一人一个声纹是各句声纹按时长加权的平均。真实会议同一场前后半场：同组最低 0.54，异组最高 0.62，有重叠；
    /// 取偏高的 0.7，宁可认不出（用户手动命名）也不认错人。跨会议未验证，暂定值（ticket 12）
    public static let recommendedMatchThreshold: Float = 0.7

    /// 文件都在且大小对。不算哈希（`prepare` 才算），App 用它决定有没有可用的引擎
    public static func modelsPresent(in directory: URL) -> Bool {
        models.allSatisfy { m in
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(m.name).path)
            return (attributes?[.size] as? NSNumber)?.int64Value == m.size
        }
    }

    public let engine = "sherpa-onnx-2.0.1/sentence-clustering"
    public let voiceprintModel = "3dspeaker-eres2net-base-zh-cn-3dspeaker-16k"

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

    public func diarize(audio: URL, sentences: [ClosedRange<TimeInterval>], speakerCount: Int?,
                        progress: @escaping (Double) -> Void) async throws -> DiarizationResult {
        try await prepare { _ in }
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                queue.async {
                    c.resume(with: Result {
                        try self.run(audio: audio, sentences: sentences, speakerCount: speakerCount, flag: flag,
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
    /// 进度分配：解码 0–10%，逐句声纹 10–100%（聚类很快，不单独算）
    private static let decodeShare = 0.1
    /// 不长于此（0.1 秒）的句子不算声纹
    private static let minimumSamples = sampleRate / 10

    private func run(audio: URL, sentences: [ClosedRange<TimeInterval>], speakerCount: Int?, flag: CancelFlag,
                     progress: Progress) throws -> DiarizationResult {
        try flag.check()
        guard !sentences.isEmpty else {
            progress.report(1)
            return DiarizationResult(segments: [], voiceprints: [:])
        }
        let samples = try Self.decode(audio, flag: flag) { progress.report($0 * Self.decodeShare) }

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

        var embedded: [(range: ClosedRange<TimeInterval>, vector: [Float])] = []
        for (i, r) in sentences.enumerated() {
            try flag.check()
            let lo = max(0, Int(r.lowerBound * Double(Self.sampleRate)))
            let hi = min(samples.count, Int(r.upperBound * Double(Self.sampleRate)))
            if hi - lo > Self.minimumSamples, let v = Self.embedding(samples[lo..<hi], extractor: extractor, dim: dim) {
                embedded.append((r, v))
            }
            progress.report(Self.decodeShare + Double(i + 1) / Double(sentences.count) * (1 - Self.decodeShare))
        }
        try flag.check()

        let labels = SentenceClustering.cluster(
            embedded.map { SentenceClustering.Item(vector: $0.vector, duration: $0.range.upperBound - $0.range.lowerBound) },
            speakerCount: speakerCount)
        progress.report(1)
        return Self.result(embedded, labels: labels, dim: dim)
    }

    /// 每句一个片段；每人的声纹是他各句（单位化的）声纹按时长加权平均，再单位化
    static func result(_ embedded: [(range: ClosedRange<TimeInterval>, vector: [Float])], labels: [Int],
                       dim: Int) -> DiarizationResult {
        var sums: [Int: [Float]] = [:]
        var segments: [SpeakerSegment] = []
        for (e, label) in zip(embedded, labels) {
            segments.append(SpeakerSegment(start: e.range.lowerBound, end: e.range.upperBound, speaker: label))
            let w = Float(e.range.upperBound - e.range.lowerBound)
            var sum = sums[label] ?? [Float](repeating: 0, count: dim)
            for d in 0..<dim { sum[d] += e.vector[d] * w }
            sums[label] = sum
        }
        let voiceprints = sums.mapValues { sum -> Voiceprint in
            let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return Voiceprint(norm > 0 ? sum.map { $0 / norm } : sum)
        }
        return DiarizationResult(segments: segments, voiceprints: voiceprints)
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
    /// sherpa-onnx 创建声纹提取器失败（返回 NULL）
    case engineUnavailable
    case unreadableAudio(String)

    public var errorDescription: String? {
        switch self {
        case let .modelMissing(name): "缺少区分说话人模型 \(name)，请重新安装 Faymee"
        case let .modelCorrupted(name): "区分说话人模型 \(name) 已损坏，请重新安装 Faymee"
        case .engineUnavailable: "区分说话人引擎启动失败"
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

/// 进度只增不减
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
