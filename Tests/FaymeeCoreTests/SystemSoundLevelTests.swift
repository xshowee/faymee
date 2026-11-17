import AVFoundation
import Foundation
import Testing
@testable import FaymeeCore

/// 0.01 秒的 float32 音频。`values[c]` 是第 c 个声道每个样本的值
private func buffer(_ values: [Float], interleaved: Bool) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                               channels: AVAudioChannelCount(values.count), interleaved: interleaved)!
    let frames = 480
    let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    b.frameLength = AVAudioFrameCount(frames)
    let list = UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList)
    if interleaved {
        let data = list[0].mData!.assumingMemoryBound(to: Float.self)
        for i in 0..<frames { for (c, v) in values.enumerated() { data[i * values.count + c] = v } }
    } else {
        for (c, v) in values.enumerated() {
            let data = list[c].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<frames { data[i] = v }
        }
    }
    return b
}

private func record(_ b: AVAudioPCMBuffer, into level: SystemSoundLevel) {
    level.record(b.audioBufferList, format: b.format)
}

/// 系统声音的电平（喂给静音判断）：IOProc 里记、主线程每秒取走一次峰值
@Suite struct SystemSoundLevelTests {
    @Test func 没收到数据算静音() {
        #expect(SystemSoundLevel().take() == -160)
    }

    @Test func 全零算静音() {
        let level = SystemSoundLevel()
        record(buffer([0, 0], interleaved: false), into: level)
        #expect(level.take() == -160)
    }

    /// 0.1 的方波电平是 -20 dBFS
    @Test(arguments: [false, true])
    func 两种排列方式都能量出电平(interleaved: Bool) {
        let level = SystemSoundLevel()
        record(buffer([0.1, 0.1], interleaved: interleaved), into: level)
        #expect(abs(level.take() - -20) < 0.01)
    }

    /// 只有右声道有声音（比如某些会议软件只往一侧出声）也要量得到
    @Test(arguments: [false, true])
    func 只有一个声道有声音也量得到(interleaved: Bool) {
        let level = SystemSoundLevel()
        record(buffer([0, 0.1], interleaved: interleaved), into: level)
        #expect(level.take() > SilenceWatch.threshold)
    }

    @Test func 取的是上次取走以来的峰值_取走后清零() {
        let level = SystemSoundLevel()
        record(buffer([0.1, 0.1], interleaved: false), into: level)
        record(buffer([0.001, 0.001], interleaved: false), into: level)
        #expect(abs(level.take() - -20) < 0.01)
        #expect(level.take() == -160)
    }
}
