import AVKit
import FaymeeCore
import SwiftUI

struct MeetingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Meeting.ID?

    var body: some View {
        NavigationSplitView {
            List(model.meetings, selection: $selection) { m in
                MeetingRow(meeting: m)
            }
            .contextMenu(forSelectionType: Meeting.ID.self) { ids in
                if let id = ids.first {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.store.directory(id)])
                    }
                    Button("移到废纸篓", role: .destructive) {
                        model.trash(id)
                    }
                    .disabled(id == model.current?.id)
                }
            }
            .overlay {
                if model.meetings.isEmpty {
                    ContentUnavailableView("还没有会议", systemImage: "waveform",
                                           description: Text("点击菜单栏图标开始录音"))
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let id = selection, let m = model.meeting(id) {
                MeetingDetail(meeting: m)
                    .id(m.id)
            } else {
                ContentUnavailableView("选择一场会议", systemImage: "list.bullet")
            }
        }
    }
}

private struct MeetingRow: View {
    @Environment(AppModel.self) private var model
    var meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                status
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var status: some View {
        switch meeting.status {
        case .recording:
            Text(model.current?.id == meeting.id ? "录音中" : "待恢复").foregroundStyle(.red)
        case .finalizing:
            Text("整理中…")
        case .done:
            if model.transcription.activity(for: meeting.id) != nil {
                Text("转写中…")
            } else if model.minutes.activity(for: meeting.id) != nil {
                Text("生成纪要中…")
            } else {
                Text(formatDuration(meeting.duration ?? 0)).monospacedDigit()
            }
        case .failed:
            Text("失败").foregroundStyle(.orange)
        }
    }
}

private struct MeetingDetail: View {
    @Environment(AppModel.self) private var model
    var meeting: Meeting
    @State private var title = ""
    /// 播放器和转写稿共用；整理完成（有录音文件）后才创建
    @State private var playback: Playback?
    /// 转写稿和纪要在这里读盘，两边共用：纪要按最新的转写稿（含刚改的句子）判断不同步、解析出处
    @State private var transcript: Transcript?
    @State private var transcriptError: String?
    @State private var minutes: Minutes?
    @State private var minutesError: String?
    /// 纪要点出处时请转写稿定位
    @State private var reveal: TranscriptReveal?
    /// 窗口够宽时纪要和转写稿并排，否则分段切换
    @State private var isWide = true
    @State private var pane: DetailPane = .minutes
    /// 第一次读完纪要之前为 false，见 reloadMinutes
    @State private var minutesLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("标题", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.bold())
                .onSubmit { model.rename(meeting.id, to: title) }
                .onAppear { title = meeting.title }

            Text(subtitle)
                .foregroundStyle(.secondary)

            if !meeting.lidGaps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("以下时段因合盖，内置麦克风没有录到声音", systemImage: "mic.slash")
                        .foregroundStyle(.orange)
                    ForEach(meeting.lidGaps, id: \.self) { gap in
                        Text(formatTimeRange(gap))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }

