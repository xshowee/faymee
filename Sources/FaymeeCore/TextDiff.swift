import Foundation

/// 纠错前后一句文字的字符级比对，切成若干处「替换 / 补字 / 删字」，标点单独成一处（spec「输入与输出」）。
/// 本机的换字词、在线的整句改写都先比对再逐处过护栏（`reviewCorrections`）；
/// 转写稿的下划线（ticket 02）也由纠错前后文字比对得出，用 `Segment.afterRange`。
///
/// 比对单位：汉字等每个字符一个单位，连续的英文字母、数字算一个单位（按词比，`long`→`Lang` 是一处替换，
/// 不是逐个字母）。一处改动里，从第一个到最后一个非标点单位之间的是一处文字改动（夹在中间的空格、标点也算进去），
/// 两头多出的标点、空白另成一处 `.punctuation`
public struct TextDiff: Sendable {
    public enum Kind: String, Sendable {
        /// 换字词：两边都有文字
        case replace
        /// 补字：原文没有，改后有
        case insert
        /// 删字：原文有，改后没有
        case delete
        /// 只动了标点或空白
        case punctuation
    }

    public struct Segment: Hashable, Sendable {
        public var kind: Kind
        /// 原文里被改掉的文字（补字时为空）
        public var before: String
        /// 改后的文字（删字时为空）
        public var after: String
        /// 在原文里的字符位置（`Character` 下标）。补字时是空区间，表示插在这里
        public var beforeRange: Range<Int>
        /// 在改后文字里的字符位置。删字时是空区间
        public var afterRange: Range<Int>
        /// 这一处包含的比对步骤（`ops` 下标），应用、扩展时用
        let ops: [Int]
    }

    public let before: String
    public let after: String
    /// 按位置排列
    public let segments: [Segment]
    let ops: [Op]

    struct Op: Hashable, Sendable {
        enum Kind: Hashable, Sendable { case equal, delete, insert }
        var kind: Kind
        var token: String
        var isPunctuation: Bool
        /// 在原文 / 改后文字里的字符位置：equal 两边都有；delete 的 after、insert 的 before 是空区间
        var beforeRange: Range<Int>
        var afterRange: Range<Int>
    }

    public init(from before: String, to after: String) {
        self.before = before
        self.after = after
        ops = Self.diff(Self.tokens(before), Self.tokens(after))
        segments = Self.segments(ops)
    }

    /// 只应用选中的几处（必须是这份比对里的），其余保持原文
    public func applying(_ chosen: [Segment]) -> String {
        let picked = Set(chosen.flatMap(\.ops))
        var text = ""
        for (i, op) in ops.enumerated() {
            switch op.kind {
            case .equal: text += op.token
            case .delete: if !picked.contains(i) { text += op.token }
            case .insert: if picked.contains(i) { text += op.token }
            }
        }
        return text
    }

    /// 把一处向两边相邻的相同文字扩展，直到两边都至少 `minimum` 个单位（或碰到标点、别的改动、句首句尾），
    /// 先左后右交替，只扩到原文 `bounds`（字符位置）以内。拼音校验用它：「对动→被动」最小改动只是「对→被」，
    /// 单看一个字读音差很远
    func widened(_ segment: Segment, minimum: Int, within bounds: Range<Int>? = nil) -> (before: String, after: String) {
        guard var lo = segment.ops.min(), var hi = segment.ops.max() else { return (segment.before, segment.after) }
        func units() -> (Int, Int) {
            ops[lo...hi].reduce((0, 0)) { n, op in
                (n.0 + (op.kind == .insert ? 0 : 1), n.1 + (op.kind == .delete ? 0 : 1))
            }
        }
        func extendable(_ i: Int) -> Bool {
            guard ops.indices.contains(i), ops[i].kind == .equal, !ops[i].isPunctuation else { return false }
            guard let bounds else { return true }
            return bounds.lowerBound <= ops[i].beforeRange.lowerBound && ops[i].beforeRange.upperBound <= bounds.upperBound
        }
        var leftTurn = true
        while min(units().0, units().1) < minimum {
            let canLeft = extendable(lo - 1), canRight = extendable(hi + 1)
            guard canLeft || canRight else { break }
            if (leftTurn && canLeft) || !canRight { lo -= 1 } else { hi += 1 }
            leftTurn.toggle()
        }
        return text(lo...hi)
    }

    /// 数字建议的单元：先向两边并上紧挨着的、`attach` 认的相同文字（数字和「月」「点」这类单位），
    /// 原文一边为空或在原文里不止出现一次时，再在 `bounds` 里先左后右逐字扩，直到在原文里只出现一次。
    /// 采纳建议时把原文唯一的那处换掉（ticket 02），所以必须唯一；扩到头也不唯一时为 nil
    func suggestionUnit(_ segment: Segment, within bounds: Range<Int>?,
                        attach: (String) -> Bool) -> (before: String, after: String)? {
        guard var lo = segment.ops.min(), var hi = segment.ops.max() else { return nil }
        func extendable(_ i: Int) -> Bool {
            guard ops.indices.contains(i), ops[i].kind == .equal, !ops[i].isPunctuation else { return false }
            guard let bounds else { return true }
            return bounds.lowerBound <= ops[i].beforeRange.lowerBound && ops[i].beforeRange.upperBound <= bounds.upperBound
        }
        while extendable(lo - 1), attach(ops[lo - 1].token) { lo -= 1 }
        while extendable(hi + 1), attach(ops[hi + 1].token) { hi += 1 }
        var leftTurn = true
        while true {
            let unit = text(lo...hi)
            if !unit.before.isEmpty, before.occurrences(of: unit.before) == 1 { return unit }
            let canLeft = extendable(lo - 1), canRight = extendable(hi + 1)
            guard canLeft || canRight else { return nil }
            if (leftTurn && canLeft) || !canRight { lo -= 1 } else { hi += 1 }
            leftTurn.toggle()
        }
    }

