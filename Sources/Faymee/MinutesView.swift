import FaymeeCore
import SwiftUI

/// 详情页的纪要部分：纪要状态与操作、不同步提示，加上按节显示的纪要。
/// 纪要和转写稿由 MeetingDetail 读盘后传进来，这里只负责显示；点出处时间交给 onJump
struct MinutesPanel: View {
    @Environment(AppModel.self) private var model
    var meeting: Meeting
    var minutes: Minutes?
    /// 纪要文件读取失败的原因
    var loadError: String?
    /// 当前转写稿（含未落盘前的最新修改），用来判断不同步、解析出处。没有或读不出来时为 nil
    var transcript: Transcript?
    var onJump: (MinutesRefTarget) -> Void

    var body: some View {
        let status = MinutesStatus(state: meeting.minutes, activity: model.minutes.activity(for: meeting.id),
                                   waitReason: model.minutes.waitReason(for: meeting.id), transcript: transcript)
        let sync = minutes.flatMap { m in transcript.map { m.sync(with: $0) } } ?? .inSync

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("纪要").font(.headline)
                if let minutes {
                    Text(MinutesTemplate(key: minutes.template)?.name ?? minutes.template)
                        .foregroundStyle(.secondary)
                }
                StatusView(status: status, generate: generate)
                Spacer()
                actions(status)
            }
            .controlSize(.small)

            if let notice = sync.notice {
                SyncBanner(sync: sync, notice: notice, canRegenerate: !status.isBusy, regenerate: generate)
            }

            if let minutes {
                MinutesContent(minutes: minutes, meeting: meeting, transcript: transcript, sync: sync,
                               onJump: onJump)
            } else {
                placeholder(status)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 生成纪要、重试、重新生成、现在生成都是用户手动点的，一律不等接通电源。
    /// 07：重新生成前有人工修改时先确认“会丢弃 N 处修改”
    private func generate() {
        model.minutes.enqueue(meeting.id, now: true)
    }

    /// 标题行右侧的操作。07（模板切换）、08（复制纪要、导出…）的按钮加在这里
    @ViewBuilder private func actions(_ status: MinutesStatus) -> some View {
        // 排队、重新生成期间也能复制或导出正在显示的旧纪要
        if let minutes {
            Button("复制纪要") { MinutesExport.copy(minutes, meeting: meeting) }
            Button("导出…") { MinutesExport.export(minutes, meeting: meeting, transcript: transcript) }
        }
        // 纪要文件缺失或读不出来时也要能重新生成
        if status == .done {
            Button("重新生成", action: generate)
        }
    }

    /// 没有纪要可显示。为什么没有、能做什么，标题旁的状态已经说了
    private func placeholder(_ status: MinutesStatus) -> some View {
        Text(loadError ?? (status == .done ? "找不到纪要文件" : "还没有纪要"))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 标题旁的状态：进度、排队说明、失败原因，以及对应的按钮
private struct StatusView: View {
    var status: MinutesStatus
    var generate: () -> Void

    var body: some View {
        if let text = status.text {
            if let p = status.progress {
                HStack(spacing: 6) {
                    ProgressView(value: p).frame(width: 80)
                    Text(text).monospacedDigit().foregroundStyle(.secondary)
                }
            } else if case .failed = status {
                Label(text, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                Text(text).foregroundStyle(.secondary)
            }
        }
        if let action = status.actionTitle {
            Button(action, action: generate)
        }
    }
}

/// 纪要与转写稿不同步的提示条：重新转写的醒目，只是改了句子的不显眼
private struct SyncBanner: View {
    var sync: MinutesSync
    var notice: String
    /// 排队或生成中不再提供重新生成
    var canRegenerate: Bool
    var regenerate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if sync == .retranscribed {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Label(notice, systemImage: "pencil")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if canRegenerate {
                Button("重新生成纪要", action: regenerate)
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.vertical, sync == .retranscribed ? 6 : 0)
        .padding(.horizontal, sync == .retranscribed ? 10 : 0)
        .background(sync == .retranscribed ? Color.orange.opacity(0.1) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 按节显示纪要。空的节（或条目都删了）显示“无”
private struct MinutesContent: View {
    var minutes: Minutes
    var meeting: Meeting
    var transcript: Transcript?
    var sync: MinutesSync
    var onJump: (MinutesRefTarget) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(minutes.sections.indices, id: \.self) { i in
                    section(minutes.sections[i])
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func section(_ section: MinutesSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.subheadline.bold())
            let items = section.visibleItems
            if items.isEmpty {
                Text("无").foregroundStyle(.tertiary)
            } else {
                ForEach(items, id: \.id) { item in
                    MinutesItemRow(item: item, isAction: section.kind == .actions, meeting: meeting,
                                   chips: item.refs.map { $0.chip(in: transcript, sync: sync) }, onJump: onJump)
                }
            }
        }
    }
}

/// 一个条目：文字，下面一行是负责人、截止时间、出处时间。
/// 一处出处都没找到的条目整行标橙色，由用户判断是否删除
private struct MinutesItemRow: View {
    var item: MinutesItem
    var isAction: Bool
    var meeting: Meeting
    var chips: [MinutesRefChip]
    var onJump: (MinutesRefTarget) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isAction ? "square" : "circle.fill")
                .font(.system(size: isAction ? 11 : 5))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if hasMeta {
                    FlowLayout(spacing: 6) {
                        if isAction, let owner = item.owner, !owner.isEmpty {
                            Label(owner, systemImage: "person")
                                .foregroundStyle(.secondary)
                        }
                        if isAction, let due = item.dueText(meetingStartedAt: meeting.startedAt) {
                            Label(due, systemImage: "calendar")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(chips.indices, id: \.self) { i in
                            RefChip(chip: chips[i]) { onJump(chips[i].target) }
                        }
                        if item.isUnsourced {
                            Label("未找到出处", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("模型给出的出处在转写稿里都找不到，内容可能不可靠")
                        }
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(item.isUnsourced ? Color.orange.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }

    private var hasMeta: Bool {
        !chips.isEmpty || item.isUnsourced || (isAction && (item.owner != nil || item.due != nil || item.dueDate != nil))
    }
}

/// 出处时间：悬停显示原句，点击跳到转写稿该句并从那里播放
private struct RefChip: View {
    var chip: MinutesRefChip
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(chip.label)
                .monospacedDigit()
                .foregroundStyle(hovering ? Color.accentColor : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(hovering ? 0.18 : 0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(chip.hint)
    }
}

/// 从左到右排，一行放不下就换行
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                // 同一行按底部对齐，图标高低不一时文字仍在一条线上
                subviews[i].place(at: CGPoint(x: x, y: y + row.height - size.height), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
