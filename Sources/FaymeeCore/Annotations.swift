import CryptoKit
import Foundation

public enum AnnotationKind: String, Codable, Hashable, Sendable {
    /// 标记：“刚才这段很重要”，没有文字
    case mark
    /// 笔记：一个时刻加一段用户输入的文字
    case note
}

/// 一条会中标注。与合盖空白一样记墙钟时间，不记录音偏移，用到偏移时经 `RecordingTimeline` 换算，
/// 所以重新转写不影响标注。
///
/// 文件中：`{"id": "a1", "at": "2026-11-10T02:05:00Z", "kind": "mark"}`，笔记多一个 `text`
public struct Annotation: Codable, Hashable, Identifiable, Sendable {
    /// `a1`、`a2`……按创建先后编号，删掉的不复用
    public var id: String
    /// 墙钟时间，整秒。笔记取输入框弹出的时刻，不取回车的时刻
    public var at: Date
    public var kind: AnnotationKind
    /// 笔记的文字，标记为 nil
    public var text: String?

    public init(id: String, at: Date, kind: AnnotationKind, text: String? = nil) {
        self.id = id
        self.at = at
        self.kind = kind
        self.text = text
    }
}

/// 录音中由 App 模型调用，每次标注后立即保存会议；会后的修改、删除也走这里
extension Meeting {
    /// 删光时 `annotations` 回到 nil、不再写进文件；`lastAnnotationNumber` 保留，编号照样不复用
    public var annotationList: [Annotation] {
        get { annotations ?? [] }
        set { annotations = newValue.isEmpty ? nil : newValue }
    }

    /// 下一个新建标注的 id：用过的最大编号加一，删掉的不复用
    public var nextAnnotationID: String { "a\(nextAnnotationNumber)" }

    private var nextAnnotationNumber: Int {
        let listed = annotationList.compactMap { Int($0.id.dropFirst()) }.max() ?? 0
        return max(lastAnnotationNumber ?? 0, listed) + 1
    }

    /// 记下一个标记
    @discardableResult
    public mutating func addMark(at time: Date) -> Annotation {
        append(.mark, at: time, text: nil)
    }

    /// 记下一条笔记，time 是输入框弹出的时刻。文字按 `normalizedNoteText` 规整，规整后为空时不记，返回 nil
    @discardableResult
    public mutating func addNote(_ text: String, at time: Date) -> Annotation? {
        guard let text = Self.normalizedNoteText(text) else { return nil }
        return append(.note, at: time, text: text)
    }

    /// 时间取到整秒：meeting.json 写盘丢小数秒，不取整的话存盘读回后标注哈希会变
    private mutating func append(_ kind: AnnotationKind, at time: Date, text: String?) -> Annotation {
        let n = nextAnnotationNumber
        let a = Annotation(id: "a\(n)", at: Date(timeIntervalSince1970: time.timeIntervalSince1970.rounded(.down)),
                           kind: kind, text: text)
        annotationList.append(a)
        lastAnnotationNumber = n
        return a
    }

    /// 会后修改笔记文字，规整同新建；规整后为空等于取消（删除另走 `deleteAnnotation`）。
    /// 标记没有文字，改它不生效。返回会议是否有变化，没有变化就不必写盘
    @discardableResult
    public mutating func editNote(_ id: String, to text: String) -> Bool {
        guard let text = Self.normalizedNoteText(text),
              let i = annotationList.firstIndex(where: { $0.id == id }),
              annotationList[i].kind == .note, annotationList[i].text != text else { return false }
        annotations![i].text = text
        return true
    }

    /// 删除一条标注，编号不会再被用到。没有这条时返回 false
    @discardableResult
    public mutating func deleteAnnotation(_ id: String) -> Bool {
        guard let i = annotationList.firstIndex(where: { $0.id == id }) else { return false }
        annotationList.remove(at: i)
        return true
    }

    /// 详情页显示的“会中标注 N 处”，标记、笔记都算；没有标注时为 nil，不显示
    public var annotationCountText: String? {
        annotationList.isEmpty ? nil : "会中标注 \(annotationList.count) 处"
    }

    /// 笔记文字的规整，新建和修改共用：换行换成空格，去掉首尾空白；为空时返回 nil
    static func normalizedNoteText(_ text: String) -> String? {
        let t = text.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 标注的 SHA-256，形如 `sha256:<64 位小写十六进制>`，没有标注时为 nil。
    /// 生成纪要时记进 `Minutes.source`，之后与当前会议比对：不同就说明标注改过（改了笔记、删了标注）。
    ///
    /// 值会写盘并在以后比对，字节格式不能改：按列表顺序，每条依次写 id、时间、种类、文字四个字段，
    /// 每个字段写成 `<UTF-8 字节数>:<内容>`，中间没有分隔符。时间是 Unix 秒数向下取整的十进制整数，
    /// 种类是 `mark` / `note`，标记的文字是空串
    public var annotationsHash: String? {
        guard !annotationList.isEmpty else { return nil }
        var bytes = Data()
        for a in annotationList {
            let time = String(Int64(a.at.timeIntervalSince1970.rounded(.down)))
            for field in [a.id, time, a.kind.rawValue, a.text ?? ""] {
                let utf8 = Data(field.utf8)
                bytes.append(contentsOf: "\(utf8.count):".utf8)
                bytes.append(utf8)
            }
        }
        return "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
