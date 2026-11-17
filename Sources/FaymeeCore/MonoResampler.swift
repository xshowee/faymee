import AVFoundation

/// 把采集的音频（设备原样的格式：任意采样率、可能多声道）逐块转成 16 kHz 单声道 Float32 样本，
/// sherpa-onnx 的模型都要这个格式。重采样有内部状态，同一路音频一直用同一个实例，只在一个线程里用。
///
/// 实时字幕的 sherpa 流式引擎用它；实时字幕定稿（ticket 08）要留最近的音频切句子时，也可以用它转成同样的样本
final class MonoResampler {
    static let sampleRate = 16000

    private let converter: AVAudioConverter
    private let output: AVAudioFormat

    init?(from input: AVAudioFormat, sampleRate: Int = MonoResampler.sampleRate) {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output)
        else { return nil }
        // 多声道时混成一路，而不是只取第一声道
        converter.downmix = true
        self.converter = converter
        self.output = output
    }

    /// 转换一块。重采样器会留几帧到下一块，所以输出的样本数不严格等于按比例算的
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error, let error { throw error }
        guard let data = converted.floatChannelData, converted.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength)))
    }
}
