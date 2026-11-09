import Foundation

/// 转写稿与回放联动、复制用到的纯逻辑，界面只负责展示
extension Transcript {
    /// 播放到 time 秒时应高亮的条目（items 的下标）：
    /// - time 所在的那条；同时落在几条里（句子伸进空白）取开始最晚的
    /// - 落在两条之间（停顿）或最后一条之后：保持刚结束的那条，免得高亮在停顿处一闪一闪。
    ///   按结束时间而不是下标取，因为句子中间可能插着长度为 0 的空白
    /// - 第一条之前为 nil
    ///
    /// 播放时每 0.25 秒调用一次，不分配内存：items 按开始时间排序（assemble 排好，编辑不改时间），
    /// 二分找出已开始的那些，再从后往前找
    public func itemIndex(at time: TimeInterval) -> Int? {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].start <= time { lo = mid + 1 } else { hi = mid }
        }
        // 已开始的是 0..<lo。从后往前，第一条包含 time 的就是开始最晚的；
        // 都不包含时取结束最晚的，结束时间相同取下标大的
        var latestEnd: Int?
        for i in stride(from: lo - 1, through: 0, by: -1) {
            if time < items[i].end { return i }
            if latestEnd.map({ items[i].end > items[$0].end }) ?? true { latestEnd = i }
        }
        return latestEnd
    }

    /// 复制用的纯文本：一条一行，行首是方括号里的开始时间（`mm:ss` 或 `h:mm:ss`），
    /// 方括号免得和以数字开头的句子粘在一起
    public var plainText: String {
        items.map { item in
            let text = switch item {
            case let .sentence(s): s.text
            case let .gap(g): g.label
            }
            return "[\(formatDuration(item.start))] \(text)"
        }
        .joined(separator: "\n")
    }
}

extension TranscriptGap {
    /// 转写稿里空白那一行的文字，如“合盖，未录到声音（10:00–13:00，03:00）”
    public var label: String {
        let range = "\(formatDuration(start))–\(formatDuration(end))，\(formatDuration(end - start))"
        return switch reason {
        case .lidClosed: "合盖，未录到声音（\(range)）"
        }
    }
}
