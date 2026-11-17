import AVFoundation

public enum FinalizeError: LocalizedError {
    case noAudio
    case cannotExport
    case durationMismatch(expected: TimeInterval, actual: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .noAudio: "没有录到音频"
        case .cannotExport: "无法创建导出任务"
        case let .durationMismatch(expected, actual):
            "导出的录音时长不对（应为 \(formatDuration(expected))，实际 \(formatDuration(actual))），已保留原始分片"
        }
    }
}

/// 一个分片在合并后录音中的位置
public struct SegmentPlacement: Sendable, Equatable {
    public var file: URL
    /// 在录音中的起点（秒）
    public var offset: TimeInterval
    /// 并入录音的时长（秒），被跳过的分片为 0
    public var duration: TimeInterval
}

public struct FinalizeResult: Sendable {
    /// 导出文件的实际时长
    public var duration: TimeInterval
    /// 与传入的分片一一对应、顺序相同
    public var placements: [SegmentPlacement]
    /// 单独保存的系统声音文件名，没有系统声音摆进录音时为 nil
    public var systemSoundFile: String? = nil
}

/// 把录音分片按顺序拼接并压缩为 AAC（m4a）。
/// 分片之间的采样率可能不同（中途换了麦克风），交给 AVFoundation 统一转换。
public enum Finalizer {
    public static let recordingFile = "recording.m4a"
    public static let systemSoundFile = "system.m4a"

    /// 整理一场会议：录音的时间线由麦克风分片决定；记在会议里的系统声音分片按麦克风分片的边界切开，
    /// 经 `RecordingTimeline` 摆进录音，两路混成单声道的 recording.m4a，另导出与之等长对齐的 system.m4a。
    /// 没有系统声音摆进录音时（没开过、或全落在麦克风断点里），产出与只有麦克风时相同，不生成 system.m4a。
    /// 两个文件都核对时长无误才算成功，调用方据此决定能否删除分片
    public static func export(_ meeting: Meeting, in store: MeetingStore) async throws -> FinalizeResult {
        let directory = store.directory(meeting.id)
        let mic = try await MicComposition(segments: store.segmentFiles(meeting.id))
        let output = directory.appendingPathComponent(recordingFile)
        guard let system = try await mic.placeSystemSound(meeting, files: store.systemSoundSegmentFiles(meeting.id))
        else { return try await mic.export(to: output) }

        // 两个文件都先导出到临时文件，都核对无误再一起换上
        let temps = [".exporting.m4a", ".exporting-system.m4a"].map { directory.appendingPathComponent($0) }
        defer { temps.forEach { try? FileManager.default.removeItem(at: $0) } }
        let expected = mic.duration.seconds
        var durations: [TimeInterval] = []
        for (temp, systemOnly) in zip(temps, [false, true]) {
            try? FileManager.default.removeItem(at: temp)
            // 码率：recording.m4a 约 58 MB/小时，system.m4a 约 43 MB/小时
            try await encodeMono(mic.composition, mix: system.audioMix(systemOnly: systemOnly),
                                 bitRate: systemOnly ? 96_000 : 128_000, to: temp)
            let actual = try await AVURLAsset(url: temp).load(.duration).seconds
            guard abs(actual - expected) < 1 else {
                throw FinalizeError.durationMismatch(expected: expected, actual: actual)
            }
            durations.append(actual)
        }
        for (temp, name) in zip(temps, [recordingFile, systemSoundFile]) {
            let url = directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temp, to: url)
        }
        return FinalizeResult(duration: durations[0], placements: mic.placements, systemSoundFile: systemSoundFile)
    }

    /// 返回导出文件的时长和每个分片的位置。只有时长核对无误才算成功，调用方据此决定能否删除分片。
    /// 分片位置要在这里记下：整理成功后分片被删除，之后就无从得知墙钟时间对应录音的哪里
    public static func export(segments: [URL], to output: URL) async throws -> FinalizeResult {
        try await MicComposition(segments: segments).export(to: output)
    }

    /// 含系统声音的录音统一导出为 48 kHz：两路的采样率可能不同
    private static let outputSampleRate = 48000

    /// 读出 composition 的混音（下混为单声道），编码为 AAC。
    /// Apple 的 m4a 导出预设没法指定声道数，单声道加立体声会导出成立体声，所以自己读写
    private static func encodeMono(_ asset: AVAsset, mix: AVAudioMix, bitRate: Int, to url: URL) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.audioMix = mix
        guard reader.canAdd(output) else { throw FinalizeError.cannotExport }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw FinalizeError.cannotExport }
        writer.add(input)

        guard reader.startReading() else { throw reader.error ?? FinalizeError.cannotExport }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? FinalizeError.cannotExport
        }
        writer.startSession(atSourceTime: .zero)
        let pump = EncodePump(reader: reader, output: output, writer: writer, input: input)
        try await withCheckedThrowingContinuation { pump.run($0) }
    }
}

