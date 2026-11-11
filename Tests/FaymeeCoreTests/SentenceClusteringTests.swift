import Foundation
import Testing
@testable import FaymeeCore

/// 单位向量 e_i 加一点偏移：同一个 i 的几句彼此很像，不同 i 之间正交
private func voice(_ axis: Int, jitter: Int = 0, dim: Int = 8) -> [Float] {
    var v = [Float](repeating: 0, count: dim)
    v[axis] = 1
    v[(axis + 1 + jitter) % dim] += 0.1
    return v
}

private func item(_ axis: Int, _ duration: TimeInterval, jitter: Int = 0) -> SentenceClustering.Item {
    SentenceClustering.Item(vector: voice(axis, jitter: jitter), duration: duration)
}

struct SentenceClusteringTests {
    @Test func 没有句子_没有组() {
        #expect(SentenceClustering.cluster([], speakerCount: nil).isEmpty)
    }

    @Test func 一句_一组() {
        #expect(SentenceClustering.cluster([item(0, 5)], speakerCount: nil) == [0])
    }

    @Test func 两个人轮流说_分成两组_组号按第一次出现编号() {
        let items = [item(3, 5), item(1, 4), item(3, 6, jitter: 1), item(1, 3, jitter: 2), item(3, 4, jitter: 3)]

        #expect(SentenceClustering.cluster(items, speakerCount: nil) == [0, 1, 0, 1, 0])
    }

    @Test func 平均相似度低于阈值时停止合并() {
        // 两个方向夹角的余弦是 0.5：阈值 0.4 时合并，0.6 时不合并
        let a = SentenceClustering.Item(vector: [1, 0], duration: 5)
        let b = SentenceClustering.Item(vector: [0.5, Float(0.75).squareRoot()], duration: 5)

        #expect(SentenceClustering.cluster([a, b], speakerCount: nil, threshold: 0.4) == [0, 0])
        #expect(SentenceClustering.cluster([a, b], speakerCount: nil, threshold: 0.6) == [0, 1])
    }

    @Test func 指定人数时合并到这么多组_不看阈值() {
        let items = [item(0, 5), item(1, 5), item(2, 5), item(3, 5)]

        #expect(Set(SentenceClustering.cluster(items, speakerCount: 2)).count == 2)
        #expect(Set(SentenceClustering.cluster([item(0, 5), item(0, 5, jitter: 1)], speakerCount: 2)).count == 2)
    }

    @Test func 指定人数多于长句数时每个长句一组() {
        let items = [item(0, 5), item(1, 5), item(1, 1)]

        #expect(SentenceClustering.cluster(items, speakerCount: 5) == [0, 1, 1])
    }

    @Test func 短句不参与聚类_归给最像的组() {
        // 短句自己一个方向（2），但不另成一组：归给更像它的 1 号人
        let short = SentenceClustering.Item(vector: [0, 0.6, 0.8, 0, 0, 0, 0, 0], duration: 1)
        let items = [item(0, 5), item(1, 5), short, item(0, 4, jitter: 1)]

        #expect(SentenceClustering.cluster(items, speakerCount: nil) == [0, 1, 1, 0])
    }

    @Test func 全是短句时都参与聚类() {
        let items = [item(0, 1), item(1, 1), item(0, 1.5, jitter: 1)]

        #expect(SentenceClustering.cluster(items, speakerCount: nil) == [0, 1, 0])
    }

    @Test func 平均链接_看两组所有句子对的平均而不是最像的一对() {
        // a1·b = 0.9 先并；a2 与 a1 是 0.6、与 b 是 0.54，平均 0.57。
        // 只看最像的一对（0.6）的话阈值 0.58 也会并进来；平均链接不并
        let a1 = SentenceClustering.Item(vector: [1, 0, 0], duration: 5)
        let a2 = SentenceClustering.Item(vector: [0.6, 0, 0.8], duration: 5)
        let b = SentenceClustering.Item(vector: [0.9, Float(0.19).squareRoot(), 0], duration: 5)

        #expect(SentenceClustering.cluster([a1, a2, b], speakerCount: nil, threshold: 0.58) == [0, 1, 0])
        #expect(SentenceClustering.cluster([a1, a2, b], speakerCount: nil, threshold: 0.55) == [0, 0, 0])
    }
}
