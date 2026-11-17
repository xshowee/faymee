import Testing
@testable import FaymeeCore

/// 按收到的样本范围（秒，相对整段录音）回答的识别器
private final class ScriptedRecognizer: SegmentRecognizer {
    /// 收到的每次请求：样本范围（秒）
    private(set) var calls: [Range<Double>] = []
    let answer: (Range<Double>) -> String

    init(answer: @escaping (Range<Double>) -> String) { self.answer = answer }

    func recognize(_ samples: ArraySlice<Float>) throws -> SegmentRecognition {
        let range = Double(samples.startIndex) / 16000..<Double(samples.endIndex) / 16000
        calls.append(range)
        return SegmentRecognition(text: answer(range), tokens: [.init(text: "x", start: 0)])
    }
}

@Suite struct GuardedRecognizerTests {
    /// 一段 60 秒的录音，取其中 [from, to) 秒交给识别器（切片下标不从 0 开始）
    private let recording = [Float](repeating: 0, count: 60 * 16000)
    private func clip(_ from: Double, _ to: Double) -> ArraySlice<Float> {
        recording[Int(from * 16000)..<Int(to * 16000)]
    }

    private let runaway = "我们现在这个这个这个这个这个这个这个这个这个这个这个这个这个"

    @Test func 正常输出原样交出() throws {
        let inner = ScriptedRecognizer { _ in "好的，那我们就这样定了。" }
        let result = try GuardedRecognizer(inner).recognize(clip(10, 18))
        #expect(result.text == "好的，那我们就这样定了。")
        #expect(result.tokens == [.init(text: "x", start: 0)])
        #expect(inner.calls.count == 1)
    }

    @Test func 删掉标记() throws {
        let inner = ScriptedRecognizer { _ in "好的 /sil 下一个" }
        #expect(try GuardedRecognizer(inner).recognize(clip(10, 18)).text == "好的下一个")
    }

    @Test func 失控复读时从中点切开_前后各多0点2秒分别重转() throws {
        let inner = ScriptedRecognizer { r in r.lowerBound == 10 && r.upperBound == 18 ? self.runaway
            : r.lowerBound == 10 ? "我们现在这个，" : "这个方案可以。" }
        let result = try GuardedRecognizer(inner).recognize(clip(10, 18))

        #expect(inner.calls.count == 3)
        #expect(abs(inner.calls[1].lowerBound - 10) < 1e-6 && abs(inner.calls[1].upperBound - 14.2) < 1e-6)
        #expect(abs(inner.calls[2].lowerBound - 13.8) < 1e-6 && abs(inner.calls[2].upperBound - 18) < 1e-6)
        // 交界处两半都识别出的「这个」只留一个
        #expect(result.text == "我们现在这个方案可以。")
        // 拼起来的文字没有对应的逐字时间
        #expect(result.tokens == nil)
    }

    @Test func 重转仍复读就截到3次_日文丢掉_只递归一层() throws {
        let inner = ScriptedRecognizer { r in r.lowerBound == 10 && r.upperBound == 18 ? self.runaway
            : r.lowerBound == 10 ? self.runaway : "やるぞ！" }
        let result = try GuardedRecognizer(inner).recognize(clip(10, 18))

        #expect(inner.calls.count == 3)
        #expect(result.text == "我们现在这个这个这个")
    }

    @Test func 日文和提示词泄漏也对半重转() throws {
        for bad in ["やるぞ！", "system"] {
            let inner = ScriptedRecognizer { r in
                r.upperBound - r.lowerBound > 5 ? bad : r.lowerBound == 10 ? "好的。" : "再见。"
            }
            #expect(try GuardedRecognizer(inner).recognize(clip(10, 18)).text == "好的。再见。")
            #expect(inner.calls.count == 3)
        }
    }

    @Test func Qwen3ASR单独输出system时按泄漏处理() throws {
        // 评估里 10:28 那场 01:08 一段 1.2 秒的话（补边后 1.8 秒），Qwen3-ASR 输出「system\n」：
        // 不到 2 秒不切，直接丢掉；长段对半重转见上一个测试
        let short = ScriptedRecognizer { _ in "system\n" }
        #expect(try GuardedRecognizer(short).recognize(clip(10, 11.8)).text == "")
        #expect(short.calls.count == 1)

        let long = ScriptedRecognizer { r in
            r.upperBound - r.lowerBound > 5 ? "system\n" : r.lowerBound == 10 ? "很多了。" : "好的。"
        }
        #expect(try GuardedRecognizer(long).recognize(clip(10, 18)).text == "很多了。好的。")
        #expect(long.calls.count == 3)
    }

    @Test func 不到2秒的短段不切_直接截短或丢掉() throws {
        let inner = ScriptedRecognizer { _ in self.runaway }
        #expect(try GuardedRecognizer(inner).recognize(clip(10, 11.5)).text == "我们现在这个这个这个")
        #expect(inner.calls.count == 1)

        // 评估里 1.22 秒的「那那那那那」：末尾 5 次够判复读，但短段没法重转核对，照原样留着（见下一个测试）
        let five = ScriptedRecognizer { _ in "那那那那那" }
        #expect(try GuardedRecognizer(five).recognize(clip(10, 11.22)).text == "那那那那那")

        let japanese = ScriptedRecognizer { _ in "あんまりないですね。" }
        #expect(try GuardedRecognizer(japanese).recognize(clip(10, 10.6)).text == "")
        #expect(japanese.calls.count == 1)
    }

    /// 真实口吃不能误判（spec）：短段（实时字幕定稿的一句常常不到 2 秒）以口吃结尾时，只够「末尾 ≥ 5 次」的
    /// 连续重复没法对半重转核对，不截；任何位置 ≥ 8 次的才是确定失控，照样截到 3 次
    @Test(arguments: [
        "到不不不不不",
        "我觉得不是不是不是不是不是",
        "就是这个这个这个这个这个。",
        "呃呃呃呃呃",
    ])
    func 短段以口吃结尾时不截短(_ stutter: String) throws {
        let inner = ScriptedRecognizer { _ in stutter }
        #expect(try GuardedRecognizer(inner).recognize(clip(10, 11.5)).text == stutter)
        #expect(inner.calls.count == 1)
    }

    @Test func 短段末尾重复到8次以上仍截到3次() throws {
        let inner = ScriptedRecognizer { _ in "那就麻烦你们了，哎呀，那那那那那那那那那。" }
        #expect(try GuardedRecognizer(inner).recognize(clip(10, 11.8)).text == "那就麻烦你们了，哎呀，那那那。")
    }
}