/// 把 reader 读出的样本依次交给 writer。回调都在同一个串行队列上，done 不用加锁
private final class EncodePump: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var done = false

    init(reader: AVAssetReader, output: AVAssetReaderOutput, writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.reader = reader
        self.output = output
        self.writer = writer
        self.input = input
    }

    func run(_ continuation: CheckedContinuation<Void, Error>) {
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "Faymee.Finalizer.encode")) { [self] in
            while !done, input.isReadyForMoreMediaData {
                if let sample = output.copyNextSampleBuffer() {
                    guard input.append(sample) else {
                        done = true
                        reader.cancelReading()
                        writer.cancelWriting()
                        continuation.resume(throwing: writer.error ?? FinalizeError.cannotExport)
                        return
                    }
                    continue
                }
                done = true
                input.markAsFinished()
                guard reader.status != .failed else {
                    writer.cancelWriting()
                    continuation.resume(throwing: reader.error ?? FinalizeError.cannotExport)
                    return
                }
                writer.finishWriting { [self] in
                    if let error = writer.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
}

/// 麦克风分片按顺序首尾相接拼成的音轨，决定录音的时间线
private struct MicComposition {
    let composition = AVMutableComposition()
    let track: AVMutableCompositionTrack
    var placements: [SegmentPlacement] = []
    var duration = CMTime.zero
    /// composition 只引用源文件的音轨，源 asset 要活到导出结束
    var assets: [AVURLAsset] = []
    /// 每个并入录音的分片在录音里的起点和声道数，混成单声道时用来定音量
    var channelCounts: [(at: CMTime, count: Int)] = []

    init(segments: [URL]) async throws {
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw FinalizeError.cannotExport }
        self.track = track
        for url in segments {
            let asset = AVURLAsset(url: url)
            // 打不开的分片（例如刚创建就崩溃、只有文件头）直接跳过，不影响其余部分
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await source.load(.timeRange),
                  range.duration > .zero
            else {
                placements.append(SegmentPlacement(file: url, offset: duration.seconds, duration: 0))
                continue
            }
            try track.insertTimeRange(range, of: source, at: duration)
            assets.append(asset)
            channelCounts.append((duration, await channelCount(source)))
            placements.append(SegmentPlacement(file: url, offset: duration.seconds, duration: range.duration.seconds))
            duration = duration + range.duration
        }
        guard duration > .zero else { throw FinalizeError.noAudio }
    }

    /// 只有麦克风：用 Apple 的 m4a 预设导出，与加入系统声音之前的产出相同
    func export(to output: URL) async throws -> FinalizeResult {
        let temp = output.deletingLastPathComponent().appendingPathComponent(".exporting.m4a")
        try? FileManager.default.removeItem(at: temp)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw FinalizeError.cannotExport }
        try await session.export(to: temp, as: .m4a)

        let expected = duration.seconds
        let actual = try await AVURLAsset(url: temp).load(.duration).seconds
        guard abs(actual - expected) < 1 else {
            try? FileManager.default.removeItem(at: temp)
            throw FinalizeError.durationMismatch(expected: expected, actual: actual)
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: temp, to: output)
        return FinalizeResult(duration: actual, placements: placements)
    }

    /// 把会议里记了的系统声音分片切开，摆进 composition 的第二条音轨。
    /// 磁盘上有、会议里没记的分片不知道墙钟起点，丢弃。一块也没摆进去时返回 nil，composition 不变
    func placeSystemSound(_ meeting: Meeting, files: [URL]) async throws -> SystemSoundTrack? {
        var placed = meeting
        placed.recordPlacements(placements)
        guard let timeline = RecordingTimeline(placed) else { return nil }
        let onDisk = Dictionary(files.map { ($0.lastPathComponent, $0) }) { first, _ in first }

        var pieces: [(source: AVAssetTrack, start: CMTime, piece: TimelinePiece, channels: Int)] = []
        var assets: [AVURLAsset] = []
        for segment in meeting.systemSoundSegmentList {
            guard let url = onDisk[segment.file] else { continue }
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await source.load(.timeRange),
                  range.duration > .zero
            else { continue }
            assets.append(asset)
            let channels = await channelCount(source)
            for piece in timeline.pieces(from: segment.startedAt, duration: range.duration.seconds) {
                pieces.append((source, range.start, piece, channels))
            }
        }
        guard !pieces.isEmpty,
              let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }

        // 按录音里的位置依次往后接：插进已有内容中间会把后面的内容整体后推，
        // 所以与前一块重叠的部分（两个系统声音分片的墙钟起点有毫秒级的出入）从这一块的开头裁掉
        let volume = AVMutableAudioMixInputParameters(track: track)
        var cursor = 0.0
        for (source, start, piece, channels) in pieces.sorted(by: { $0.piece.offset < $1.piece.offset }) {
            let trim = max(0, cursor - piece.offset)
            let at = piece.offset + trim
            let length = min(piece.duration - trim, duration.seconds - at)
            guard length > 0.001 else { continue }
            if at > cursor {
                track.insertEmptyTimeRange(CMTimeRange(start: time(cursor), end: time(at)))
            }
            try track.insertTimeRange(CMTimeRange(start: start + time(piece.source + trim), duration: time(length)),
                                      of: source, at: time(at))
            volume.setVolume(downmixGain(channels), at: time(at))
            cursor = at + length
        }
        let micVolume = AVMutableAudioMixInputParameters(track: self.track)
        for (at, count) in channelCounts { micVolume.setVolume(downmixGain(count), at: at) }
        return SystemSoundTrack(mic: micVolume, system: volume, assets: assets)
    }

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48000) }
}

