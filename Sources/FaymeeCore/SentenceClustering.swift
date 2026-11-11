import Accelerate
import Foundation

/// 逐句声纹聚类：每句一个声纹，把声音相近的句子归成同一个人。
///
/// - 长于 `anchorDuration` 的句子做平均链接层次聚类（两组的相似度 = 两组所有句子两两余弦相似度的平均），
///   自动判断人数时合并到最像的两组也低于 `threshold` 为止，指定人数时合并到剩这么多组为止
/// - 更短的句子声纹不稳，不参与聚类，归给最像的组（组中心是组内句子声纹按时长加权的平均）
/// - 全是短句时都参与聚类
///
/// 依据和参数见 ticket 12、13：在真实远场会议上，比 pyannote 分段 + 整段聚类既少拆碎也少混人
public enum SentenceClustering {
    /// 自动判断人数时的停止阈值（平均余弦相似度，越低判出的人越少）。ERes2Net 声纹下在 2 个样例和
    /// 3 场有在场人数的真实录音上校过：低于 0.26 时 10:59 那场开始把不同的人并到一起，高于 0.29 时
    /// 08:58 那场超过在场人数。暂定值
    public static let defaultThreshold = 0.27
    /// 参与层次聚类的句子最短时长（秒）
    public static let anchorDuration: TimeInterval = 2

    public struct Item: Sendable {
        public var vector: [Float]
        public var duration: TimeInterval

        public init(vector: [Float], duration: TimeInterval) {
            self.vector = vector
            self.duration = duration
        }
    }

    /// 每句的组号，从 0 起，按第一次出现的先后编号。声纹全是同一维数
    public static func cluster(_ items: [Item], speakerCount: Int?,
                               threshold: Double = defaultThreshold) -> [Int] {
        guard !items.isEmpty else { return [] }
        let dim = items[0].vector.count
        let unit = items.map { normalized($0.vector.map(Double.init)) }

        var anchors = items.indices.filter { items[$0].duration >= anchorDuration }
        if anchors.isEmpty { anchors = Array(items.indices) }
        let m = anchors.count

        // 合并记录按相似度从高到低应用。平均链接没有倒挂，按这个顺序用并查集截取，与贪心逐步合并的结果相同
        let merges = averageLinkage(anchors.map { unit[$0] }, dim: dim).sorted { $0.similarity > $1.similarity }
        let applied = speakerCount.map { max(0, m - max(1, $0)) }
            ?? merges.prefix { $0.similarity >= threshold }.count
        var parent = Array(0..<m)
        func root(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for merge in merges.prefix(applied) {
            parent[root(merge.a)] = root(merge.b)
        }

        // 组：按根编号；组中心按时长加权
        var group: [Int: Int] = [:]
        var label = [Int](repeating: -1, count: items.count)
        for (k, i) in anchors.enumerated() {
            let r = root(k)
            let g = group[r] ?? group.count
            group[r] = g
            label[i] = g
        }
        var centers = [[Double]](repeating: [Double](repeating: 0, count: dim), count: group.count)
        for i in anchors {
            for d in 0..<dim { centers[label[i]][d] += unit[i][d] * items[i].duration }
        }
        centers = centers.map(normalized)
        for i in items.indices where label[i] < 0 {
            var best = (group: 0, similarity: -Double.infinity)
            for (g, c) in centers.enumerated() {
                let s = dot(c, unit[i])
                if s > best.similarity { best = (g, s) }
            }
            label[i] = best.group
        }

        // 按第一次出现重新编号
        var renumber: [Int: Int] = [:]
        return label.map { g in
            let n = renumber[g] ?? renumber.count
            renumber[g] = n
            return n
        }
    }

    struct Merge {
        /// 合并的两组各自的一个成员（anchors 里的下标）
        var a: Int
        var b: Int
        var similarity: Double
    }

    /// 平均链接层次聚类，用最近邻链（nearest-neighbor chain）算法：O(n²) 时间和内存。
    /// 返回全部 n-1 次合并，顺序不保证按相似度
    static func averageLinkage(_ vectors: [[Double]], dim: Int) -> [Merge] {
        let n = vectors.count
        guard n > 1 else { return [] }
        // 相似度矩阵 S = X·Xᵀ
        let x = vectors.flatMap { $0 }
        var xt = [Double](repeating: 0, count: n * dim)
        vDSP_mtransD(x, 1, &xt, 1, vDSP_Length(dim), vDSP_Length(n))
        var s = [Double](repeating: 0, count: n * n)
        vDSP_mmulD(x, 1, xt, 1, &s, 1, vDSP_Length(n), vDSP_Length(n), vDSP_Length(dim))

        var size = [Double](repeating: 1, count: n)
        var active = [Bool](repeating: true, count: n)
        var remaining = n
        var chain: [Int] = []
        var merges: [Merge] = []
        merges.reserveCapacity(n - 1)
        var nextStart = 0
        while remaining > 1 {
            if chain.isEmpty {
                while !active[nextStart] { nextStart += 1 }
                chain.append(nextStart)
            }
            let a = chain[chain.count - 1]
            // 最像的一组；与链上前一个一样像时选前一个，保证链会终止
            var best = -1, bestSimilarity = -Double.infinity
            if chain.count >= 2 {
                best = chain[chain.count - 2]
                bestSimilarity = s[a * n + best]
            }
            for k in 0..<n where active[k] && k != a && s[a * n + k] > bestSimilarity {
                best = k
                bestSimilarity = s[a * n + k]
            }
            guard chain.count >= 2, best == chain[chain.count - 2] else {
                chain.append(best)
                continue
            }
            chain.removeLast(2)
            merges.append(Merge(a: a, b: best, similarity: bestSimilarity))
            // 新组放在 a 的位置：与其余每组的平均相似度按两组大小加权（Lance–Williams）
            let total = size[a] + size[best]
            for k in 0..<n where active[k] && k != a && k != best {
                let v = (size[a] * s[a * n + k] + size[best] * s[best * n + k]) / total
                s[a * n + k] = v
                s[k * n + a] = v
            }
            size[a] = total
            active[best] = false
            remaining -= 1
        }
        return merges
    }

    private static func normalized(_ v: [Double]) -> [Double] {
        let norm = dot(v, v).squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }
}
