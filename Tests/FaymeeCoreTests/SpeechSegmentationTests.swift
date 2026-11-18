import Foundation
import Testing
@testable import FaymeeCore

/// 静音切段的后处理：VAD 的说话段前后补 0.3 秒，再把超过 10 秒的切开。全部按 16 kHz 样本下标
@Suite struct SpeechSegmentationTests {
    private let rate = 16000
    private func s(_ seconds: Double) -> Int { Int((seconds * 16000).rounded()) }

    /// 有声音的样本（振幅 0.5），`quiet` 范围内为 0
    private func audio(seconds: Double, quiet: [Range<Double>] = []) -> [Float] {
        var x = [Float](repeating: 0.5, count: s(seconds))
        for q in quiet { for i in s(q.lowerBound)..<s(q.upperBound) { x[i] = 0 } }
        return x
    }

    @Test func 说话段前后各补0点3秒_不越过录音两端() {
        let x = audio(seconds: 20)

        let segments = SpeechSegmentation.segments(speech: [s(0.1)..<s(2), s(5)..<s(8), s(19)..<s(19.9)], samples: x)

        #expect(segments == [
            SpeechSegment(audio: 0..<s(2.3), speech: s(0.1)..<s(2)),
            SpeechSegment(audio: s(4.7)..<s(8.3), speech: s(5)..<s(8)),
            SpeechSegment(audio: s(18.7)..<s(20), speech: s(19)..<s(19.9)),
        ])
    }

    /// 补边后超过 10 秒：在 6–10 秒之间能量最低的 0.1 秒处切开（切在那 0.1 秒的中点），切点处不补边
    @Test func 超过10秒的段在6到10秒间最安静处切开_切点不补边() {
        let x = audio(seconds: 20, quiet: [7.45..<7.55])

        // 补边后是 0.7–13.3 秒（12.6 秒）；从 0.7 秒起 6–10 秒内最安静的是 7.45–7.55 秒
        let segments = SpeechSegmentation.segments(speech: [s(1)..<s(13)], samples: x)

        #expect(segments == [
            SpeechSegment(audio: s(0.7)..<s(7.5), speech: s(1)..<s(7.5)),
            SpeechSegment(audio: s(7.5)..<s(13.3), speech: s(7.5)..<s(13)),
        ])
    }

    /// 很长的段反复切，直到每段 ≤ 10 秒；说话部分首尾相接、不重叠
    @Test func 很长的段反复切到每段不超过10秒() {
        let x = audio(seconds: 40, quiet: [8.0..<8.1, 15.3..<15.4, 24.0..<24.1])

        let segments = SpeechSegmentation.segments(speech: [s(0.5)..<s(32)], samples: x)

        #expect(segments.allSatisfy { $0.audio.count <= s(10) })
        #expect(segments.map(\.speech.lowerBound).first == s(0.5))
        #expect(segments.map(\.speech.upperBound).last == s(32))
        #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.speech.upperBound == $1.speech.lowerBound })
        #expect(segments.dropLast().map(\.speech.upperBound) == [s(8.05), s(15.35), s(24.05)])
    }

    /// 没有安静处（全程同样响）也照样切，不超过 10 秒
    @Test func 没有安静处也不超过10秒() {
        let x = audio(seconds: 30)

        let segments = SpeechSegmentation.segments(speech: [0..<x.count], samples: x)

        #expect(segments.allSatisfy { $0.audio.count <= s(10) && !$0.speech.isEmpty })
        #expect(segments.first?.audio.lowerBound == 0 && segments.last?.audio.upperBound == x.count)
        #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.audio.upperBound == $1.audio.lowerBound })
    }

    /// 补边后才超过 10 秒、最安静处落在段尾补边里（真实录音里补边常常就是最安静的）：说话部分全在第一块，
    /// 只剩补边的那一小块不要
    @Test func 切点落在段尾补边里时丢掉只剩补边的一块() {
        let x = audio(seconds: 20, quiet: [10.1..<10.4])

        // 补边后 0.2–10.4 秒（10.2 秒）；6.2–10.2 秒内最安静的是 10.1–10.2 秒，切在 10.15 秒，已在说话部分之后
        let segments = SpeechSegmentation.segments(speech: [s(0.5)..<s(10.1)], samples: x)

        #expect(segments == [SpeechSegment(audio: s(0.2)..<s(10.15), speech: s(0.5)..<s(10.1))])
    }

    /// 刚好 10 秒（补边后）不切
    @Test func 补边后正好10秒不切() {
        let x = audio(seconds: 20)

        let segments = SpeechSegmentation.segments(speech: [s(1)..<s(10.4)], samples: x)

        #expect(segments == [SpeechSegment(audio: s(0.7)..<s(10.7), speech: s(1)..<s(10.4))])
    }
}
