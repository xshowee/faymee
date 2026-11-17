import AVFoundation
import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-11T02:00:00Z", strategy: .iso8601)
private let mic = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
/// 系统声音一般是立体声
private let system = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

/// 一块音频，每个样本由 sample(帧号) 给出，各声道相同
private func buffer(_ format: AVAudioFormat, seconds: Double, _ sample: (Int) -> Float) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount((format.sampleRate * seconds).rounded())
    let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    b.frameLength = frames
    let channels = Int(format.channelCount)
    for i in 0..<Int(frames) {
        for c in 0..<channels {
            if format.isInterleaved {
                b.floatChannelData![0][i * channels + c] = sample(i)
            } else {
                b.floatChannelData![c][i] = sample(i)
            }
        }
    }
    return b
}

/// 系统声音的测试信号：逐个样本递增，丢了、重了样本都看得出来
private func ramp(_ n: Int) -> Float { Float(n + 1) * 1e-5 }

/// 采集线程送麦克风：count 块各 0.1 秒的静音，从 start 秒开始，时刻取每块收到时（即块的末尾）
private func pushMic(_ mixer: LiveAudioMixer, from start: Double, count: Int, format: AVAudioFormat = mic,
                     value: Float = 0) {
    for i in 0..<count {
        let end = start + Double(i + 1) / 10
        mixer.microphone.push(buffer(format, seconds: 0.1) { _ in value }, at: t0.addingTimeInterval(end))
    }
}

/// 采集线程送系统声音：从 start 秒开始、共 seconds 秒的递增信号，每块 10 毫秒（IOProc 的块很小）。
/// 递增信号从 first 号样本接着往下数
private func pushSystem(_ mixer: LiveAudioMixer, from start: Double, seconds: Double, first: Int = 0,
                        format: AVAudioFormat = system) {
    let blocks = Int((seconds * 100).rounded())
    let frames = Int(format.sampleRate / 100)
    for k in 0..<blocks {
        let end = start + Double(k + 1) / 100
        let offset = first + k * frames
        mixer.systemSound.push(buffer(format, seconds: 0.01) { ramp(offset + $0) }, at: t0.addingTimeInterval(end))
    }
}

/// 取出的音频接成一串（第一个声道）
private func samples(_ chunks: [LiveAudioTap.Chunk]) -> [Float] {
    chunks.flatMap { c in (0..<Int(c.buffer.frameLength)).map { c.buffer.floatChannelData![0][$0] } }
}

@Suite struct LiveAudioMixerTests {
    @Test func 两路按时间对齐_系统声音落在麦克风的同一时刻() {
        let mixer = LiveAudioMixer()
        mixer.isEnabled = true
        pushMic(mixer, from: 0, count: 10)
        pushSystem(mixer, from: 0.5, seconds: 0.2)

        let out = mixer.drain()
        // 输出跟着麦克风：块数、时刻、格式都不变
        #expect(out.map(\.time) == (1...10).map { t0.addingTimeInterval(Double($0) / 10) })
        #expect(out.allSatisfy { $0.buffer.format == mic })
        let s = samples(out)
        #expect(s.count == 48000)
        #expect(s[0..<24000].allSatisfy { $0 == 0 })
        #expect(Array(s[24000..<33600]) == (0..<9600).map(ramp))
        #expect(s[33600...].allSatisfy { $0 == 0 })
    }

    /// 两路相加：说话的同时对方也在说，两边都在；加起来超过满幅时限幅，不绕回
    @Test func 两路相加_超过满幅时限幅() {
        let mixer = LiveAudioMixer()
        mixer.isEnabled = true
        pushMic(mixer, from: 0, count: 1, value: 0.25)
        pushMic(mixer, from: 0.1, count: 1, value: 0.8)
        for k in 0..<20 {
            mixer.systemSound.push(buffer(system, seconds: 0.01) { _ in 0.5 }, at: t0.addingTimeInterval(Double(k + 1) / 100))
        }

        let s = samples(mixer.drain())
        #expect(s[0..<4800].allSatisfy { $0 == 0.75 })
        #expect(s[4800...].allSatisfy { $0 == 1 })
    }

