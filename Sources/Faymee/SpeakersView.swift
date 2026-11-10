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

/// 详情页转写稿上方的说话人列表：每人一个 chip（颜色、名字、发言时长），点开是改名、合并到……、
/// 记住这个声音、不是此人（只对声纹认出的人）；
/// 右侧是“重新区分说话人”。转写稿有说话人信息（区分过）时才显示，只有一个人时也显示，
/// 这样自动判断成一个人时也能改名、指定人数重新区分
struct SpeakerBar: View {
    var transcript: Transcript
    /// 排队、转写中、区分说话人中不能改
    var canEdit: Bool
    var canRediarize: Bool
    var onRename: (Speaker) -> Void
    var onMerge: (_ source: String, _ target: String) -> Void
    var voiceprintActions: VoiceprintActions
    var suggestions: NameSuggestionActions
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
                        // chip 和它的姓名建议放在一起，折行时不分开
                        HStack(spacing: 6) {
                            SpeakerChip(entry: entry, others: list.filter { $0.speaker.id != entry.speaker.id },
                                        canEdit: canEdit, onRename: onRename, onMerge: onMerge,
                                        voiceprintActions: voiceprintActions)
                            if let prompt = suggestions.prompts[entry.speaker.id] {
                                NameSuggestionView(prompt: prompt, actions: suggestions)
                            }
                        }
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

/// 说话人菜单里的声纹操作。登记只在用户点“记住这个声音”时发生
struct VoiceprintActions {
    /// 这个说话人的“记住这个声音”一项：标题、能不能点、原因
    var enrollment: (Speaker) -> VoiceprintEnrollmentOption
    var onEnroll: (Speaker) -> Void
    /// 不是此人：退回“说话人 N”
    var onReject: (Speaker) -> Void
}

private struct SpeakerChip: View {
    var entry: SpeakerListEntry
    var others: [SpeakerListEntry]
    var canEdit: Bool
    var onRename: (Speaker) -> Void
    var onMerge: (_ source: String, _ target: String) -> Void
    var voiceprintActions: VoiceprintActions

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
            Divider()
            let enrollment = voiceprintActions.enrollment(speaker)
            Button(enrollment.title) { voiceprintActions.onEnroll(speaker) }
                .disabled(!enrollment.isEnabled)
            // 禁用项的悬停提示在菜单里不可靠，原因直接作为一行灰字放在下面
            if let reason = enrollment.unavailableReason {
                Text(reason)
            }
            if speaker.isRecognized {
                Button("不是此人") { voiceprintActions.onReject(speaker) }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(SpeakerPalette.color(speaker.colorIndex))
                    .frame(width: 8, height: 8)
                Text(speaker.displayName)
                if speaker.isRecognized {
                    RecognizedMark()
                }
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
        .help("\(entry.sentenceCount) 句" + (speaker.isRecognized ? "。\(RecognizedMark.explanation)" : ""))
    }
}

/// 纪要生成时推断出的姓名建议，和采纳、忽略、点出处的操作。没有要显示的建议时 `prompts` 为空
struct NameSuggestionActions {
    /// 说话人 id → 要显示的建议（`Minutes.nameSuggestionPrompts`）
    var prompts: [String: NameSuggestionPrompt] = [:]
    /// 采纳就是改名：和改名一样，转写中、区分说话人中不能点
    var canAdopt = false
    var onAdopt: (NameSuggestionPrompt) -> Void = { _ in }
    var onIgnore: (NameSuggestionPrompt) -> Void = { _ in }
    /// 点出处：跳到那句称呼并从那里播放
    var onJump: (MinutesRefTarget) -> Void = { _ in }
}

/// “可能是王总？”，后面是出处时间（点了跳到那句称呼）、采纳、忽略。
/// 说话人列表里跟在 chip 后面，转写稿里跟在这个人第一次开口的段首后面
struct NameSuggestionView: View {
    var prompt: NameSuggestionPrompt
    var actions: NameSuggestionActions

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tertiary)
            Text("可能是\(prompt.name)？")
                .foregroundStyle(.secondary)
                .help("生成纪要时从会上的称呼推断，点时间可以听那句原话")
            ForEach(prompt.refs.indices, id: \.self) { i in
                RefChip(chip: prompt.refs[i]) { actions.onJump(prompt.refs[i].target) }
            }
            Button("采纳") { actions.onAdopt(prompt) }
                .disabled(!actions.canAdopt)
                .help("把这个说话人改名为“\(prompt.name)”")
            Button("忽略") { actions.onIgnore(prompt) }
                .help("不再提示这个名字，重新生成纪要也不会再出现")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .fixedSize()
    }
}

/// “自动认出”标记：名字是声纹认出的，机器判断、可能出错。不显眼，悬停有说明
struct RecognizedMark: View {
    static let explanation = "名字由声纹自动认出，可能出错；认错了在说话人菜单里点“不是此人”"

    var body: some View {
        Image(systemName: "waveform")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .help(Self.explanation)
            .accessibilityLabel("自动认出")
    }
}

/// 段首：说话人颜色和名字。点名字改名；未知不能点
struct SpeakerTurnHeader: View {
    var turn: SpeakerTurn
    var canEdit: Bool
    var onRename: (_ speakerID: String) -> Void

    var body: some View {
        let color = SpeakerPalette.color(turn.colorIndex)
        HStack(spacing: 4) {
            if let id = turn.speakerID {
                Button { onRename(id) } label: { label(color) }
                    .buttonStyle(.plain)
                    .disabled(!canEdit)
                    .help(canEdit ? "改名" : "")
            } else {
                label(color)
            }
            if turn.isRecognized {
                RecognizedMark()
            }
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
