import Foundation
import Testing
@testable import FaymeeCore

@Suite struct VoiceprintTests {
    @Test func 方向相同时相似度为1() {
        #expect(abs(Voiceprint([1, 2, 3]).similarity(to: Voiceprint([2, 4, 6])) - 1) < 1e-6)
    }

    @Test func 正交时为0() {
        #expect(Voiceprint([1, 0]).similarity(to: Voiceprint([0, 5])) == 0)
    }

    @Test func 相反时为负1() {
        #expect(abs(Voiceprint([1, -2]).similarity(to: Voiceprint([-1, 2])) + 1) < 1e-6)
    }

    /// (1,1)·(1,0) / (√2·1) = √2/2
    @Test func 一般情况() {
        #expect(abs(Voiceprint([1, 1]).similarity(to: Voiceprint([3, 0])) - 0.70710678) < 1e-6)
    }

    /// 维数不同（换了声纹模型）、空向量、零向量都不可比，当作不像
    @Test func 不可比时为0() {
        #expect(Voiceprint([1, 0]).similarity(to: Voiceprint([1, 0, 0])) == 0)
        #expect(Voiceprint([]).similarity(to: Voiceprint([])) == 0)
        #expect(Voiceprint([0, 0]).similarity(to: Voiceprint([1, 0])) == 0)
    }
}
