import AVFoundation

/// 麦克风设备的输入流布局：采样率和每个输入流的声道数。
///
/// 直接在设备上建 IOProc 采集时，回调给的 AudioBufferList 每个流一个 buffer，流内是交错的 Float32
/// （设备的 virtual format）。录音分片、电平和实时字幕用的是非交错 Float32，各流的声道按顺序排在一起，
/// 这里负责转换。
public struct InputStreamLayout: Equatable, Sendable {
    public var sampleRate: Double
    public var channelsPerStream: [Int]

    public init(sampleRate: Double, channelsPerStream: [Int]) {
        self.sampleRate = sampleRate
        self.channelsPerStream = channelsPerStream
    }

    public var channelCount: Int { channelsPerStream.reduce(0, +) }

    /// 转换后的格式（非交错 Float32）。没有声道或采样率时为 nil
    public func makeFormat() -> AVAudioFormat? {
        let channels = channelCount
        guard sampleRate > 0, channels > 0, channelsPerStream.allSatisfy({ $0 > 0 }) else { return nil }
        if channels <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                 channels: AVAudioChannelCount(channels), interleaved: false)
        }
        // 两个声道以上必须带声道布局
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))
        else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false,
                             channelLayout: layout)
    }

    /// 把 IOProc 给的数据拷成 format（`makeFormat()` 的结果）的新 buffer。
    /// 数据的流数、声道数、帧数和布局对不上（设备配置刚变、还没重建）或没有数据时返回 nil
    public func deinterleave(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard buffers.count == channelsPerStream.count else { return nil }
        var frames: Int?
        for (buffer, channels) in zip(buffers, channelsPerStream) {
            guard Int(buffer.mNumberChannels) == channels, buffer.mData != nil else { return nil }
            let count = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            guard frames == nil || frames == count else { return nil }
            frames = count
        }
        guard let frames, frames > 0,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData
        else { return nil }
        output.frameLength = AVAudioFrameCount(frames)
        var next = 0
        for (buffer, channels) in zip(buffers, channelsPerStream) {
            let source = buffer.mData!.assumingMemoryBound(to: Float.self)
            for channel in 0 ..< channels {
                let target = destination[next + channel]
                for frame in 0 ..< frames {
                    target[frame] = source[frame * channels + channel]
                }
            }
            next += channels
        }
        return output
    }
}
