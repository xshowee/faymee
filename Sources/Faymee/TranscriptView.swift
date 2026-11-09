import AppKit
import FaymeeCore
import SwiftUI

/// 详情页的转写部分：转写状态与操作，加上转写稿本身。只在录音整理好（可回放）后显示
struct TranscriptSection: View {
    @Environment(AppModel.self) private var model
    var meeting: Meeting
    var playback: Playback?
    @State private var transcript: Transcript?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("转写稿").font(.headline)
                status
                Spacer()
                actions
            }
            .controlSize(.small)

            if let transcript {
                if transcript.items.isEmpty {
                    placeholder("没有识别出文字")
                } else {
                    TranscriptList(transcript: transcript, playback: playback)
                }
            } else if let loadError {
                placeholder(loadError)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // 转写状态变化时重读：完成后换上新稿；重新转写进行中或失败时文件没动，仍显示旧稿
        .task(id: meeting.transcription) { reload() }
    }

    @ViewBuilder private var status: some View {
        if let activity = model.transcription.activity(for: meeting.id) {
            switch activity {
            case let .preparing(p):
                progress("正在准备转写引擎（\(percent(p))）", p)
            case let .transcribing(p):
                progress("转写中 \(percent(p))", p)
            }
        } else {
            switch meeting.transcription?.status {
            case nil:
                // v0.1 的旧会议不会自动转写
                Button("转写") { model.transcription.enqueue(meeting.id) }
            case .queued:
                Text("排队中").foregroundStyle(.secondary)
            case .running:
                // 管线刚开始或刚被录音暂停的一瞬间，还没有进度
                Text("转写中…").foregroundStyle(.secondary)
            case .failed:
                Label(meeting.transcription?.error ?? "转写失败", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                Button("重试") { model.transcription.enqueue(meeting.id) }
            case .done:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if let transcript, !transcript.items.isEmpty {
            Button("复制全文") { copy(transcript) }
        }
        if transcript != nil, meeting.transcription?.status == .done {
            // TODO(06)：转写稿有人工修改时先确认“重新转写会丢弃 N 处修改”
            Button("重新转写") { model.transcription.enqueue(meeting.id) }
        }
    }

    private func progress(_ title: String, _ value: Double) -> some View {
        HStack(spacing: 6) {
            ProgressView(value: value).frame(width: 80)
            Text(title).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func percent(_ p: Double) -> String {
        "\(Int((min(max(p, 0), 1) * 100).rounded()))%"
    }

    private func reload() {
        do {
            transcript = try model.store.loadTranscript(meeting.id)
            loadError = nil
        } catch {
            transcript = nil
            loadError = "转写稿读取失败：\(error.localizedDescription)"
        }
    }

    private func copy(_ transcript: Transcript) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.plainText, forType: .string)
    }
}

/// 转写稿列表：一条一行。播放时高亮当前条目并跟随滚动；
/// 用户手动滚动后暂停跟随，直到点某句的时间或重新开始播放
private struct TranscriptList: View {
    var transcript: Transcript
    var playback: Playback?
    @State private var following = true
    @State private var allSelected = false
    @FocusState private var focused: Bool

    var body: some View {
        let current = playback.flatMap { transcript.itemIndex(at: $0.currentTime) }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(transcript.items.indices, id: \.self) { i in
                        row(i, isCurrent: i == current)
                            .id(i)
                    }
                }
                .padding(.vertical, 4)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .onScrollPhaseChange { _, phase in
                // 程序滚动是 .animating，只有用户拖动、滚轮和惯性才暂停跟随
                if phase == .tracking || phase == .interacting || phase == .decelerating {
                    following = false
                }
            }
            .onChange(of: current) { _, current in
                if following, let current { scroll(proxy, to: current) }
            }
            .onChange(of: playback?.isPlaying) { _, playing in
                if playing == true {
                    following = true
                    if let current { scroll(proxy, to: current) }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !following, playback?.isPlaying == true, let current {
                    Button("回到当前位置") {
                        following = true
                        scroll(proxy, to: current)
                    }
                    .controlSize(.small)
                    .padding(8)
                }
            }
        }
        // 全选复制：⌘A 选中整份转写稿，⌘C 复制为带时间的纯文本
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .simultaneousGesture(TapGesture().onEnded { focused = true })
        .onChange(of: focused) { _, focused in
            if !focused { allSelected = false }
        }
        .onCommand(#selector(NSResponder.selectAll(_:))) { allSelected = true }
        .onCopyCommand {
            allSelected ? [NSItemProvider(object: transcript.plainText as NSString)] : []
        }
        .onExitCommand { allSelected = false }
    }

    @ViewBuilder private func row(_ i: Int, isCurrent: Bool) -> some View {
        Group {
            switch transcript.items[i] {
            case let .sentence(s):
                TranscriptSentenceRow(sentence: s, isCurrent: isCurrent, timeWidth: timeWidth) {
                    following = true
                    playback?.play(from: s.start)
                }
            case let .gap(g):
                TranscriptGapRow(gap: g, isCurrent: isCurrent, timeWidth: timeWidth)
            }
        }
        .background(allSelected ? Color(nsColor: .selectedTextBackgroundColor) : .clear)
    }

    /// 时间列宽度，录音超过一小时时要放得下 h:mm:ss
    private var timeWidth: CGFloat {
        (transcript.items.last?.start ?? 0) >= 3600 ? 60 : 42
    }

    private func scroll(_ proxy: ScrollViewProxy, to i: Int) {
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(i, anchor: UnitPoint(x: 0, y: 0.3))
        }
    }
}

/// 一句一行：时间（单击跳到该句开头播放）+ 文本。
/// 编辑（06）只需要替换 `text` 部分，时间列和高亮背景不变
struct TranscriptSentenceRow: View {
    var sentence: TranscriptSentence
    var isCurrent: Bool
    var timeWidth: CGFloat
    var onSeek: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TimestampButton(time: sentence.start, width: timeWidth, action: onSeek)
            text
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isCurrent ? Color.accentColor.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 4)
    }

    private var text: some View {
        Text(sentence.text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 合盖空白：不可编辑的标记行，样式与句子区分开
struct TranscriptGapRow: View {
    var gap: TranscriptGap
    var isCurrent: Bool
    var timeWidth: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(formatDuration(gap.start))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: timeWidth, alignment: .leading)
            Label(gap.label, systemImage: "mic.slash")
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.orange.opacity(isCurrent ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}

private struct TimestampButton: View {
    var time: TimeInterval
    var width: CGFloat
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(formatDuration(time))
                .monospacedDigit()
                .foregroundStyle(hovering ? Color.accentColor : .secondary)
                .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("从这里播放")
    }
}
