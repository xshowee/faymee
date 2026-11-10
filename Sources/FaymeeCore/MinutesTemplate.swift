import Foundation

/// 纪要模板：四个基本节之外的额外节，以及给模型的侧重提示。内置五个，不支持用户自定义
public struct MinutesTemplate: Hashable, Sendable, Identifiable {
    /// 模板额外定义的节，写盘时为 `kind: custom` + `key`
    public struct CustomSection: Hashable, Sendable {
        public let key: String
        public let title: String
        /// 告诉模型这一节记什么
        public let hint: String
    }

    /// 写进 `Minutes.template` 的标识
    public let key: String
    /// 界面上显示的名字
    public let name: String
    public let customSections: [CustomSection]
    /// 给模型的侧重提示，没有时为 nil
    public let focus: String?

    public var id: String { key }

    /// 纪要里各节的种类和标题，按显示顺序：四个基本节在前，额外的节在后
    public var sections: [(kind: MinutesSectionKind, title: String)] {
        [(.overview, "概要"), (.decisions, "决议"), (.actions, "待办"), (.questions, "未决问题")]
            + customSections.map { (.custom($0.key), $0.title) }
    }

    /// 按 `Minutes.template` 里的标识找内置模板，不认识时为 nil
    public init?(key: String) {
        guard let template = Self.all.first(where: { $0.key == key }) else { return nil }
        self = template
    }

    private init(key: String, name: String, customSections: [CustomSection], focus: String?) {
        self.key = key
        self.name = name
        self.customSections = customSections
        self.focus = focus
    }

    /// 内置模板，按界面上的显示顺序；第一个“通用”是默认，自动生成一律用它
    public static let all: [MinutesTemplate] = [general, weekly, customer, interview, review]

    public static let general = MinutesTemplate(key: "general", name: "通用", customSections: [], focus: nil)

    public static let weekly = MinutesTemplate(
        key: "weekly", name: "周会",
        customSections: [
            CustomSection(key: "progress", title: "各项进展", hint: "每项工作的当前进展，包括上周待办的完成情况。"),
        ],
        focus: "上周待办的完成情况、延期和风险。")

    public static let customer = MinutesTemplate(
        key: "customer", name: "客户拜访",
        customSections: [
            CustomSection(key: "requests", title: "客户诉求", hint: "客户提出的需求、问题和期望。"),
            CustomSection(key: "commitments", title: "我方承诺", hint: "我方答应客户要做的事、给出的报价或时间。"),
        ],
        focus: "客户提到的需求、预算、时间点，以及我方答应了什么。")

    public static let interview = MinutesTemplate(
        key: "interview", name: "面试",
        customSections: [
            CustomSection(key: "strengths", title: "候选人亮点", hint: "候选人表现好的地方，附上具体依据。"),
            CustomSection(key: "concerns", title: "顾虑", hint: "对候选人有疑虑的地方，附上具体依据。"),
            CustomSection(key: "recommendation", title: "结论建议",
                          hint: "面试官在会上明确说出的结论或建议；没有说出的不要写。"),
        ],
        focus: "只记录评价依据（候选人说了什么、做了什么），不替面试官下结论。")

    public static let review = MinutesTemplate(
        key: "review", name: "评审",
        customSections: [
            CustomSection(key: "issues", title: "问题清单",
                          hint: "评审中提出的每个问题，写明严重程度（如严重、一般、建议）和处理意见。"),
        ],
        focus: "每个问题的严重程度与处理意见。")
}
