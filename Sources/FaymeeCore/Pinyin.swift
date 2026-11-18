import Foundation

/// 读音相近的判断（转写纠错护栏规则 3）：两边转成不带声调的拼音，按字母算编辑距离比
public enum Pinyin {
    /// 不带声调的拼音，连写、小写、去掉空白。用系统的 `CFStringTransform`（汉字转拉丁字母再去声调），
    /// 英文原样（只转小写）。多音字按系统的默认读音，如「长度」是 zhangdu
    public static func key(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).lowercased().filter { !$0.isWhitespace }
    }

    /// 两段文字拼音的编辑距离 ÷ 较长一边的字母数，0 表示读音相同。两边都空时为 0
    public static func distanceRatio(_ a: String, _ b: String) -> Double {
        let x = Array(key(a)), y = Array(key(b))
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 0 }
        return Double(levenshtein(x, y)) / Double(longest)
    }
}

/// 编辑距离（插入、删除、替换各算 1）
func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
    guard !a.isEmpty else { return b.count }
    guard !b.isEmpty else { return a.count }
    var previous = Array(0...b.count)
    var current = previous
    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            current[j] = a[i - 1] == b[j - 1]
                ? previous[j - 1]
                : 1 + min(previous[j - 1], previous[j], current[j - 1])
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}