/// 两路等权重相加。多声道下混到单声道时按 −3 dB 声像律相加，L=R 时比原来响 3 dB；
/// 乘 1/√2 后单声道等于两声道的平均
private func downmixGain(_ channels: Int) -> Float {
    channels > 1 ? Float(0.5.squareRoot()) : 1
}

/// 读不出格式时当单声道
private func channelCount(_ track: AVAssetTrack) async -> Int {
    guard let format = try? await track.load(.formatDescriptions).first,
          let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)
    else { return 1 }
    return Int(description.pointee.mChannelsPerFrame)
}

/// 已摆进 composition 的系统声音音轨
private struct SystemSoundTrack {
    var mic: AVMutableAudioMixInputParameters
    var system: AVMutableAudioMixInputParameters
    /// 源 asset 要活到导出结束
    var assets: [AVURLAsset]

    /// systemOnly 时麦克风音量为 0：麦克风音轨仍在混音里，导出的文件才和 recording.m4a 一样长
    func audioMix(systemOnly: Bool) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        var muted: AVMutableAudioMixInputParameters?
        if systemOnly {
            muted = AVMutableAudioMixInputParameters()
            muted!.trackID = mic.trackID
            muted!.setVolume(0, at: .zero)
        }
        mix.inputParameters = [system, muted ?? mic]
        return mix
    }
}

extension Meeting {
    /// 整理成功：记下录音文件、时长和分片位置，同时标记为排队转写。
    /// 两者要在同一次保存里：分两次写的话，中间崩溃这场会议就再也不会自动转写
    /// （启动时只恢复排队中和转写中的会议）
    public mutating func markFinalized(recording: String, _ result: FinalizeResult) {
        self.recording = recording
        duration = result.duration
        recordPlacements(result.placements)
        systemSoundRecording = result.systemSoundFile
        status = .done
        transcription = TranscriptionState(status: .queued)
    }

    /// 把整理得到的分片位置写进 segments，供之后把墙钟时间映射到录音偏移（见 RecordingTimeline）。
    /// 按文件名对应而不是按下标：Finalizer 拿到的是磁盘上的分片列表，可能与 meeting.json 不完全一致。
    /// meeting.json 里有、磁盘上没有的分片没有并入录音，记为时长 0、紧接前一个分片，
    /// 免得一个缺失的字段让整场会议退回到近似算法
    public mutating func recordPlacements(_ placements: [SegmentPlacement]) {
        let byFile = Dictionary(placements.map { ($0.file.lastPathComponent, $0) }) { first, _ in first }
        var cursor: TimeInterval = 0
        for i in segments.indices {
            let placement = byFile[segments[i].file]
            segments[i].offset = placement?.offset ?? cursor
            segments[i].duration = placement?.duration ?? 0
            cursor = segments[i].offset! + segments[i].duration!
        }
    }
}
