import FaymeeCore
import SwiftUI

/// 说话人的颜色。按 `Speaker.colorIndex` 取，超过调色板长度时循环；未知用中性色
enum SpeakerPalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]

    static func color(_ index: Int?) -> Color {
        guard let index else { return .secondary }
        return colors[index % colors.count]
    }
}

/// 详情页转写稿上方的说话人列表：每人一个 chip（颜色、名字、发言时长），点开是改名、合并到……；
/// 右侧是“重新区分说话人”。转写稿有说话人信息（区分过）时才显示，只有一个人时也显示，
/// 这样自动判断成一个人时也能改名、指定人数重新区分
struct SpeakerBar: View {
    var transcript: Transcript
    /// 排队、转写中、区分说话人中不能改
    var canEdit: Bool
    var canRediarize: Bool
    var onRename: (Speaker) -> Void
    var onMerge: (_ source: String, _ target: String) -> Void
    var onRediarize: (_ speakerCount: Int?) -> Void

    /// “重新区分说话人”可选的人数上限
    private static let maxSpeakerCount = 8

    var body: some View {
        let list = transcript.speakerList
        HStack(alignment: .top, spacing: 8) {
            Text("说话人")
                .foregroundStyle(.secondary)
                .padding(.vertical, 3)
            if list.isEmpty {
                Text("没有区分出说话人")
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 3)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(list, id: \.speaker.id) { entry in
                        SpeakerChip(entry: entry, others: list.filter { $0.speaker.id != entry.speaker.id },
                                    canEdit: canEdit, onRename: onRename, onMerge: onMerge)
                    }
                }
            }
            Spacer(minLength: 0)
            if canRediarize {
                Menu("重新区分说话人") {
                    Button("自动判断人数") { onRediarize(nil) }
                    Divider()
                    ForEach(2...Self.maxSpeakerCount, id: \.self) { n in
                        Button("\(n) 人") { onRediarize(n) }
                    }
                }
                .fixedSize()
                .disabled(!canEdit)
                .help("人数不对时指定人数重新区分；名字会沿用到时间上重合最多的新说话人")
            }
        }
        .font(.callout)
        .controlSize(.small)
    }
}

private struct SpeakerChip: View {
    var entry: SpeakerListEntry
    var others: [SpeakerListEntry]
    var canEdit: Bool
    var onRename: (Speaker) -> Void
    var onMerge: (_ source: String, _ target: String) -> Void

    var body: some View {
        let speaker = entry.speaker
        Menu {
            Button("改名…") { onRename(speaker) }
            if !others.isEmpty {
                Menu("合并到") {
                    ForEach(others, id: \.speaker.id) { other in
                        Button(other.speaker.displayName) { onMerge(speaker.id, other.speaker.id) }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(SpeakerPalette.color(speaker.colorIndex))
                    .frame(width: 8, height: 8)
                Text(speaker.displayName)
                // 单句改出来的新说话人没有区分结果，时长为 0，不显示
                if speaker.speechDuration > 0 {
                    Text(formatDuration(speaker.speechDuration))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.background.secondary, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!canEdit)
        .help("\(entry.sentenceCount) 句")
    }
}

/// 段首：说话人颜色和名字。点名字改名；未知不能点
struct SpeakerTurnHeader: View {
    var turn: SpeakerTurn
    var canEdit: Bool
    var onRename: (_ speakerID: String) -> Void

    var body: some View {
        let color = SpeakerPalette.color(turn.colorIndex)
        if let id = turn.speakerID {
            Button { onRename(id) } label: { label(color) }
                .buttonStyle(.plain)
                .disabled(!canEdit)
                .help(canEdit ? "改名" : "")
        } else {
            label(color)
        }
    }

    private func label(_ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(turn.name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(turn.speakerID == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
        }
    }
}