    /// 收到时刻有抖动，系统声音的最后一点常常晚于麦克风那块才到：照样一个样本不丢、不重复，
    /// 不会因为差了几十毫秒就重新对齐、把对方的话切碎
    @Test func 收到时刻有抖动_系统声音晚到一点_样本连续不丢不重() {
        let mixer = LiveAudioMixer()
        mixer.isEnabled = true
        let micJitter: [Double] = [0, 0.02, -0.015, 0.01, -0.02, 0.018, 0, -0.01, 0.02, -0.005]
        let systemJitter: [Double] = [0, 0.003, -0.002, 0.001, -0.003]
        var out: [LiveAudioTap.Chunk] = []
        var late: [(AVAudioPCMBuffer, Date)] = []
        for r in 0..<10 {
            let micEnd = Double(r + 1) / 10 + micJitter[r]
            mixer.microphone.push(buffer(mic, seconds: 0.1) { _ in 0 }, at: t0.addingTimeInterval(micEnd))
            for (b, t) in late { mixer.systemSound.push(b, at: t) }
            late = []
            for k in 0..<10 {
                let block = r * 10 + k
                let end = Double(block + 1) / 100 + (block == 0 ? 0 : systemJitter[block % 5])
                let b = buffer(system, seconds: 0.01) { ramp(block * 480 + $0) }
                // 这一轮的最后两块等到下一轮才到
                if k >= 8 { late.append((b, t0.addingTimeInterval(end))) } else {
                    mixer.systemSound.push(b, at: t0.addingTimeInterval(end))
                }
            }
            out += mixer.drain()
        }

        let heard = samples(out).filter { $0 != 0 }
        #expect(heard == (0..<heard.count).map(ramp))
        // 只有最后晚到、还没混的两块没出来
        #expect(heard.count == 48000 - 960)
    }

    @Test func 系统声音一直没有数据_麦克风照常输出不等待() {
        let mixer = LiveAudioMixer()
        mixer.isEnabled = true
        var out: [LiveAudioTap.Chunk] = []
        for r in 0..<3 {
            pushMic(mixer, from: Double(r), count: 10, value: 0.25)
            let drained = mixer.drain()
            #expect(drained.count == 10)
            out += drained
        }
        #expect(out.map(\.time) == (1...30).map { t0.addingTimeInterval(Double($0) / 10) })
        #expect(samples(out) == [Float](repeating: 0.25, count: 3 * 48000))
    }

    /// 录音中打开、关掉、再打开系统声音：输出还是一块接一块的麦克风，格式不变（实时字幕不会因此重开转写），
    /// 系统声音只出现在开着的时候。没在放声音时系统声音可能一阵没有回调，之后的仍落在对的时刻
    @Test func 中途开关系统声音_输出连续_系统声音落在开着的时段() {
        let mixer = LiveAudioMixer()
        mixer.isEnabled = true
        var out: [LiveAudioTap.Chunk] = []
        // 0–1 秒没开
        pushMic(mixer, from: 0, count: 10)
        out += mixer.drain()
        // 1–2 秒开着：前 0.3 秒有声音，中间 0.6 秒没在放（没有回调），最后 0.1 秒又有
        pushMic(mixer, from: 1, count: 10)
        pushSystem(mixer, from: 1, seconds: 0.3)
        pushSystem(mixer, from: 1.9, seconds: 0.1, first: 14400)
        out += mixer.drain()
        // 2–3 秒关了，3–4 秒又开
        pushMic(mixer, from: 2, count: 10)
        out += mixer.drain()
        pushMic(mixer, from: 3, count: 10)
        pushSystem(mixer, from: 3, seconds: 1, first: 20000)
        out += mixer.drain()

        #expect(out.map(\.time) == (1...40).map { t0.addingTimeInterval(Double($0) / 10) })
        #expect(out.allSatisfy { $0.buffer.format == mic })
        let s = samples(out)
        let second = 48000
        #expect(s[0..<second].allSatisfy { $0 == 0 })
        #expect(Array(s[second..<second + 14400]) == (0..<14400).map(ramp))
        #expect(s[second + 14400..<second + 43200].allSatisfy { $0 == 0 })
        #expect(Array(s[second + 43200..<2 * second]) == (14400..<19200).map(ramp))
        #expect(s[2 * second..<3 * second].allSatisfy { $0 == 0 })
        #expect(Array(s[3 * second..<4 * second]) == (20000..<68000).map(ramp))
    }

