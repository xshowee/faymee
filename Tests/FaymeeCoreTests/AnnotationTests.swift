import Foundation
import Testing
@testable import FaymeeCore

private let t0 = try! Date("2026-11-10T02:00:00Z", strategy: .iso8601)

/// 相对 t0 的墙钟时间
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func meeting() -> Meeting {
    Meeting(id: "m", title: "会议", startedAt: t0, status: .recording)
}

@Suite struct AnnotationIDTests {
    @Test func 按创建先后编号() {
        var m = meeting()
        #expect(m.nextAnnotationID == "a1")
        let a = m.addMark(at: at(10))
        let b = m.addNote("预算", at: at(20))
        #expect(a.id == "a1")
        #expect(b?.id == "a2")
        #expect(m.annotationList.map(\.id) == ["a1", "a2"])
        #expect(m.nextAnnotationID == "a3")
    }

    @Test func 删掉的编号不复用() {
        var m = meeting()
        m.addMark(at: at(10))
        m.addMark(at: at(20))
        m.deleteAnnotation("a2")
        let added = m.addMark(at: at(30))
        #expect(added.id == "a3")
    }

    @Test func 删光之后编号照样不复用() {
        var m = meeting()
        m.addMark(at: at(10))
        m.deleteAnnotation("a1")
        #expect(m.annotations == nil)
        let added = m.addMark(at: at(20))
        #expect(added.id == "a2")
    }

    /// 文件里有标注而没有记下的编号（手改过或更早的写法），新编号不和已有的撞
    @Test func 没有记下的编号时接着列表里最大的编号() {
        var m = meeting()
        m.annotations = [Annotation(id: "a4", at: at(10), kind: .mark)]
        let added = m.addMark(at: at(20))
        #expect(added.id == "a5")
    }

    @Test func 时间取到整秒() {
        var m = meeting()
        let added = m.addMark(at: at(10.9))
        #expect(added.at == at(10))
    }
}

@Suite struct AnnotationNoteTests {
    @Test func 笔记文字去掉首尾空白且换行换成空格() {
        var m = meeting()
        let note = m.addNote("  预算\n老王确认 \n", at: at(10))
        #expect(note?.text == "预算 老王确认")
        #expect(note?.kind == .note)
    }

    @Test func 空笔记不记() {
        var m = meeting()
        let note = m.addNote(" \n ", at: at(10))
        #expect(note == nil)
        #expect(m.annotations == nil)
        #expect(m.lastAnnotationNumber == nil)
    }

    @Test func 修改笔记文字() {
        var m = meeting()
        m.addNote("预算", at: at(10))
        let changed = m.editNote("a1", to: " 预算 → 老王确认\n")
        #expect(changed)
        #expect(m.annotationList == [Annotation(id: "a1", at: at(10), kind: .note, text: "预算 → 老王确认")])
    }

    @Test func 修改为空或不变时不改() {
        var m = meeting()
        m.addNote("预算", at: at(10))
        let before = m
        let changed = m.editNote("a1", to: "  ")
        #expect(!changed)
        let unchanged = m.editNote("a1", to: "预算 ")
        #expect(!unchanged)
        #expect(m == before)
    }

    @Test func 标记没有文字可改() {
        var m = meeting()
        m.addMark(at: at(10))
        let before = m
        let changed = m.editNote("a1", to: "预算")
        #expect(!changed)
        let missing = m.editNote("a9", to: "预算")
        #expect(!missing)
        #expect(m == before)
    }

    @Test func 删除标注() {
        var m = meeting()
        m.addMark(at: at(10))
        m.addNote("预算", at: at(20))
        let deleted = m.deleteAnnotation("a1")
        #expect(deleted)
        #expect(m.annotationList.map(\.id) == ["a2"])
        let deletedAgain = m.deleteAnnotation("a1")
        #expect(!deletedAgain)
    }
}

/// annotationsHash 写进 minutes.json，之后和当前会议比对来判断“会中标注有改动”，所以算法一旦发布就不能变
@Suite struct AnnotationsHashTests {
    private func sample() -> Meeting {
        var m = meeting()
        m.addMark(at: at(300))
        m.addNote("预算 → 老王确认", at: at(390))
        return m
    }

    /// 期望值用 shell 独立算出（`date -j -u -f %Y-%m-%dT%H:%M:%SZ 2026-11-10T02:05:00Z +%s` 得 1794276300）：
    /// `printf '2:a110:17942763004:mark0:2:a210:17942763904:note23:预算 → 老王确认' | shasum -a 256`
    @Test func 按约定字节格式计算SHA256() {
        #expect(sample().annotationsHash
            == "sha256:e04aab77313b12e810cb4b49c19766df2f4a7424361f03b583576cd605eda2ba")
    }

    @Test func 没有标注时为nil() {
        var m = meeting()
        #expect(m.annotationsHash == nil)
        m.addMark(at: at(10))
        m.deleteAnnotation("a1")
        #expect(m.annotationsHash == nil)
    }

    @Test func 改笔记或删标注时变化() {
        let before = sample().annotationsHash
        var edited = sample()
        edited.editNote("a2", to: "预算 → 老李确认")
        var deleted = sample()
        deleted.deleteAnnotation("a1")
        #expect(edited.annotationsHash != before)
        #expect(deleted.annotationsHash != before)
    }

    @Test func 时间变化时变化() {
        var moved = sample()
        moved.annotations![0].at = at(301)
        #expect(moved.annotationsHash != sample().annotationsHash)
    }

    /// 标记与文字为空串的笔记不同；字段之间挪动文字不能撞出同一个哈希
    @Test func 种类不同或字段边界移动时变化() {
        let mark = Annotation(id: "a1", at: at(10), kind: .mark)
        let emptyNote = Annotation(id: "a1", at: at(10), kind: .note, text: "")
        var a = meeting(), b = meeting()
        a.annotations = [mark]
        b.annotations = [emptyNote]
        #expect(a.annotationsHash != b.annotationsHash)

        a.annotations = [Annotation(id: "a1", at: at(10), kind: .note, text: "ab"),
                         Annotation(id: "a2", at: at(10), kind: .note, text: "c")]
        b.annotations = [Annotation(id: "a1", at: at(10), kind: .note, text: "a"),
                         Annotation(id: "a2", at: at(10), kind: .note, text: "bc")]
        #expect(a.annotationsHash != b.annotationsHash)
    }
}
