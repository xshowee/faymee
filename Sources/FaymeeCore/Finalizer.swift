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
}

/// 把录音分片按顺序拼接并压缩为 AAC（m4a）。
/// 分片之间的采样率可能不同（中途换了麦克风），交给 AVFoundation 统一转换。
public enum Finalizer {
    /// 返回导出文件的时长和每个分片的位置。只有时长核对无误才算成功，调用方据此决定能否删除分片。
    /// 分片位置要在这里记下：整理成功后分片被删除，之后就无从得知墙钟时间对应录音的哪里
    public static func export(segments: [URL], to output: URL) async throws -> FinalizeResult {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw FinalizeError.cannotExport }

        var cursor = CMTime.zero
        var placements: [SegmentPlacement] = []
        for url in segments {
            let asset = AVURLAsset(url: url)
            // 打不开的分片（例如刚创建就崩溃、只有文件头）直接跳过，不影响其余部分
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await source.load(.timeRange),
                  range.duration > .zero
            else {
                placements.append(SegmentPlacement(file: url, offset: cursor.seconds, duration: 0))
                continue
            }
            try track.insertTimeRange(range, of: source, at: cursor)
            placements.append(SegmentPlacement(file: url, offset: cursor.seconds, duration: range.duration.seconds))
            cursor = cursor + range.duration
        }
        guard cursor > .zero else { throw FinalizeError.noAudio }

        let temp = output.deletingLastPathComponent().appendingPathComponent(".exporting.m4a")
        try? FileManager.default.removeItem(at: temp)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw FinalizeError.cannotExport }
        try await session.export(to: temp, as: .m4a)

        let expected = cursor.seconds
        let actual = try await AVURLAsset(url: temp).load(.duration).seconds
        guard abs(actual - expected) < 1 else {
            try? FileManager.default.removeItem(at: temp)
            throw FinalizeError.durationMismatch(expected: expected, actual: actual)
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: temp, to: output)
        return FinalizeResult(duration: actual, placements: placements)
    }
}

extension Meeting {
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
