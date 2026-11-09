import AVFoundation

enum FinalizeError: LocalizedError {
    case noAudio
    case cannotExport
    case durationMismatch(expected: TimeInterval, actual: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .noAudio: "没有录到音频"
        case .cannotExport: "无法创建导出任务"
        case let .durationMismatch(expected, actual):
            "导出的录音时长不对（应为 \(formatDuration(expected))，实际 \(formatDuration(actual))），已保留原始分片"
        }
    }
}

/// 把录音分片按顺序拼接并压缩为 AAC（m4a）。
/// 分片之间的采样率可能不同（中途换了麦克风），交给 AVFoundation 统一转换。
enum Finalizer {
    /// 返回导出文件的时长。只有时长核对无误才算成功，调用方据此决定能否删除分片
    static func export(segments: [URL], to output: URL) async throws -> TimeInterval {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw FinalizeError.cannotExport }

        var cursor = CMTime.zero
        for url in segments {
            let asset = AVURLAsset(url: url)
            // 打不开的分片（例如刚创建就崩溃、只有文件头）直接跳过，不影响其余部分
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await source.load(.timeRange),
                  range.duration > .zero
            else { continue }
            try track.insertTimeRange(range, of: source, at: cursor)
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
        return actual
    }
}
