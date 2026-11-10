import Testing
@testable import FaymeeCore

/// 02 解析模型给的 dueDate 时用 `CalendarDate(_:)`，不合法就置空
@Suite struct CalendarDateTests {
    @Test func 解析合法日期() {
        let d = CalendarDate("2026-11-18")
        #expect(d?.year == 2026 && d?.month == 11 && d?.day == 18)
        #expect(d?.description == "2026-11-18")
        #expect(CalendarDate("2028-02-29") != nil)
        #expect(CalendarDate("2000-02-29") != nil)
    }

    @Test(arguments: ["2026-02-29", "1900-02-29", "2026-04-31", "2026-13-01", "2026-00-10", "2026-11-00",
                      "2026-1-18", "26-11-18", "2026/11/18", "2026-11-18T00:00:00Z", "下周三", "",
                      "２０２６-11-18", "+026-11-18"])
    func 不合法时为nil(_ s: String) {
        #expect(CalendarDate(s) == nil)
    }
}
