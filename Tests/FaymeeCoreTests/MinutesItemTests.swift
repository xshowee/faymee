import Testing
@testable import FaymeeCore

@Suite struct MinutesItemTests {
    /// 模型给的出处都校验不过的条目保留下来，标为“未找到出处”；手动添加的条目本来就没有出处，不算
    @Test func 未找到出处() {
        #expect(MinutesItem(id: "d1", text: "推迟发布", refs: []).isUnsourced)
        #expect(!MinutesItem(id: "d1", text: "推迟发布", refs: [MinutesRef(id: "s3", start: 12)]).isUnsourced)
        #expect(!MinutesItem(id: "m1", text: "补一条", refs: [], origin: .manual).isUnsourced)
    }
}