    /// 蓝牙耳机的麦克风常是 16 kHz，系统声音是 48 kHz 交错立体声：系统声音换成麦克风的采样率、
    /// 两个声道平均成一路再混进去，输出仍是麦克风的格式
    @Test func 系统声音的格式和麦克风不同_换成麦克风的格式再混() {
        let headset = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                                    interleaved: false)!
        let interleaved = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2,
                                        interleaved: true)!
        let mixer = LiveAudioMixer()
        mixer.isEnabled = true
        pushMic(mixer, from: 0, count: 20, format: headset)
        // 0.5–1.5 秒：左声道 0.3、右声道 0.1
        for k in 0..<100 {
            let b = AVAudioPCMBuffer(pcmFormat: interleaved, frameCapacity: 480)!
            b.frameLength = 480
            for i in 0..<480 {
                b.floatChannelData![0][2 * i] = 0.3
                b.floatChannelData![0][2 * i + 1] = 0.1
            }
            mixer.systemSound.push(b, at: t0.addingTimeInterval(0.5 + Double(k + 1) / 100))
        }

        let out = mixer.drain()
        #expect(out.count == 20)
        #expect(out.allSatisfy { $0.buffer.format == headset })
        let s = samples(out)
        #expect(s.count == 32000)
        #expect(s[0..<7800].allSatisfy { $0 == 0 })
        #expect(s[8200..<23800].allSatisfy { abs($0 - 0.2) < 1e-3 })
        #expect(s[24200...].allSatisfy { abs($0) < 1e-3 })
    }

    /// 主线程迟迟没来取：两路各只留最新的，丢最旧的，留下的仍按时间对齐
    @Test func 超过缓冲上限时丢最旧的_留下的照样对齐() {
        // 留下 10 块麦克风（0.5–1.5 秒）、105 块系统声音（0.45–1.5 秒）：系统声音早出来的那点丢掉
        let mixer = LiveAudioMixer(capacity: 1.05)
        mixer.isEnabled = true
        pushMic(mixer, from: 0, count: 15)
        pushSystem(mixer, from: 0, seconds: 1.5)

        let out = mixer.drain()
        #expect(out.map(\.time) == (6...15).map { t0.addingTimeInterval(Double($0) / 10) })
        #expect(samples(out) == (24000..<72000).map(ramp))
    }

    /// 关掉（面板看不见、录音结束）时丢掉还没混的系统声音，再打开时不会把旧的混进来
    @Test func 关掉再打开_不混进之前剩下的系统声音() {
        let mixer = LiveAudioMixer()
        mixer.isEnabled = true
        pushMic(mixer, from: 0, count: 1)
        pushSystem(mixer, from: 0, seconds: 0.5)
        _ = mixer.drain()
        mixer.isEnabled = false
        mixer.isEnabled = true
        pushMic(mixer, from: 0.1, count: 4)

        #expect(samples(mixer.drain()).allSatisfy { $0 == 0 })
    }

    /// 切换麦克风后格式变了：输出跟着麦克风换格式（实时字幕会话据此接着转写，不插分隔行），
    /// 系统声音照常混进新格式的每个声道
    @Test func 麦克风切换格式_输出跟着换_系统声音照常混进去() {
        let usb = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let mixer = LiveAudioMixer()
        mixer.isEnabled = true
        pushMic(mixer, from: 0, count: 10)
        pushSystem(mixer, from: 0, seconds: 1)
        let before = mixer.drain()
        pushMic(mixer, from: 1, count: 10, format: usb)
        pushSystem(mixer, from: 1, seconds: 1, first: 48000)
        let after = mixer.drain()

        #expect((before + after).map(\.time) == (1...20).map { t0.addingTimeInterval(Double($0) / 10) })
        #expect(before.allSatisfy { $0.buffer.format == mic })
        #expect(after.allSatisfy { $0.buffer.format == usb })
        #expect(samples(before) == (0..<48000).map(ramp))
        // 换了采样率，只看量级：落在 1 秒处信号的大小附近，声道 0、1 一样
        let s = samples(after)
        #expect(s.count == 44100)
        #expect(abs(s[22050] - ramp(48000 + 24000)) < 1e-3)
        #expect(after.allSatisfy { c in
            (0..<Int(c.buffer.frameLength)).allSatisfy { c.buffer.floatChannelData![0][$0] == c.buffer.floatChannelData![1][$0] }
        })
    }
}
