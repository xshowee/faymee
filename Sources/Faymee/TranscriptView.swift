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
    @State private var saveError: String?
    @State private var confirmingRetranscribe = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("转写稿").font(.headline)
                status
                Spacer()
                actions
            }
            .controlSize(.small)

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let transcript {
                if transcript.items.isEmpty {
                    placeholder("没有识别出文字")
                } else {
                    TranscriptList(transcript: transcript, playback: playback, isEditable: isEditable,
                                   onEdit: { id, text in update { $0.edit(sentence: id, to: text) } },
                                   onRestore: { id in update { $0.restore(sentence: id) } })
                }
            } else if let loadError {
                placeholder(loadError)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // 转写状态变化时重读：完成后换上新稿；重新转写进行中或失败时文件没动，仍显示旧稿
        .task(id: meeting.transcription) { reload() }
        .confirmationDialog("重新转写会丢弃 \(transcript?.editCount ?? 0) 处修改",
                            isPresented: $confirmingRetranscribe) {
            Button("重新转写", role: .destructive) { model.transcription.enqueue(meeting.id) }
        } message: {
            Text("转写完成前仍显示当前转写稿，成功后整体替换。")
        }
    }

    /// 排队或转写中不能编辑：转写成功后整份替换，这期间的修改会被悄悄丢掉。
    /// 失败时旧稿保留，可以继续编辑
    private var isEditable: Bool {
        switch meeting.transcription?.status {
        case .queued, .running: false
        case nil, .done, .failed: true
        }
    }

    /// “重试”和“重新转写”成功后都会整份替换现有转写稿，有人工修改时先确认
    private func retranscribe() {
        if let transcript, transcript.editCount > 0 {
            confirmingRetranscribe = true
        } else {
            model.transcription.enqueue(meeting.id)
        }
    }

    /// 改一句就整份原子写盘。写盘失败时界面保持磁盘上的样子，不显示没保存的修改
    private func update(_ change: (inout Transcript) -> Bool) {
        guard var edited = transcript, change(&edited) else { return }
        do {
            try model.store.saveTranscript(edited, for: meeting.id)
            transcript = edited
            saveError = nil
        } catch {
            saveError = "修改没能保存：\(error.localizedDescription)"
        }
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
                Button("重试") { retranscribe() }
            case .done:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if let transcript, !transcript.items.isEmpty {
            Button("复制全文") { copy(transcript) }
        }
        // 转写稿缺失或读不出来时也要能重新转写，否则就再也转不了
        if meeting.transcription?.status == .done {
            Button("重新转写") { retranscribe() }
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
            saveError = nil
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

/// 列表里谁有键盘焦点：列表本身（⌘A/⌘C）或正在编辑的句子
private enum TranscriptFocus: Hashable {
    case list
    case sentence(String)
}

/// 转写稿列表：一条一行。播放时高亮当前条目并跟随滚动；
/// 用户手动滚动后暂停跟随，直到点某句的时间或重新开始播放。
/// 双击句子编辑：回车或点别处保存，Esc 取消；同一时间只编辑一句
private struct TranscriptList: View {
    var transcript: Transcript
    var playback: Playback?
    var isEditable: Bool
    var onEdit: (_ id: String, _ text: String) -> Void
    var onRestore: (_ id: String) -> Void
    @State private var following = true
    @State private var allSelected = false
    @State private var editingID: String?
    @State private var draft = ""
    /// 当前播放到的条目，由 CurrentItemTracker 在条目切换时写入
    @State private var current: Int?
    @FocusState private var focus: TranscriptFocus?

    var body: some View {
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
            .background {
                if let playback {
                    CurrentItemTracker(playback: playback, transcript: transcript, current: $current)
                }
            }
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
        .focused($focus, equals: .list)
        // 编辑中不抢焦点：双击的第二下、在编辑框里点光标位置都可能触发这个手势
        .simultaneousGesture(TapGesture().onEnded { if editingID == nil { focus = .list } })
        .onChange(of: focus) { old, new in
            if new != .list { allSelected = false }
            // 编辑框失去焦点（点了别的控件等）就保存
            if case let .sentence(id) = old, new != old, editingID == id { commitEdit() }
        }
        .onChange(of: draft) { old, new in
            // 竖向编辑框里回车若插入了换行而不是提交，也当作回车保存（一句一行，不需要换行）。
            // 只看新出现的换行，免得原文本身带换行时一进入编辑就被保存
            if editingID != nil, new.contains(where: \.isNewline), !old.contains(where: \.isNewline) {
                commitEdit()
            }
        }
        // 编辑中切到别的会议或关掉窗口，同样算“点别处”，保存
        .onDisappear(perform: commitEdit)
        .onChange(of: isEditable) { _, editable in
            // 开始重新转写：放弃正在编辑的内容，免得写进马上要被整份替换的旧稿
            if !editable { cancelEdit() }
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
                TranscriptSentenceRow(
                    sentence: s, isCurrent: isCurrent, timeWidth: timeWidth, isEditable: isEditable,
                    isEditing: editingID == s.id, draft: $draft, focus: $focus,
                    onSeek: {
                        commitEdit()
                        following = true
                        playback?.play(from: s.start)
                    },
                    onTap: commitEdit,
                    onBeginEdit: { beginEdit(s) },
                    onCommit: commitEdit,
                    onCancel: cancelEdit,
                    onRestore: {
                        commitEdit()
                        onRestore(s.id)
                    })
            case let .gap(g):
                TranscriptGapRow(gap: g, isCurrent: isCurrent, timeWidth: timeWidth)
                    .onTapGesture(perform: commitEdit)
            }
        }
        .background(allSelected ? Color(nsColor: .selectedTextBackgroundColor) : .clear)
    }

    private func beginEdit(_ s: TranscriptSentence) {
        guard isEditable, editingID != s.id else { return }
        commitEdit()
        allSelected = false
        draft = s.text
        editingID = s.id
    }

    /// 保存正在编辑的句子，没有在编辑时什么都不做。先清掉 editingID，焦点随后变化时就不会再存一次
    private func commitEdit() {
        guard let id = editingID else { return }
        editingID = nil
        onEdit(id, draft)
        focus = .list
    }

    private func cancelEdit() {
        guard editingID != nil else { return }
        editingID = nil
        focus = .list
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

/// 只有它观察播放进度（每 0.25 秒变一次），算出的当前条目变了才写回。
/// 列表本身因此只在条目切换时重算，而不是播放时每 0.25 秒整个重算
private struct CurrentItemTracker: View {
    var playback: Playback
    var transcript: Transcript
    @Binding var current: Int?

    var body: some View {
        let index = transcript.itemIndex(at: playback.currentTime)
        Color.clear
            .onChange(of: index, initial: true) { _, index in current = index }
            .onDisappear { current = nil }
    }
}

/// 一句一行：时间（单击跳到该句开头播放）+ 文本。
/// 双击文本进入编辑；改过的句子末尾有个淡淡的铅笔标记，点开可以看原文、恢复原文
private struct TranscriptSentenceRow: View {
    var sentence: TranscriptSentence
    var isCurrent: Bool
    var timeWidth: CGFloat
    var isEditable: Bool
    var isEditing: Bool
    @Binding var draft: String
    var focus: FocusState<TranscriptFocus?>.Binding
    var onSeek: () -> Void
    /// 单击文本：结束别的句子的编辑（“点别处保存”）
    var onTap: () -> Void
    var onBeginEdit: () -> Void
    var onCommit: () -> Void
    var onCancel: () -> Void
    var onRestore: () -> Void

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

    @ViewBuilder private var text: some View {
        if isEditing {
            // 竖向扩展：长句子折行显示而不是横向滚动。句中换行由 Transcript.edit 换成空格
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .focused(focus, equals: .sentence(sentence.id))
                // 编辑框出现后再给焦点；出现前设的焦点可能落空
                .onAppear { focus.wrappedValue = .sentence(sentence.id) }
                .onSubmit(onCommit)
                .onExitCommand(perform: onCancel)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(sentence.text)
                if let original = sentence.original {
                    EditedMarker(original: original, canRestore: isEditable, onRestore: onRestore)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if isEditable { onBeginEdit() } }
            .onTapGesture(perform: onTap)
            .contextMenu {
                if isEditable {
                    Button("编辑", action: onBeginEdit)
                    if sentence.original != nil {
                        Button("恢复原文", action: onRestore)
                    }
                }
            }
        }
    }
}

/// 人工修改过的标记：不显眼的铅笔图标，点开显示引擎原文和“恢复原文”
private struct EditedMarker: View {
    var original: String
    var canRestore: Bool
    var onRestore: () -> Void

    var body: some View {
        Menu {
            Text("原文：\(original)")
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
