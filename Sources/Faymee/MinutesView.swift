import FaymeeCore
import SwiftUI

/// 详情页的纪要部分：纪要状态与操作、不同步提示，加上按节显示的纪要。
/// 纪要和转写稿由 MeetingDetail 读盘后传进来；这里改完纪要写盘并写回 minutes，点出处时间交给 onJump
struct MinutesPanel: View {
    @Environment(AppModel.self) private var model
    var meeting: Meeting
    @Binding var minutes: Minutes?
    /// 纪要文件读取失败的原因
    var loadError: String?
    /// 当前转写稿（含未落盘前的最新修改），用来判断不同步、解析出处。没有或读不出来时为 nil
    var transcript: Transcript?
    var onJump: (MinutesRefTarget) -> Void
    @State private var saveError: String?
    @State private var refs = RefResolverCache()
    /// 有人工修改时，重新生成（或切换模板）要先确认
    @State private var pendingRegenerate: Regenerate?

    /// 等确认的重新生成；template 为 nil 时沿用当前模板
    private struct Regenerate {
        var template: MinutesTemplate?
    }

    var body: some View {
        let status = MinutesStatus(state: meeting.minutes, activity: model.minutes.activity(for: meeting.id),
                                   waitReason: model.minutes.waitReason(for: meeting.id), transcript: transcript)
        let resolver = refs.resolver(minutes: minutes, transcript: transcript)
        let sync = resolver.sync

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("纪要").font(.headline)
                if let minutes {
                    Text(MinutesTemplate(key: minutes.template)?.name ?? minutes.template)
                        .foregroundStyle(.secondary)
                }
                if status == .queued(.model) {
                    // 不静默下载：在这里说明要下多大的模型，用户点“下载”才开始
                    ModelDownloadControls(style: .minutes)
                } else {
                    StatusView(status: status) { regenerate(status) }
                }
                Spacer()
                actions(status)
            }
            .controlSize(.small)

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let notice = sync.notice {
                SyncBanner(sync: sync, notice: notice, canRegenerate: !status.isBusy) { regenerate(status) }
            }

            if let minutes {
                MinutesContent(minutes: minutes, meeting: meeting, refs: resolver,
                               isEditable: !status.isBusy, onJump: onJump, onChange: update)
            } else {
                placeholder(status)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // 纪要由 MeetingDetail 在状态变化时重读，之前的保存错误随之作废
        .onChange(of: meeting.minutes) { saveError = nil }
        .confirmationDialog("重新生成会丢弃 \(minutes?.editCount ?? 0) 处修改",
                            isPresented: Binding(get: { pendingRegenerate != nil },
                                                 set: { if !$0 { pendingRegenerate = nil } }),
                            presenting: pendingRegenerate) { pending in
            Button(pending.template.map { "按“\($0.name)”重新生成" } ?? "重新生成", role: .destructive) {
                generate(template: pending.template)
            }
        } message: { _ in
            Text("生成完成前仍显示当前纪要，成功后整体替换。")
        }
    }

    /// 生成纪要、重试、重新生成、现在生成、切换模板都走这里。纪要有人工修改时先确认“会丢弃 N 处修改”；
    /// 已在排队（如“现在生成”）时修改是排队前就有的、排队后也改不了，不再问
    private func regenerate(_ status: MinutesStatus, template: MinutesTemplate? = nil) {
        if !status.isBusy, let minutes, minutes.editCount > 0 {
            pendingRegenerate = Regenerate(template: template)
        } else {
            generate(template: template)
        }
    }

    /// 都是用户手动点的，一律不等接通电源
    private func generate(template: MinutesTemplate? = nil) {
        model.minutes.enqueue(meeting.id, template: template, now: true)
    }

    /// 改一处就整份原子写盘。写盘失败时界面保持磁盘上的样子，不显示没保存的修改
    private func update(_ change: (inout Minutes) -> Bool) {
        guard var edited = minutes, change(&edited) else { return }
        do {
            try model.store.saveMinutes(edited, for: meeting.id)
            minutes = edited
            saveError = nil
        } catch {
            saveError = "修改没能保存：\(error.localizedDescription)"
        }
    }

    /// 标题行右侧的操作。08（复制纪要、导出…）的按钮加在这里
    @ViewBuilder private func actions(_ status: MinutesStatus) -> some View {
        // 排队、重新生成期间也能复制或导出正在显示的旧纪要
        if let minutes {
            Button("复制纪要") { MinutesExport.copy(minutes, meeting: meeting, transcript: transcript) }
            Button("导出…") { MinutesExport.export(minutes, meeting: meeting, transcript: transcript) }
        }
        // 纪要文件缺失或读不出来时也要能重新生成
        if status == .done {
            RegenerateMenu(current: minutes?.template) { template in regenerate(status, template: template) }
        }
    }

