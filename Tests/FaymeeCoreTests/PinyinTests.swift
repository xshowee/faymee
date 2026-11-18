import Testing
@testable import FaymeeCore

/// 拼音编辑距离比：spec「护栏」规则 3 的实算值
@Suite struct PinyinTests {
    @Test(arguments: [
        ("对动", "被动", 0.29), ("工会上", "工位上", 0.17), ("端道的", "端到端", 0.27),
        ("公老师", "龚老师", 0.0), ("long chain", "LangChain", 0.11), ("自然体", "智能体", 0.44),
        ("十月", "四月", 0.17), ("重庆", "重要", 0.56),
    ])
    func 拼音编辑距离比同spec实算(before: String, after: String, expected: Double) {
        let ratio = Pinyin.distanceRatio(before, after)
        #expect(abs(ratio - expected) < 0.005, "\(before)→\(after) = \(ratio)")
    }

    @Test func 转成不带声调的拼音_英文转小写去空格() {
        #expect(Pinyin.key("被动") == "beidong")
        #expect(Pinyin.key("Long Chain") == "longchain")
    }

    @Test func 两边都空时比为零() {
        #expect(Pinyin.distanceRatio("", "") == 0)
    }
}
