import AVKit
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
            Text(formatDuration(meeting.duration ?? 0)).monospacedDigit()
        case .failed:
            Text("失败").foregroundStyle(.orange)
        }
    }
}

private struct MeetingDetail: View {
    @Environment(AppModel.self) private var model
    var meeting: Meeting
    @State private var title = ""

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
                if let url = model.store.recordingURL(meeting) {
                    AudioPlayer(url: url)
                        .frame(height: 60)
                }
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

            Spacer()

            HStack {
                Spacer()
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.store.directory(meeting.id)])
                }
            }
        }
        .padding(20)
        .onDisappear { model.rename(meeting.id, to: title) }
    }

    private var subtitle: String {
        var parts = [meeting.startedAt.formatted(date: .complete, time: .shortened)]
        if let d = meeting.duration { parts.append("时长 \(formatDuration(d))") }
        let devices = Array(NSOrderedSet(array: meeting.segments.map(\.device))) as? [String] ?? []
        if !devices.isEmpty { parts.append(devices.joined(separator: "、")) }
        return parts.joined(separator: " · ")
    }
}

private struct AudioPlayer: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
    }
}