    /// 没有纪要可显示。为什么没有、能做什么，标题旁的状态已经说了
    private func placeholder(_ status: MinutesStatus) -> some View {
        Text(loadError ?? (status == .done ? "找不到纪要文件" : "还没有纪要"))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// body 每次渲染都要解析出处，生成中进度每秒变好几次。同步状态要对整份转写稿算 SHA-256，
/// 所以纪要的 source 和转写稿没变时沿用上次的解析器。是普通的类而不是状态：在 body 里更新它不触发重绘
@MainActor private final class RefResolverCache {
    private var cached: MinutesRefResolver?

    func resolver(minutes: Minutes?, transcript: Transcript?) -> MinutesRefResolver {
        let resolver = cached?.updated(minutes: minutes, transcript: transcript)
            ?? MinutesRefResolver(minutes: minutes, transcript: transcript)
        cached = resolver
        return resolver
    }
}

/// “重新生成”：点按钮按当前模板重新生成，点箭头可以选别的模板（切换模板）。
/// 两者放在一个控件里，标题行还要放状态、复制、导出，窄窗口下放不下更多按钮
private struct RegenerateMenu: View {
    /// `Minutes.template`；纪要文件缺失或读不出来时为 nil
    var current: String?
    /// nil 表示沿用当前模板
    var onSelect: (MinutesTemplate?) -> Void

    var body: some View {
        Menu("重新生成") {
            Section("按模板重新生成") {
                ForEach(MinutesTemplate.all) { template in
                    Button(template.key == current ? "\(template.name)（当前）" : template.name) {
                        onSelect(template)
                    }
                }
            }
        } primaryAction: {
            onSelect(nil)
        }
        .fixedSize()
        .help("按当前模板重新生成；点箭头切换模板")
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

/// 按节显示纪要。空的节（或条目都删了）显示“无”。
/// 可编辑时：双击条目或右键编辑，悬停时行尾有编辑、删除按钮，节末可以添加；已删除的条目留一行可以撤销
private struct MinutesContent: View {
    var minutes: Minutes
    var meeting: Meeting
    /// 在当前转写稿里解析出处
    var refs: MinutesRefResolver
    /// 排队或生成中不能编辑：成功后整份替换，这期间的修改会被悄悄丢掉。失败时旧纪要保留，可以继续编辑
    var isEditable: Bool
    var onJump: (MinutesRefTarget) -> Void
    /// 改纪要：闭包返回是否有变化，有变化才写盘
    var onChange: ((inout Minutes) -> Bool) -> Void
    /// 正在编辑的条目，或要往哪一节添加；同一时间只有一个
    @State private var editing: EditTarget?

    private enum EditTarget: Hashable {
        case item(String)
        case add(MinutesSectionKind)
    }

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
        // 开始重新生成：放弃正在编辑的内容，免得写进马上要被整份替换的旧纪要
        .onChange(of: isEditable) { _, editable in
            if !editable { editing = nil }
        }
    }

    private func section(_ section: MinutesSection) -> some View {
        let isAction = section.kind == .actions
        return VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.subheadline.bold())
            if section.visibleItems.isEmpty {
                Text("无").foregroundStyle(.tertiary)
            }
            ForEach(section.items, id: \.id) { item in
                if item.deleted {
                    if isEditable {
                        DeletedItemRow(item: item) { onChange { $0.undoDelete(item: item.id) } }
                    }
                } else {
                    MinutesItemRow(item: item, isAction: isAction, meeting: meeting,
                                   chips: item.refs.map(refs.chip),
                                   isEditable: isEditable, onJump: onJump,
                                   onEdit: { editing = .item(item.id) },
                                   onRestore: { onChange { $0.restore(item: item.id) } },
                                   onDelete: { onChange { $0.delete(item: item.id) } })
                        .popover(isPresented: presenting(.item(item.id)), arrowEdge: .bottom) {
                            MinutesItemEditor(title: "编辑条目", isAction: isAction, item: item,
                                              meetingStartedAt: meeting.startedAt) { draft in
                                editing = nil
                                onChange { $0.edit(item: item.id, text: draft.text, owner: draft.owner,
                                                   due: draft.due, dueDate: draft.dueDate) }
                            } onCancel: { editing = nil }
                        }
                }
            }
            if isEditable {
                Button {
                    editing = .add(section.kind)
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .popover(isPresented: presenting(.add(section.kind)), arrowEdge: .bottom) {
                    MinutesItemEditor(title: "添加到“\(section.title)”", isAction: isAction, item: nil,
                                      meetingStartedAt: meeting.startedAt) { draft in
                        editing = nil
                        onChange { $0.addItem(to: section.kind, text: draft.text, owner: draft.owner,
                                              due: draft.due, dueDate: draft.dueDate) != nil }
                    } onCancel: { editing = nil }
                }
            }
        }
    }

    private func presenting(_ target: EditTarget) -> Binding<Bool> {
        Binding(get: { editing == target }, set: { if !$0, editing == target { editing = nil } })
    }
}

/// 一个条目：文字，下面一行是负责人、截止时间、出处时间和标记。
/// 一处出处都没找到的条目整行标橙色，由用户判断是否删除；改过的条目文字后有个淡淡的铅笔标记
private struct MinutesItemRow: View {
    var item: MinutesItem
    var isAction: Bool
    var meeting: Meeting
    var chips: [MinutesRefChip]
    var isEditable: Bool
    var onJump: (MinutesRefTarget) -> Void
    var onEdit: () -> Void
    var onRestore: () -> Void
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isAction ? "square" : "circle.fill")
                .font(.system(size: isAction ? 11 : 5))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(item.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let original = item.original {
                        MinutesEditedMarker(original: original, isAction: isAction, meeting: meeting,
                                            canRestore: isEditable, onRestore: onRestore)
                    }
                }
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
                        if item.origin == .manual {
                            Label("手动添加", systemImage: "hand.point.up.left")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if isEditable { onEdit() } }
            if isEditable {
                // 悬停才显示，占位不变，免得行宽跳动
                HStack(spacing: 2) {
                    Button(action: onEdit) { Image(systemName: "pencil") }
                        .help("编辑")
                    Button(action: onDelete) { Image(systemName: "trash") }
                        .help("删除")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(item.isUnsourced ? Color.orange.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
        .contextMenu {
            if isEditable {
                Button("编辑…", action: onEdit)
                if item.original != nil {
                    Button("恢复原文", action: onRestore)
                }
                Divider()
                Button("删除", action: onDelete)
            }
        }
    }

    private var hasMeta: Bool {
        !chips.isEmpty || item.isUnsourced || item.origin == .manual
            || (isAction && (item.owner != nil || item.due != nil || item.dueDate != nil))
    }
}

/// 已删除的条目：留一行淡淡的划线文字，可以撤销
private struct DeletedItemRow: View {
    var item: MinutesItem
    var onUndo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .font(.system(size: 9))
                .frame(width: 12)
            Text(item.text)
                .strikethrough()
                .lineLimit(1)
                .truncationMode(.tail)
            Button("撤销删除", action: onUndo)
                .buttonStyle(.borderless)
                .fixedSize()
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
        .help("已删除，不会复制或导出")
    }
}

/// 改过的条目：不显眼的铅笔图标，点开显示模型原文和“恢复原文”
private struct MinutesEditedMarker: View {
    var original: MinutesItem.Original
    var isAction: Bool
    var meeting: Meeting
    var canRestore: Bool
    var onRestore: () -> Void

    var body: some View {
        Menu {
            Text("原文：\(original.text)")
            if isAction {
                Text("负责人：\(original.owner ?? "无")")
                let due = MinutesItem(id: "", text: "", due: original.due, dueDate: original.dueDate, refs: [])
                    .dueText(meetingStartedAt: meeting.startedAt)
                Text("截止：\(due ?? "无")")
            }
            Divider()
            Button("恢复原文", action: onRestore).disabled(!canRestore)
        } label: {
            Image(systemName: "pencil")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .font(.caption)
        .foregroundStyle(.tertiary)
        .help("已修改")
    }
}

/// 编辑或新增条目的表单：文字，待办另有负责人、截止时间（会上的原话）和换算后的日期。
/// 日期不会按原话自动换算，改了原话要自己核对日期
private struct MinutesItemEditor: View {
    struct Draft {
        var text: String
        var owner: String
        var due: String
        var hasDate: Bool
        var date: Date

        var dueDate: CalendarDate? {
            guard hasDate else { return nil }
            let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
            return c.year.flatMap { y in c.month.flatMap { m in c.day.flatMap { CalendarDate(year: y, month: m, day: $0) } } }
        }
    }

    var title: String
    var isAction: Bool
    var onSave: (Draft) -> Void
    var onCancel: () -> Void
    @State private var draft: Draft
    @FocusState private var textFocused: Bool

    /// item 为 nil 时是新增
    init(title: String, isAction: Bool, item: MinutesItem?, meetingStartedAt: Date,
         onSave: @escaping (Draft) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.isAction = isAction
        self.onSave = onSave
        self.onCancel = onCancel
        let date = item?.dueDate.flatMap {
            Calendar.current.date(from: DateComponents(year: $0.year, month: $0.month, day: $0.day))
        }
        _draft = State(initialValue: Draft(text: item?.text ?? "", owner: item?.owner ?? "", due: item?.due ?? "",
                                           hasDate: date != nil, date: date ?? meetingStartedAt))
    }

    private var canSave: Bool { !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField("内容", text: $draft.text, axis: .vertical)
                .lineLimit(2...6)
                .focused($textFocused)
            if isAction {
                TextField("负责人", text: $draft.owner)
                TextField("截止时间（如“下周三”）", text: $draft.due)
                HStack {
                    Toggle("截止日期", isOn: $draft.hasDate)
                    DatePicker("", selection: $draft.date, displayedComponents: .date)
                        .labelsHidden()
                        .disabled(!draft.hasDate)
                }
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .frame(width: 340)
        .onAppear { textFocused = true }
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
struct FlowLayout: Layout {
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
