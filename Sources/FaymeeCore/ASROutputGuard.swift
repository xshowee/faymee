import Foundation

/// 大模型类 ASR（Fun-ASR-Nano、Qwen3-ASR）输出的检查与清理，纯函数。
///
/// 这类模型偶尔失控：同一个 1–4 字的单元连续重复十几到几十次（常常直到段尾，后面的内容丢掉），
/// 或者输出日文、输出提示词。这里只判断和清理文字；对半重转在 `GuardedRecognizer`。
///
/// 复读按“字”算：标点和空白不算字（「就用这个，就用这个，」的单元是「就用这个」），全是数字的单元不算
/// （「100000」「13800000000」是正常输出）。Qwen3-ASR 还会把 5 个字以上的整句一直重复到输出上限
public enum ASROutputGuard {
    /// 同一单元在任何位置连续重复这么多次算失控
    static let runawayRepeats = 8
    /// 输出末尾连续重复这么多次算失控（生成停不下来，一直重复到上下文用完）
    static let trailingRepeats = 5
    /// 单元最长几个字
    static let maxUnit = 4
    /// 长单元（5–20 个字的整句）连续重复这么多次算失控。正常说话很少把同一整句连说 4 遍
    static let phraseRepeats = 4
    static let maxPhraseUnit = 20

    /// 是否失控复读：1–4 字的单元连续重复 ≥ 8 次，或输出末尾连续重复 ≥ 5 次（末尾可以多一个没写完的单元）；
    /// 5–20 字的整句连续重复 ≥ 4 次。真实口吃（「不不不不不啊」「这个这个。」）不算
    public static func isRunaway(_ text: String) -> Bool {
        !runawayRuns(in: Array(text).filter(isContent)).isEmpty
    }

    /// 截短后保留几次
    static let keptRepeats = 3

    /// 把失控的连续重复截到 3 次（对半重转后仍复读时用）。删掉的单元连同夹在中间的标点一起删，
    /// 连续段后面的标点和内容保留；不到失控的重复（口吃）不动
    public static func truncateRepeats(_ text: String) -> String {
        let characters = Array(text)
        let contentPositions = characters.indices.filter { isContent(characters[$0]) }
        let runs = runawayRuns(in: contentPositions.map { characters[$0] })
        guard !runs.isEmpty else { return text }
        var drop = IndexSet()
        for run in runs {
            let first = run.start + run.unit * keptRepeats
            guard first < run.end else { continue }
            drop.insert(integersIn: contentPositions[first]...contentPositions[run.end - 1])
        }
        return String(characters.indices.filter { !drop.contains($0) }.map { characters[$0] })
    }

    // MARK: - 复读的连续段

    /// 一段连续重复：从第 `start` 个字起，`unit` 个字一单元，连续 `count` 次
    struct Run: Equatable {
        var start: Int
        var unit: Int
        var count: Int
        /// 末尾多出的、没写完的半个单元（只在连续段一直到结尾时算）
        var tail: Int
        var end: Int { start + unit * count + tail }
    }

    /// 所有失控的连续段（按出现顺序，不重叠）。同一起点取覆盖最长的单元，一样长取短单元
    static func runawayRuns(in chars: [Character]) -> [Run] {
        var runs: [Run] = []
        var i = 0
        while i < chars.count {
            var best: Run?
            for unit in 1...maxPhraseUnit where i + unit * 2 <= chars.count {
                let pattern = chars[i..<(i + unit)]
                guard !pattern.allSatisfy(\.isNumber) else { continue }
                var count = 1
                while i + unit * (count + 1) <= chars.count,
                      chars[(i + unit * count)..<(i + unit * (count + 1))] == pattern {
                    count += 1
                }
                let after = i + unit * count
                let rest = chars.count - after
                let tail = rest < unit && chars[after...].elementsEqual(pattern.prefix(rest)) ? rest : 0
                let atEnd = after + tail == chars.count
                let isRunaway = unit <= maxUnit
                    ? count >= runawayRepeats || (atEnd && count >= trailingRepeats)
                    : count >= phraseRepeats
                guard isRunaway else { continue }
                let run = Run(start: i, unit: unit, count: count, tail: atEnd ? tail : 0)
                if best.map({ run.unit * run.count > $0.unit * $0.count }) ?? true { best = run }
            }
            if let best {
                runs.append(best)
                i = best.end
            } else {
                i += 1
            }
        }
        return runs
    }

    /// 算不算“字”：标点、空白以外的字符
    static func isContent(_ c: Character) -> Bool {
        !c.isWhitespace && !c.isPunctuation && !c.isSymbol
    }

    // MARK: - 其他异常

    public enum Problem: Equatable, Sendable {
        /// 失控复读
        case runaway
        /// 整段不是中文（偶发的日文、韩文、俄文输出）
        case foreign
        /// 输出了提示词（如单独的「system」、热词列表）
        case promptLeak
    }

    /// 输出有没有问题（先 `clean`）。有问题的段对半重转
    /// - Parameter hotwords: 交给模型的热词（拼进了提示词），用来认出整串热词的泄漏（Qwen3-ASR 据此不带热词重转）
    public static func problem(in text: String, hotwords: [String] = []) -> Problem? {
        if isPromptLeak(text) || isHotwordLeak(text, hotwords: hotwords) { return .promptLeak }
        if isForeign(text) { return .foreign }
        if isRunaway(text) { return .runaway }
        return nil
    }

