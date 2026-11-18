import Testing
@testable import FaymeeCore

/// 用例来自真实会议上 Fun-ASR-Nano 的输出（评估数据里的片段）
@Suite struct ASROutputGuardTests {
    @Test(arguments: [
        // 同一单元连续 ≥ 8 次（在中间）
        "我我我我我我我我我我我我我我我我我我我。大伟的意思是说你们问打的时候",
        "我们对对其实其实其实其实其实其实其实其实其实其实。现在刚才呈现的意思是",
        "不是不是不是不是不是不是不是不是还不是啊还不是",
        // 带标点的单元
        "有一点点，没有，就用这个，就用这个，就用这个，就用这个，就用这个，就用这个，就用这个，就用这个，就用这",
        // 末尾连续 ≥ 5 次
        "你要把这个整出来，这个啊，这个这个这个这个这个这个这个。",
        "那就麻烦你们了，哎呀，那那那那那那那那那。",
        "那那那那那",
    ])
    func 失控复读判为复读(_ text: String) {
        #expect(ASROutputGuard.isRunaway(text))
    }

    @Test(arguments: [
        // 真实口吃
        "到不不不不不啊，也是",
        "我觉得不是不是不是不是不是，还是要再看看",
        "这个这个。",
        "好像可以可以搞，可以搞，把这个智能体工具",
        // 数字不算复读
        "预算一共是100000",
        "电话是13800000000，",
        "哈哈哈哈",
    ])
    func 口吃和正常输出不误判(_ text: String) {
        #expect(!ASROutputGuard.isRunaway(text))
    }

    @Test(arguments: [
        ("嗯，我我我我我我我我我我我我我我我我我我我我我我我我。", "嗯，我我我。"),
        ("你要把这个整出来，这个啊，这个这个这个这个这个这个这个。", "你要把这个整出来，这个啊，这个这个这个。"),
        // 带标点的单元：标点跟着单元一起删，末尾没写完的半个单元也删
        ("没有，就用这个，就用这个，就用这个，就用这个，就用这个，就用这个，就用这个，就用这个，就用这",
         "没有，就用这个，就用这个，就用这个，"),
        // 中间的失控段截掉后，后面的内容保留；口吃（不到失控）不动
        ("我们对对其实其实其实其实其实其实其实其实其实其实。到不不不不不啊，现在",
         "我们对对其实其实其实。到不不不不不啊，现在"),
        ("行，咱有事咱有事咱有事。那就麻烦你们了，哎呀，那那那那那那那那那。",
         "行，咱有事咱有事咱有事。那就麻烦你们了，哎呀，那那那。"),
        ("没有复读的文字", "没有复读的文字"),
    ])
    func 失控的连续重复截到3次(_ text: String, _ expected: String) {
        #expect(ASROutputGuard.truncateRepeats(text) == expected)
        #expect(!ASROutputGuard.isRunaway(ASROutputGuard.truncateRepeats(text)))
    }

    @Test(arguments: [
        ("咱有事咱有事。 /sil 那就麻烦你们了", "咱有事咱有事。那就麻烦你们了"),
        ("[breath]然后我们看一下", "然后我们看一下"),
        ("好的 [breath] 下一个", "好的下一个"),
        ("调 agent [breath] 的这些", "调 agent 的这些"),
        ("用 LangChain /sil Agent 搭", "用 LangChain Agent 搭"),
        ("<|im_end|>", ""),
        ("调 agent 的这些，DeerFlow 和 LangChain", "调 agent 的这些，DeerFlow 和 LangChain"),
    ])
    func 删掉标记(_ text: String, _ expected: String) {
        #expect(ASROutputGuard.clean(text) == expected)
    }

    @Test func 判出日文和提示词泄漏_英文和数字不算() {
        #expect(ASROutputGuard.problem(in: "やるぞ！") == .foreign)
        #expect(ASROutputGuard.problem(in: "ええ、あ、このように集中したのかな、この。") == .foreign)
        #expect(ASROutputGuard.problem(in: "あんまりないですね。") == .foreign)
        #expect(ASROutputGuard.problem(in: "안녕하세요") == .foreign)
        // Qwen3-ASR 在一段 0.9 秒的「嗯」上输出过俄文字母
        #expect(ASROutputGuard.problem(in: "стьы") == .foreign)
        // 实时字幕定稿实测（10:38）：Fun-ASR-Nano 把短句「别的」转成「彼の話」，只有 1 个假名
        #expect(ASROutputGuard.problem(in: "彼の話") == .foreign)
        #expect(ASROutputGuard.problem(in: "はい。") == .foreign)
        #expect(ASROutputGuard.problem(in: "system") == .promptLeak)
        #expect(ASROutputGuard.problem(in: "热词列表：[DeerFlow, LangChain]") == .promptLeak)
        #expect(ASROutputGuard.problem(in: "那那那那那那那那那。") == .runaway)
        for ok in ["OK。", "LangChain", "7月2号交付，预算100000", "好的，那我们就这样定了。", "这个系统要上线", "",
                   "我们要做语音转写，热词列表也要支持",
                   // 中文里偶尔夹一个「の」不算；和日文共用的汉字不算
                   "这是我の书", "这个の那个", "彼此的话", "話題",
                   // 一个假名夹在英文里：只数非 ASCII 字时它占了全部，但整句并不短
                   "LangChain の", "用 Agent の"] {
            #expect(ASROutputGuard.problem(in: ok) == nil, "\(ok)")
        }
    }