    /// 改后文字里 `range` 所覆盖的比对步骤连同中间的改动，两边各是什么文字。
    /// 参考词校验用：改后命中参考词时，按整个参考词与对应的原文比拼音
    func span(coveringAfter range: Range<Int>) -> (before: String, after: String) {
        // 删掉的字在改后文字里是个插入点：落在范围里（含起点）就算，「自然→智能」里的「自然」也要带上
        let hit = ops.indices.filter { i in
            let r = ops[i].afterRange
            return ops[i].kind == .delete ? range.lowerBound <= r.lowerBound && r.lowerBound < range.upperBound
                : r.overlaps(range)
        }
        guard let lo = hit.min(), let hi = hit.max() else { return ("", "") }
        return text(lo...hi)
    }

    private func text(_ range: ClosedRange<Int>) -> (before: String, after: String) {
        ops[range].reduce(into: (before: "", after: "")) { t, op in
            if op.kind != .insert { t.before += op.token }
            if op.kind != .delete { t.after += op.token }
        }
    }

    // MARK: - 比对

    /// 比对单位：连续的 ASCII 字母数字合成一个，其余每个字符一个
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        for c in text {
            if c.isASCII && (c.isLetter || c.isNumber) {
                word.append(c)
            } else {
                if !word.isEmpty { tokens.append(word); word = "" }
                tokens.append(String(c))
            }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    static func isPunctuation(_ token: String) -> Bool {
        token.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
                || CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    /// 最长公共子序列比对。同一处里先删后补
    private static func diff(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        // lcs[i][j]：a[i...] 与 b[j...] 的最长公共子序列长度
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0, x = 0, y = 0
        func length(_ t: String) -> Int { t.count }
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                let k = length(a[i])
                ops.append(Op(kind: .equal, token: a[i], isPunctuation: isPunctuation(a[i]),
                              beforeRange: x..<x + k, afterRange: y..<y + k))
                i += 1; j += 1; x += k; y += k
            } else if i < n, j == m || lcs[i + 1][j] >= lcs[i][j + 1] {
                let k = length(a[i])
                ops.append(Op(kind: .delete, token: a[i], isPunctuation: isPunctuation(a[i]),
                              beforeRange: x..<x + k, afterRange: y..<y))
                i += 1; x += k
            } else {
                let k = length(b[j])
                ops.append(Op(kind: .insert, token: b[j], isPunctuation: isPunctuation(b[j]),
                              beforeRange: x..<x, afterRange: y..<y + k))
                j += 1; y += k
            }
        }
        return ops
    }

    /// 连续的非 equal 步骤是一处改动；其中第一个到最后一个非标点步骤之间是文字改动，两头的标点另成一处
    private static func segments(_ ops: [Op]) -> [Segment] {
        var segments: [Segment] = []
        var i = 0
        while i < ops.count {
            guard ops[i].kind != .equal else { i += 1; continue }
            var end = i
            while end < ops.count, ops[end].kind != .equal { end += 1 }
            let hunk = Array(i..<end)
            let content = hunk.filter { !ops[$0].isPunctuation }
            if let first = content.first, let last = content.last {
                let span = Array(first...last)
                let rest = hunk.filter { $0 < first || $0 > last }
                segments.append(make(span, ops))
                if !rest.isEmpty { segments.append(make(rest, ops, kind: .punctuation)) }
            } else {
                segments.append(make(hunk, ops, kind: .punctuation))
            }
            i = end
        }
        return segments.sorted { ($0.beforeRange.lowerBound, $0.ops[0]) < ($1.beforeRange.lowerBound, $1.ops[0]) }
    }

    private static func make(_ indices: [Int], _ ops: [Op], kind: Kind? = nil) -> Segment {
        let picked = indices.map { ops[$0] }
        let before = picked.filter { $0.kind == .delete }.map(\.token).joined()
        let after = picked.filter { $0.kind == .insert }.map(\.token).joined()
        let kind = kind ?? (before.isEmpty ? .insert : after.isEmpty ? .delete : .replace)
        func union(_ ranges: [Range<Int>]) -> Range<Int> {
            ranges.dropFirst().reduce(ranges[0]) { min($0.lowerBound, $1.lowerBound)..<max($0.upperBound, $1.upperBound) }
        }
        return Segment(kind: kind, before: before, after: after,
                       beforeRange: union(picked.map(\.beforeRange)), afterRange: union(picked.map(\.afterRange)),
                       ops: indices)
    }
}
