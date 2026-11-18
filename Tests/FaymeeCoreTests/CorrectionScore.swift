@testable import FaymeeCore

/// 纠错评估的计分（ticket 04，spec「评估」的指标）：一份转写稿纠错前后对照标准稿。
///
/// - 字错率按字符算编辑距离，去掉标点、空白，拉丁字母转小写（转写模型的标点、空格跟标准稿不一样，不计）
/// - 转写稿的句子和标准稿的行对不齐，标准稿当一整段比；某一句的改动好坏 = 只应用这一句的改动时，
///   整份的编辑距离比改前多了还是少了（少了算改对，多了算改坏，不变算中性）
/// - `clean`：本来全对的稿子，任何修改（含只改标点）都算改坏
struct CorrectionScore {
    /// 标准稿字数（去掉标点、空白后）
    var referenceLength: Int
    var errorsBefore: Int
    var errorsAfter: Int
    /// 送进去的句子数
    var sentences: Int
    /// 文字有变化的句子数
    var changed = 0
    var improved = 0
    var broken = 0
    var neutral = 0
    /// 每句改动带来的编辑距离变化（负数是改对），只含有变化的句子，按句子下标
    var deltas: [Int: Int] = [:]

    init(before: [String], after: [String], reference: String, clean: Bool = false) {
        precondition(before.count == after.count)
        var alphabet: [Character: Int32] = [:]
        func encode(_ text: String) -> [Int32] {
            normalizedForScoring(text).map { c in
                if let code = alphabet[c] { return code }
                let code = Int32(alphabet.count)
                alphabet[c] = code
                return code
            }
        }
        let ref = encode(reference)
        let hyp = before.map(encode)
        sentences = before.count
        referenceLength = ref.count

        // forward[k][j]：前 k 句对标准稿前 j 个字的编辑距离；
        // backward[k][j]：第 k 句起的各句对标准稿第 j 个字起的后缀的编辑距离
        let m = ref.count
        let reversedRef = Array(ref.reversed())
        var forward = [(0...m).map(Int32.init)]
        for h in hyp { forward.append(advance(forward.last!, with: h, against: ref)) }
        var tails = [(0...m).map(Int32.init)]
        for h in hyp.reversed() { tails.append(advance(tails.last!, with: h.reversed(), against: reversedRef)) }
        // tails[n - k][m - j] 是第 k 句起对后缀 j 的距离
        func backward(_ k: Int, _ j: Int) -> Int32 { tails[hyp.count - k][m - j] }

        errorsBefore = Int(forward[hyp.count][m])
        var all = forward[0]
        for i in hyp.indices {
            let changedHere = after[i] != before[i]
            let encoded = changedHere ? encode(after[i]) : hyp[i]
            all = advance(all, with: encoded, against: ref)
            guard changedHere else { continue }
            let row = advance(forward[i], with: encoded, against: ref)
            let alone = (0...m).map { row[$0] + backward(i + 1, $0) }.min()!
            let delta = Int(alone) - errorsBefore
            deltas[i] = delta
            changed += 1
            if clean || delta > 0 {
                broken += 1
            } else if delta < 0 {
                improved += 1
            } else {
                neutral += 1
            }
        }
        errorsAfter = Int(all[m])
    }
}

/// 计分用的文字：去掉标点、空白，拉丁字母转小写
func normalizedForScoring(_ text: String) -> [Character] {
    text.lowercased().filter { !$0.isWhitespace && !TextDiff.isPunctuation(String($0)) }
}

/// 编辑距离的一行往下推：`row[j]` 是已处理的转写文字对 `reference` 前 j 个字的距离，再接上 `text`
private func advance(_ row: [Int32], with text: [Int32], against reference: [Int32]) -> [Int32] {
    var previous = row
    var current = [Int32](repeating: 0, count: row.count)
    for c in text {
        current.withUnsafeMutableBufferPointer { cur in
            previous.withUnsafeBufferPointer { prev in
                reference.withUnsafeBufferPointer { ref in
                    cur[0] = prev[0] + 1
                    for j in 1..<cur.count {
                        let substitute = prev[j - 1] + (ref[j - 1] == c ? 0 : 1)
                        cur[j] = min(substitute, prev[j] + 1, cur[j - 1] + 1)
                    }
                }
            }
        }
        swap(&previous, &current)
    }
    return previous
}