    /// 对半重转的两半在中点各多带 0.2 秒，交界处的字常被两半各识别一遍（真实输出）
    @Test(arguments: [
        ("掉下面的一些小的什么，你现在这些是不在，就是", "就是室内网的还是就是自自己联系的，我这。",
         "掉下面的一些小的什么，你现在这些是不在，就是室内网的还是就是自自己联系的，我这。"),
        ("我是说最终的，就说你们去给。", "去给客户交付，哎，做售后服务。", "我是说最终的，就说你们去给客户交付，哎，做售后服务。"),
        ("你要把这个整出来，这个啊，这个。", "这个东西，这个东西这个。", "你要把这个整出来，这个啊，这个东西，这个东西这个。"),
        // 没有重复的字：原样接上
        ("嗯，我们现在大模型训练，这个这个模型其实还是挺难的。", "我们这只是应用层。",
         "嗯，我们现在大模型训练，这个这个模型其实还是挺难的。我们这只是应用层。"),
        ("看前面这都在群里面。", "", "看前面这都在群里面。"),
        ("", "那就麻烦你们了。", "那就麻烦你们了。"),
        // 英文之间留空格
        ("我们用的是", "LangChain 和 Agent。", "我们用的是LangChain 和 Agent。"),
        ("我们用的是 DeerFlow", "LangChain 和 Agent。", "我们用的是 DeerFlow LangChain 和 Agent。"),
    ])
    func 两半拼起来时去掉交界处重复的字(_ first: String, _ second: String, _ expected: String) {
        #expect(ASROutputGuard.joinHalves(first, second) == expected)
    }

    /// Qwen3-ASR（带 8 个热词）在真实会议上的输出：一整句话反复说到输出上限
    private let phraseLoop = "每一个模型，然后在端到端的这个研发，然后在端到端的这个研发，然后在端到端的这个研发，"
        + "然后在端到端的这个研发，然后在端到端的这个研发，然后在端到端"

    @Test func 五字以上的整句连续重复4次也算复读() {
        #expect(ASROutputGuard.isRunaway(phraseLoop))
        #expect(ASROutputGuard.truncateRepeats(phraseLoop)
            == "每一个模型，然后在端到端的这个研发，然后在端到端的这个研发，然后在端到端的这个研发，")
        // 3 次以内的整句重复是正常说话
        #expect(!ASROutputGuard.isRunaway("我知道了我知道了我知道了。然后在端到端的这个研发，然后在端到端的这个研发，"
            + "然后在端到端的这个研发。"))
    }

    /// Qwen3-ASR 把热词放在提示词的 system 段（空格连接），会把整串热词当成转写结果输出（真实输出）
    private let hotwords = ["DeerFlow", "LangChain", "Harness", "Agent", "智能体", "工具广场", "模型广场", "端到端研发"]

    @Test func 输出连着三个以上按热词表顺序的热词算提示词泄漏() {
        let leaks = ["DeerFlow LangChain Harness Agent 智能体 工具广场 模型广场 端到端研发。",
                     "DeerFlow LangChain Harness Agent 智能体 工具广场 模型广场 端到端研发。那你既然是TR，那么你就要把你们主的。",
                     "智能体、工具广场、模型广场"]
        for text in leaks {
            #expect(ASROutputGuard.problem(in: text, hotwords: hotwords) == .promptLeak, "\(text)")
            #expect(ASROutputGuard.problem(in: text) == nil)
        }
        // 会上说到热词、说到两个连着的热词都正常；热词不到 3 个不判
        for ok in ["我们用 DeerFlow 和 LangChain 搭 Agent", "模型广场、工具广场都有", "LangChain Harness 这些",
                   "创建智能体，然后去工具广场"] {
            #expect(ASROutputGuard.problem(in: ok, hotwords: hotwords) == nil, "\(ok)")
        }
        #expect(ASROutputGuard.problem(in: "DeerFlow LangChain", hotwords: ["DeerFlow", "LangChain"]) == nil)
    }

    @Test(arguments: [
        ("嗯，我我我我我我我我我我我我我我我我我我我我我我我我。", "嗯，我我我。"),
        ("やるぞ！", ""),
        ("system", ""),
        ("好的。", "好的。"),
    ])
    func 重转后仍有问题时的兜底_复读截短_日文和泄漏丢掉(_ text: String, _ expected: String) {
        #expect(ASROutputGuard.salvage(text) == expected)
    }
}