    /// 重转后仍有问题时的兜底：复读截到 3 次；日文、提示词泄漏整段丢掉
    public static func salvage(_ text: String) -> String {
        switch problem(in: text) {
        case nil: text
        case .runaway: truncateRepeats(text)
        case .foreign, .promptLeak: ""
        }
    }

    /// 假名、谚文、西里尔字母占（不算 ASCII 的）字的三成以上。中文里偶尔夹一个「の」不算；英文、数字不算
    static func isForeign(_ text: String) -> Bool {
        let chars = text.unicodeScalars.filter { $0.value > 0x7F && isContent(Character($0)) }
        let foreign = chars.filter { s in
            switch s.value {
            case 0x3041...0x3096, 0x30A1...0x30FA, 0x31F0...0x31FF, // 平假名、片假名（不含长音符「ー」）
                 0x1100...0x11FF, 0x3131...0x318E, 0xAC00...0xD7A3, // 谚文
                 0x0400...0x04FF: true // 西里尔字母（Qwen3-ASR 偶尔输出俄文）
            default: false
            }
        }
        return foreign.count >= 2 && foreign.count * 10 >= chars.count * 3
    }

    /// 提示词里的固定片段（Fun-ASR-Nano：「语音转写：」「热词列表：[…]」；Qwen3-ASR：单独的 system / user）。
    /// 带冒号、括号，免得会上真说到「语音转写」「热词」时误判
    private static let promptFragments = ["语音转写：", "语音转写成中文：", "热词列表：", "上下文信息：",
                                          "helpful assistant", "im_start", "im_end"]
    private static let chatRoles: Set<String> = ["system", "user", "assistant"]

    static func isPromptLeak(_ text: String) -> Bool {
        let lower = text.lowercased()
        if promptFragments.contains(where: lower.contains) { return true }
        return chatRoles.contains(String(lower.filter(isContent)))
    }

    /// 输出里连着出现热词表中相邻的 3 个热词（按表的顺序，忽略中间的空格、标点、大小写，合起来至少 6 个字）：
    /// 模型把提示词里的热词串当成了转写结果（Qwen3-ASR 把热词用空格连接放在 system 段）。
    /// 会上说到一两个热词、或不按表的顺序说到几个热词不算
    static func isHotwordLeak(_ text: String, hotwords: [String]) -> Bool {
        let words = hotwords.map { String($0.lowercased().filter(isContent)) }.filter { !$0.isEmpty }
        guard words.count >= 3 else { return false }
        let content = String(text.lowercased().filter(isContent))
        return (0...(words.count - 3)).contains { i in
            let run = words[i..<(i + 3)].joined()
            return run.count >= 6 && content.contains(run)
        }
    }

    // MARK: - 对半重转后拼接

    /// 交界处最多去掉几个重复的字（两半在中点各多带 0.2 秒，共 0.4 秒，快的时候约两三个字）
    static let maxSeamOverlap = 4

    /// 把对半重转的两半接起来：前一半末尾和后一半开头相同的字（最多 4 个，不算标点）是交界处被识别了两遍的，
    /// 去掉后一半里的那几个字和前一半末尾的标点（「你们去给。」+「去给客户交付」→「你们去给客户交付」）。
    /// 两边都是英文或数字时中间留一个空格
    public static func joinHalves(_ first: String, _ second: String) -> String {
        let a = Array(first), b = Array(second)
        let tail = a.filter(isContent), head = b.filter(isContent)
        var left = first, right = second
        for k in stride(from: min(maxSeamOverlap, tail.count, head.count), through: 1, by: -1)
        where tail.suffix(k).elementsEqual(head.prefix(k)) {
            // 后一半去掉开头的 k 个字（连同夹在中间的标点、空白），前一半去掉末尾的标点
            var seen = 0
            let cut = b.firstIndex { c in
                if isContent(c) { seen += 1 }
                return seen == k
            }!
            right = String(b[(cut + 1)...])
            left = String(a[..<(a.lastIndex(where: isContent)! + 1)])
            break
        }
        if let l = left.last, let r = right.first, isLatin(l), isLatin(r) { return left + " " + right }
        return left + right
    }

    // MARK: - 标记

    /// `[breath]`、`[laughter]` 这类方括号里的英文标记，`/sil`，`<|im_end|>` 这类特殊 token；连同两边的空白一起匹配
    private static let marker = try! NSRegularExpression(
        pattern: #"\s*(?:\[[A-Za-z_ ]+\]|/sil\b|<\|[^|>]*\|>)\s*"#)

    /// 删掉模型输出里的标记。标记两边原来有空格、且有一边是英文或数字时留一个空格（模型在中英文之间加空格：
    /// 「调 agent [breath] 的」→「调 agent 的」），否则不留（「好的 [breath] 下一个」→「好的下一个」）
    public static func clean(_ text: String) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in marker.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = match.range
            result += ns.substring(with: NSRange(location: last, length: r.location - last))
            let after = r.location + r.length < ns.length
                ? ns.substring(with: NSRange(location: r.location + r.length, length: 1)).first : nil
            let hadSpace = ns.substring(with: r).first?.isWhitespace == true
                || ns.substring(with: r).last?.isWhitespace == true
            if hadSpace, let before = result.last, let after, isLatin(before) || isLatin(after) {
                result += " "
            }
            last = r.location + r.length
        }
        result += ns.substring(from: last)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLatin(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }
}