            switch meeting.status {
            case .done:
                if let playback {
                    AudioPlayer(player: playback.player)
                        .frame(height: 60)
                }
                panes
            case .recording:
                Label("正在录音", systemImage: "record.circle").foregroundStyle(.red)
            case .finalizing:
                ProgressView("正在整理录音…").controlSize(.small)
            case .failed:
                Label(meeting.error ?? "整理录音失败", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("重试") {
                    Task { await model.finalize(meeting.id) }
                }
            }

            // 转写稿占满剩余高度；没有转写稿时把按钮推到底部
            if meeting.status != .done { Spacer() }

            HStack {
                Spacer()
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.store.directory(meeting.id)])
                }
            }
        }
        .padding(20)
        // 转写状态变化时重读：完成后换上新稿；重新转写进行中或失败时文件没动，仍显示旧稿
        .task(id: meeting.transcription) { reloadTranscript() }
        // 纪要同理：重新生成成功后换上新纪要，排队、生成中、失败时仍显示旧纪要
        .task(id: meeting.minutes) { reloadMinutes() }
        // 正在看的会议整理完成时，录音文件才出现
        .task(id: model.store.recordingURL(meeting)) {
            guard playback == nil, let url = model.store.recordingURL(meeting) else { return }
            playback = Playback(url: url)
        }
        .onDisappear {
            model.rename(meeting.id, to: title)
            // stop 后观察已移除，不能再用；置空后再次出现时由上面的 .task 重建
            playback?.stop()
            playback = nil
        }
    }

    /// 纪要（左）和转写稿（右）。窄窗口下叠在一起、只显示选中的那个：
    /// 两个都一直在视图树里，切换时不重建，转写稿的滚动位置、编辑状态都保留，点出处时也随时能定位
    private var panes: some View {
        let layout = isWide ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            : AnyLayout(ZStackLayout(alignment: .topLeading))
        return VStack(alignment: .leading, spacing: 8) {
            if !isWide {
                Picker("", selection: $pane) {
                    Text("纪要").tag(DetailPane.minutes)
                    Text("转写稿").tag(DetailPane.transcript)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            layout {
                MinutesPanel(meeting: meeting, minutes: minutes, loadError: minutesError, transcript: transcript,
                             onJump: jump)
                    .modifier(PaneVisibility(isVisible: isWide || pane == .minutes))
                TranscriptSection(meeting: meeting, playback: playback, transcript: $transcript,
                                  loadError: transcriptError, reveal: $reveal)
                    .modifier(PaneVisibility(isVisible: isWide || pane == .transcript))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.wideWidth } action: { isWide = $0 }
    }

    /// 并排时每边至少要能放下一行状态和操作按钮
    private static let wideWidth: CGFloat = 720

    /// 点纪要的出处时间：从那里播放，转写稿定位并高亮那句；窄窗口下切到转写稿
    private func jump(to target: MinutesRefTarget) {
        if !isWide { pane = .transcript }
        playback?.play(from: target.time)
        // 只在有转写稿列表接收时才发请求：没人处理的请求会留到列表下次出现时才触发
        if let transcript, !transcript.items.isEmpty {
            reveal = TranscriptReveal(sentenceID: target.sentenceID, time: target.time)
        }
    }

    private func reloadTranscript() {
        do {
            transcript = try model.store.loadTranscript(meeting.id)
            transcriptError = nil
        } catch {
            transcript = nil
            transcriptError = "转写稿读取失败：\(error.localizedDescription)"
        }
    }

    private func reloadMinutes() {
        do {
            minutes = try model.store.loadMinutes(meeting.id)
            minutesError = nil
        } catch {
            minutes = nil
            minutesError = "纪要读取失败：\(error.localizedDescription)"
        }
        // 窄窗口下打开一场还没有纪要的会议（旧会议、还在排队）时先显示转写稿；
        // 只在打开时决定一次，之后纪要生成好了也不替用户切换
        if !minutesLoaded {
            minutesLoaded = true
            pane = minutes == nil ? .transcript : .minutes
        }
    }

    private var subtitle: String {
        var parts = [meeting.startedAt.formatted(date: .complete, time: .shortened)]
        if let d = meeting.duration { parts.append("时长 \(formatDuration(d))") }
        let devices = Array(NSOrderedSet(array: meeting.segments.map(\.device))) as? [String] ?? []
        if !devices.isEmpty { parts.append(devices.joined(separator: "、")) }
        return parts.joined(separator: " · ")
    }
}

private enum DetailPane: Hashable {
    case minutes, transcript
}

/// 窄窗口下没选中的那一栏：留在视图树里但看不见、点不到，也拿不到键盘焦点
private struct PaneVisibility: ViewModifier {
    var isVisible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .disabled(!isVisible)
            .accessibilityHidden(!isVisible)
    }
}

/// 播放器由 Playback 持有，暂停和清理也由它负责
private struct AudioPlayer: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
