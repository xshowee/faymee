import AppKit
import FaymeeCore
import SwiftUI

/// 点纪要出处时请转写稿定位到某句。每次点击都是新的请求（id 不同），同一处点两次也会再定位
struct TranscriptReveal: Equatable {
    let id = UUID()
    /// 要定位、高亮的句子；为 nil 时按 time 找
    var sentenceID: String?
    var time: TimeInterval
}

/// 详情页的转写部分：转写状态与操作，加上转写稿本身。只在录音整理好（可回放）后显示。
/// 转写稿由 MeetingDetail 读盘、和纪要共用（纪要要按最新的转写稿判断不同步），这里改完写回 transcript
struct TranscriptSection: View {
    @Environment(AppModel.self) private var model
    var meeting: Meeting
    var playback: Playback?
    @Binding var transcript: Transcript?
    /// 和纪要部分共用的纪要：读姓名建议，点“忽略”时写回
    @Binding var minutes: Minutes?
    /// 转写稿读取失败的原因
    var loadError: String?
    /// 纪要点出处时的定位请求，处理完置空
    @Binding var reveal: TranscriptReveal?
    @State private var saveError: String?
    @State private var confirmingRetranscribe = false
    /// 正在改名的说话人和输入框里的名字
    @State private var renaming: Speaker?
    @State private var renameDraft = ""
    /// 改名改成了本场另一个说话人的名字，等确认合并
    @State private var pendingMerge: SpeakerMerge?
    /// 有说话人修改时重新区分前先确认
    @State private var pendingRediarize: Rediarize?
    /// 记住声音成功后的短暂提示，和哪次登记设的（连点两次时，第一次的计时不清掉第二次的提示）
    @State private var voiceprintNotice: VoiceprintNotice?
    /// 采纳姓名建议后，顺便问一句要不要记住这个声音（只给按钮，用户点了才登记）
    @State private var enrollOffer: EnrollOffer?
    /// 正在修改的笔记和输入框里的文字
    @State private var editingNote: TranscriptNote?
    @State private var noteDraft = ""
    /// 等确认删除的笔记（笔记是用户自己打的字，删了找不回来，先确认；标记直接删）
    @State private var deletingNote: TranscriptNote?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("转写稿").font(.headline)
                status
                speakerStatusView
                Spacer()
                actions
            }
            .controlSize(.small)

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let voiceprintNotice {
                Label(voiceprintNotice.text, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 之后又改了名（或清空、合并掉）就不再问：按钮会按新名字登记，提示里的名字已不对
            if let enrollOffer, transcript?.speaker(enrollOffer.speakerID)?.displayName == enrollOffer.name {
                enrollOfferView(enrollOffer)
            }

            let suggestions = nameSuggestionActions
            if let transcript, transcript.diarization != nil, !transcript.items.isEmpty {
                SpeakerBar(transcript: transcript, canEdit: canEditSpeakers,
                           onRename: beginRename,
                           onMerge: { source, target in update { $0.mergeSpeaker(source, into: target) } },
                           voiceprintActions: voiceprintActions(transcript),
                           suggestions: suggestions)
            }

            if let transcript {
                if transcript.items.isEmpty {
                    placeholder("没有识别出文字")
                } else {
                    TranscriptList(transcript: transcript, meeting: meeting, playback: playback, isEditable: isEditable,
                                   reveal: $reveal,
                                   onEdit: { id, text in update { $0.edit(sentence: id, to: text) } },
                                   onRestore: { id in update { $0.restore(sentence: id) } },
                                   speakerActions: speakerActions, suggestions: suggestions,
                                   annotationActions: annotationActions)
                }
            } else if let loadError {
                placeholder(loadError)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // 转写稿由 MeetingDetail 在转写、说话人状态变化时重读，之前的保存错误随之作废
        .onChange(of: meeting.transcription) { saveError = nil }
        .onChange(of: meeting.diarization) { saveError = nil }
        .onChange(of: meeting.id) {
            voiceprintNotice = nil
            enrollOffer = nil
        }
        // 重新区分、重新转写后编号已重排，问的那个 spk2 不再是同一个人
        .onChange(of: transcript?.speakersCreatedAt) { enrollOffer = nil }
        // 开始区分说话人时关掉还没确认的改名、合并：结束时说话人整体替换
        .onChange(of: canEditSpeakers) { _, editable in
            if !editable {
                renaming = nil
                pendingMerge = nil
                enrollOffer = nil
            }
        }
        .confirmationDialog("重新转写会丢弃 \(retranscribeEditCount) 处修改",
                            isPresented: $confirmingRetranscribe) {
            Button("重新转写", role: .destructive) { model.transcription.enqueue(meeting.id) }
        } message: {
            if transcript?.diarization != nil, !model.transcription.transcriptionDiarizes {
                Text("转写完成前仍显示当前转写稿，成功后整体替换。这次不区分说话人，新转写稿没有说话人，说话人和名字都会丢掉。")
            } else {
                Text("转写完成前仍显示当前转写稿，成功后整体替换。")
            }
        }
        .alert("给说话人改名", isPresented: $renaming.isPresent(), presenting: renaming) { speaker in
            TextField(speaker.displayName, text: $renameDraft)
            Button("改名") { rename(speaker.id, to: renameDraft) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("转写稿里这个人的所有句子都会显示新名字。留空则恢复为编号。")
        }
        .confirmationDialog(pendingMerge.map { "“\($0.name)”已是本场的另一个说话人，合并为同一人？" } ?? "",
                            isPresented: $pendingMerge.isPresent(), presenting: pendingMerge) { merge in
            Button("合并") {
                guard var edited = transcript, edited.mergeSpeaker(merge.source, into: merge.target),
                      save(edited) else { return }
                // 采纳姓名建议引起的合并：问的是合并后的那个人
                if merge.offersEnroll { offerEnroll(merge.target, in: edited) }
            }
        } message: { _ in
            Text("两人的句子会归到同一个说话人下。")
        }
        .confirmationDialog("重新区分说话人会丢弃 \(transcript?.speakerEditCount ?? 0) 处说话人修改",
                            isPresented: $pendingRediarize.isPresent(), presenting: pendingRediarize) { request in
            Button("重新区分说话人", role: .destructive) {
                model.transcription.enqueueDiarization(meeting.id, speakerCount: request.speakerCount)
            }
        } message: { _ in
            Text("完成前仍显示当前说话人。名字会沿用到时间上重合最多的新说话人，句子文字不变。")
        }
        .alert("修改笔记", isPresented: $editingNote.isPresent(), presenting: editingNote) { note in
            TextField(note.text, text: $noteDraft)
            Button("保存") { model.editNote(note.id, to: noteDraft, in: meeting.id) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("改完后纪要会提示“会中标注有改动”，可以重新生成纪要。清空等于不改，删除请用右键菜单。")
        }
        .confirmationDialog(deletingNote.map { "删除笔记“\($0.text)”？" } ?? "",
                            isPresented: $deletingNote.isPresent(), presenting: deletingNote) { note in
            Button("删除笔记", role: .destructive) { model.deleteAnnotation(note.id, in: meeting.id) }
        } message: { _ in
            Text("删除后不能恢复。")
        }
    }

    /// 转写稿里的旗子和笔记行：改、删都写会议（meeting.json），与转写稿无关，所以转写中也能改，重新转写也不影响
    private var annotationActions: AnnotationActions {
        AnnotationActions(
            onEditNote: { note in
                noteDraft = note.text
                editingNote = note
            },
            onDeleteNote: { note in deletingNote = note },
            onDeleteMark: { mark in model.deleteAnnotation(mark.id, in: meeting.id) })
    }

    private var speakerStatus: SpeakerStatus {
        SpeakerStatus(transcription: meeting.transcription, diarization: meeting.diarization,
                      activity: model.transcription.activity(for: meeting.id), transcript: transcript,
                      canDiarize: model.transcription.canDiarize)
    }

    /// 改说话人（改名、合并、单句改）：转写中不能改（同改文字），区分说话人排队或进行中也不能改，
    /// 结束时说话人整体替换，这期间的修改会被清掉
    private var canEditSpeakers: Bool { isEditable && !speakerStatus.isBusy }

    /// 已有说话人时可以指定人数重新区分；没有引擎时入队总会失败，不给入口
    private var canRediarize: Bool {
        transcript?.diarization != nil && model.transcription.canDiarize
    }

    private var speakerActions: SpeakerActions? {
        guard transcript?.diarization != nil else { return nil }
        return SpeakerActions(
            canEdit: canEditSpeakers,
            onSet: { id, speaker in update { $0.setSpeaker(sentence: id, to: speaker) } },
            onNew: { id in update { $0.setNewSpeaker(sentence: id) != nil } },
            onRestore: { id in update { $0.restoreSpeaker(sentence: id) } },
            onRename: { id in if let s = transcript?.speaker(id) { beginRename(s) } })
    }

    private func voiceprintActions(_ transcript: Transcript) -> VoiceprintActions {
        let library = model.voiceprints.library
        let current = model.transcription.voiceprintModel
        return VoiceprintActions(
            enrollment: { speaker in
                library.enrollmentOption(speaker: speaker.id, in: transcript, meetingID: meeting.id,
                                         currentVoiceprintModel: current)
            },
            onEnroll: { speaker in enroll(speaker, from: transcript) },
            onReject: { speaker in update { $0.rejectRecognizedPerson(speaker.id) } })
    }

    /// 姓名建议：采纳走改名（同名时照常确认合并），忽略写纪要。转写稿和纪要不可用时为空
    private var nameSuggestionActions: NameSuggestionActions {
        let prompts = minutes?.nameSuggestionPrompts(transcript: transcript) ?? [:]
        guard !prompts.isEmpty else { return NameSuggestionActions() }
        return NameSuggestionActions(
            prompts: prompts, canAdopt: canEditSpeakers,
            onAdopt: { prompt in rename(prompt.speaker, to: prompt.name, offeringEnroll: true) },
            onIgnore: ignore,
            onJump: { target in
                playback?.play(from: target.time)
                reveal = TranscriptReveal(sentenceID: target.sentenceID, time: target.time)
            })
    }

    /// 忽略建议：从磁盘重读纪要再改，免得把刚生成好、界面还没换上的新纪要用旧的覆盖。
    /// 不算人工修改，生成纪要期间也可以点（管线写盘前会继承）
    private func ignore(_ prompt: NameSuggestionPrompt) {
        do {
            guard var current = try model.store.loadMinutes(meeting.id) else { return }
            if current.ignoreNameSuggestion(speaker: prompt.speaker, name: prompt.name) {
                try model.store.saveMinutes(current, for: meeting.id)
            }
            minutes = current
            saveError = nil
        } catch {
            saveError = "没能忽略建议：\(error.localizedDescription)"
        }
    }

    /// 采纳建议改名成功后：这个人能登记声纹时，给一个“记住这个声音”按钮。不自动登记
    private func offerEnroll(_ id: String, in edited: Transcript) {
        guard let speaker = edited.speaker(id) else { return }
        let option = model.voiceprints.library.enrollmentOption(
            speaker: id, in: edited, meetingID: meeting.id,
            currentVoiceprintModel: model.transcription.voiceprintModel)
        enrollOffer = option.isEnabled
            ? EnrollOffer(speakerID: id, name: speaker.displayName, title: option.title) : nil
    }

    private func enrollOfferView(_ offer: EnrollOffer) -> some View {
        HStack(spacing: 8) {
            Label("已改名为\(offer.name)", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
            Button(offer.title) {
                enrollOffer = nil
                if let transcript, let speaker = transcript.speaker(offer.speakerID) {
                    enroll(speaker, from: transcript)
                }
            }
            .help("以后的会议自动认出\(offer.name)；声纹只存在这台 Mac 上")
            Button {
                enrollOffer = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("不用了")
        }
        .font(.caption)
        .controlSize(.small)
    }

    /// 记住这个声音：只写声纹库，不改转写稿。之后的会议才会认出此人
    private func enroll(_ speaker: Speaker, from transcript: Transcript) {
        do {
            try model.voiceprints.enroll(speaker: speaker.id, from: transcript, meetingID: meeting.id)
            saveError = nil
            let notice = VoiceprintNotice(text: "已记住\(speaker.displayName)的声音，之后的会议会自动认出")
            voiceprintNotice = notice
            Task {
                try? await Task.sleep(for: .seconds(4))
                if voiceprintNotice?.id == notice.id { voiceprintNotice = nil }
            }
        } catch {
            saveError = "没能记住声音：\(error.localizedDescription)"
        }
    }

    private func beginRename(_ speaker: Speaker) {
        renameDraft = speaker.name ?? ""
        renaming = speaker
    }

    /// 改成本场另一个人的名字时不直接改，先确认合并。
    /// `offeringEnroll`：采纳姓名建议，改好后问要不要记住这个声音
    private func rename(_ id: String, to name: String, offeringEnroll: Bool = false) {
        guard var edited = transcript else { return }
        switch edited.renameSpeaker(id, to: name) {
        case .unchanged:
            break
        case .renamed:
            if save(edited), offeringEnroll { offerEnroll(id, in: edited) }
        case let .needsMerge(target):
            // 清空名字退回的“说话人 N”与别人相同时 name 为空，提示里显示对方的名字
            let merge = SpeakerMerge(source: id, target: target,
                                     name: edited.speaker(target)?.displayName ?? name,
                                     offersEnroll: offeringEnroll)
            // 等改名框关掉再弹合并确认，同一刻弹出可能被吞掉
            Task { pendingMerge = merge }
        }
    }

    /// 重新区分说话人（含区分失败后的“重试”）。会清掉单句改过的说话人和合并，有这类修改时先确认
    private func rediarize(_ speakerCount: Int?) {
        if let transcript, transcript.speakerEditCount > 0 {
            pendingRediarize = Rediarize(speakerCount: speakerCount)
        } else {
            model.transcription.enqueueDiarization(meeting.id, speakerCount: speakerCount)
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

    /// 重新转写会丢弃的修改数。这次不区分说话人（开关关着、没有引擎）时说话人名字也会丢，一起算
    private var retranscribeEditCount: Int {
        transcript?.retranscribeEditCount(diarizes: model.transcription.transcriptionDiarizes) ?? 0
    }

    /// “重试”和“重新转写”成功后都会整份替换现有转写稿，有人工修改时先确认
    private func retranscribe() {
        if retranscribeEditCount > 0 {
            confirmingRetranscribe = true
        } else {
            model.transcription.enqueue(meeting.id)
        }
    }

    /// 改一句就整份原子写盘。写盘失败时界面保持磁盘上的样子，不显示没保存的修改
    private func update(_ change: (inout Transcript) -> Bool) {
        guard var edited = transcript, change(&edited) else { return }
        save(edited)
    }

    @discardableResult
    private func save(_ edited: Transcript) -> Bool {
        do {
            try model.store.saveTranscript(edited, for: meeting.id)
            transcript = edited
            saveError = nil
            return true
        } catch {
            saveError = "修改没能保存：\(error.localizedDescription)"
            return false
        }
    }

    /// 说话人的状态和操作：区分进度、排队、失败原因和重试、旧会议的“区分说话人”。
    /// 转写排队或进行中时不显示，由转写状态说明
    @ViewBuilder private var speakerStatusView: some View {
        let status = speakerStatus
        if let text = status.text {
            if let p = status.progress {
                progress(text, p)
            } else if case .failed = status {
                Label(text, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                Text(text).foregroundStyle(.secondary)
            }
        }
        // 区分前后、失败时入口都在这一个位置：从未区分是“区分说话人”，失败是“重试”（点按钮自动判断人数，
        // 箭头里可以指定人数），区分过是“重新区分说话人”菜单（只有菜单，免得误点就整份重新区分）
        if let title = status.actionTitle {
            Menu(title) { rediarizeItems } primaryAction: { rediarize(nil) }
                .fixedSize()
                .disabled(!canEditSpeakers)
        } else if status == .done, canRediarize {
            Menu("重新区分说话人") { rediarizeItems }
                .fixedSize()
                .disabled(!canEditSpeakers)
                .help("人数不对时指定人数重新区分；名字会沿用到时间上重合最多的新说话人")
        }
    }

    /// “重新区分说话人”可选的人数上限
    private static let maxSpeakerCount = 8

    @ViewBuilder private var rediarizeItems: some View {
        Button("自动判断人数") { rediarize(nil) }
        Divider()
        ForEach(2...Self.maxSpeakerCount, id: \.self) { n in
            Button("\(n) 人") { rediarize(n) }
        }
    }

    @ViewBuilder private var status: some View {
        if let activity = model.transcription.activity(for: meeting.id) {
            switch activity {
            case let .preparing(p):
                progress("正在准备转写引擎（\(formatPercent(p))）", p)
            case let .transcribing(p):
                progress("转写中 \(formatPercent(p))", p)
            case .diarizing:
                // 由 speakerStatusView 显示
                EmptyView()
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
                    .disabled(isDiarizing)
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
                // 只区分说话人正在进行时管线不接受重新转写
                .disabled(isDiarizing)
        }
    }

    private var isDiarizing: Bool {
        if case .diarizing = speakerStatus { true } else { false }
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

    private func copy(_ transcript: Transcript) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.plainText(meeting: meeting), forType: .string)
    }
}

private struct SpeakerMerge {
    var source: String
    var target: String
    /// 合并目标的显示名（即用户输入的名字），确认提示里显示
    var name: String
    /// 采纳姓名建议引起的合并：合并后问要不要记住这个声音
    var offersEnroll = false
}

/// 采纳建议后“记住这个声音”的按钮：对哪个说话人，标题同说话人菜单里那一项
private struct EnrollOffer {
    var speakerID: String
    var name: String
    var title: String
}

private struct Rediarize {
    var speakerCount: Int?
}

private struct VoiceprintNotice {
    let id = UUID()
    var text: String
}

/// 转写稿区分过说话人时，句子菜单里改说话人、段首点名字改名用的操作
struct SpeakerActions {
    var canEdit: Bool
    var onSet: (_ sentenceID: String, _ speakerID: String) -> Void
    var onNew: (_ sentenceID: String) -> Void
    var onRestore: (_ sentenceID: String) -> Void
    var onRename: (_ speakerID: String) -> Void
}

/// 转写稿里旗子（标记）和笔记行的右键操作。点击播放由列表自己处理
struct AnnotationActions {
    var onEditNote: (TranscriptNote) -> Void
    var onDeleteNote: (TranscriptNote) -> Void
    var onDeleteMark: (TranscriptMark) -> Void
}

private extension TranscriptRow {
    /// 列表里一行的身份，也是 `ScrollViewProxy.scrollTo` 的锚点：条目是 `items` 下标（播放跟随、出处定位按它滚），
    /// 笔记是标注 id（改文字不换身份）
    var scrollID: AnyHashable {
        switch self {
        case let .item(i): i
        case let .note(note): note.id
        }
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
    /// 全选复制时带上会议的笔记
    var meeting: Meeting
    var playback: Playback?
    var isEditable: Bool
    @Binding var reveal: TranscriptReveal?
    var onEdit: (_ id: String, _ text: String) -> Void
    var onRestore: (_ id: String) -> Void
    /// 区分过说话人时才有
    var speakerActions: SpeakerActions?
    /// 姓名建议挂在这个人第一次开口的段首
    var suggestions = NameSuggestionActions()
    /// 旗子、笔记行的修改和删除
    var annotationActions: AnnotationActions
    @State private var following = true
    /// 纪要点出处后短暂高亮的条目，和哪次请求高亮的（连点两次时，第一次的计时不清掉第二次的高亮）
    @State private var revealed: Int?
    @State private var revealedBy: UUID?
    @State private var allSelected = false
    @State private var editingID: String?
    @State private var draft = ""
    /// 当前播放到的条目，由 CurrentItemTracker 在条目切换时写入
    @State private var current: Int?
    @State private var layout = TranscriptLayoutCache()
    @FocusState private var focus: TranscriptFocus?

    var body: some View {
        // 段首和可选的说话人整份算一次，不在每行里重算
        let turns = transcript.speakerTurns
        let choices = transcript.speakerList.map { SpeakerChoice(id: $0.speaker.id, name: $0.speaker.displayName) }
        // 笔记按时间插在条目之间（同复制全文），标记的旗子挂在最近的句子旁
        let annotationLayout = layout.layout(transcript: transcript, meeting: meeting)
        let notes = annotationLayout.notes
        let rows = annotationLayout.rows
        let marks = annotationLayout.marks
        let timeWidth = timeWidth(lastNote: notes.last)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // 身份和滚动锚点一致（条目是下标，笔记是标注 id），懒加载时没出现过的行也能滚到
                    ForEach(rows, id: \.scrollID) { r in
                        switch r {
                        case let .item(i):
                            // 滚动锚点仍是条目下标：播放跟随、出处定位都按下标滚
                            row(i, turn: turns[i], isFirst: i == 0, choices: choices,
                                isCurrent: i == current, isRevealed: i == revealed, marks: marks[i] ?? [],
                                timeWidth: timeWidth)
                                .id(i)
                        case let .note(note):
                            TranscriptNoteRow(note: note, timeWidth: timeWidth,
                                              onPlay: { play(from: note.offset) },
                                              onEdit: {
                                                  commitEdit()
                                                  annotationActions.onEditNote(note)
                                              },
                                              onDelete: {
                                                  commitEdit()
                                                  annotationActions.onDeleteNote(note)
                                              })
                                .background(allSelected ? Color(nsColor: .selectedTextBackgroundColor) : .clear)
                                .id(note.id)
                        }
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
            // initial：窄窗口下转写稿刚换上来、或刚读完盘时请求就已经在了
            .onChange(of: reveal, initial: true) { _, request in
                guard let request else { return }
                reveal = nil
                handle(request, proxy)
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
            allSelected ? [NSItemProvider(object: transcript.plainText(meeting: meeting) as NSString)] : []
        }
        .onExitCommand { allSelected = false }
    }

    @ViewBuilder private func row(_ i: Int, turn: SpeakerTurn?, isFirst: Bool, choices: [SpeakerChoice],
                                  isCurrent: Bool, isRevealed: Bool, marks: [TranscriptMark],
                                  timeWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let turn {
                HStack(spacing: 8) {
                    SpeakerTurnHeader(turn: turn, canEdit: speakerActions?.canEdit ?? false) { id in
                        commitEdit()
                        speakerActions?.onRename(id)
                    }
                    if turn.isFirstOfSpeaker, let id = turn.speakerID, let prompt = suggestions.prompts[id] {
                        NameSuggestionView(prompt: prompt, actions: suggestions)
                    }
                }
                // 与句子文字左对齐：行的外边距 4 + 内边距 8 + 时间列 + 间距 10
                .padding(.leading, 12 + timeWidth + 10)
                .padding(.top, isFirst ? 4 : 10)
            }
            switch transcript.items[i] {
            case let .sentence(s):
                TranscriptSentenceRow(
                    sentence: s, isCurrent: isCurrent, isRevealed: isRevealed, timeWidth: timeWidth,
                    isEditable: isEditable,
                    speakerMenu: speakerMenu(for: s, choices: choices),
                    isEditing: editingID == s.id, draft: $draft, focus: $focus,
                    marks: marks,
                    onSeek: { play(from: s.start) },
                    onPlayMark: { mark in play(from: mark.offset) },
                    onDeleteMark: { mark in
                        commitEdit()
                        annotationActions.onDeleteMark(mark)
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

    private func speakerMenu(for s: TranscriptSentence, choices: [SpeakerChoice]) -> SentenceSpeakerMenu? {
        guard let actions = speakerActions, actions.canEdit else { return nil }
        // 只有改过说话人的句子才去查能不能恢复
        let canRestore = s.originalSpeaker != nil && transcript.canRestoreSpeaker(sentence: s.id)
        let original = s.originalSpeaker.map { o in
            o.speaker.flatMap(transcript.speaker)?.displayName ?? Speaker.unknownName
        }
        return SentenceSpeakerMenu(
            choices: choices.filter { $0.id != s.speaker },
            restoreTo: canRestore ? original : nil,
            onSet: { id in
                commitEdit()
                actions.onSet(s.id, id)
            },
            onNew: {
                commitEdit()
                actions.onNew(s.id)
            },
            onRestore: {
                commitEdit()
                actions.onRestore(s.id)
            })
    }

    /// 定位到纪要出处那句：结束编辑、恢复跟随、滚过去并短暂高亮。播放由点出处的一方负责
    private func handle(_ request: TranscriptReveal, _ proxy: ScrollViewProxy) {
        commitEdit()
        let index = request.sentenceID.flatMap { id in
            transcript.items.firstIndex { if case let .sentence(s) = $0 { s.id == id } else { false } }
        } ?? transcript.itemIndex(at: request.time)
        guard let index else { return }
        following = true
        scroll(proxy, to: index)
        revealed = index
        revealedBy = request.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if revealedBy == request.id { withAnimation(.easeOut(duration: 0.4)) { revealed = nil } }
        }
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

    /// 点时间、旗子、笔记行：结束编辑，恢复跟随，从这里播放
    private func play(from time: TimeInterval) {
        commitEdit()
        following = true
        playback?.play(from: time)
    }

    /// 时间列宽度，录音超过一小时时要放得下 h:mm:ss（笔记可能排在最后一条之后）
    private func timeWidth(lastNote: TranscriptNote?) -> CGFloat {
        max(transcript.items.last?.start ?? 0, lastNote?.offset ?? 0) >= 3600 ? 60 : 42
    }

    private func scroll(_ proxy: ScrollViewProxy, to i: Int) {
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(i, anchor: UnitPoint(x: 0, y: 0.3))
        }
    }
}

/// body 在编辑句子时每按一键、播放时每换一句都会重算，笔记行和旗子的排版要换算时间线、排序、挂旗子，
/// 所以转写稿的条目和会议的标注没变时沿用上次的结果。是普通的类而不是状态：在 body 里更新它不触发重绘
@MainActor private final class TranscriptLayoutCache {
    private var cached: TranscriptAnnotationLayout?

    func layout(transcript: Transcript, meeting: Meeting) -> TranscriptAnnotationLayout {
        let layout = cached?.updated(transcript: transcript, meeting: meeting)
            ?? TranscriptAnnotationLayout(transcript: transcript, meeting: meeting)
        cached = layout
        return layout
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
    /// 纪要点出处定位到这句，比播放高亮更醒目
    var isRevealed = false
    var timeWidth: CGFloat
    var isEditable: Bool
    /// 右键菜单里改这句的说话人；没区分过、不能改说话人时为 nil
    var speakerMenu: SentenceSpeakerMenu?
    var isEditing: Bool
    @Binding var draft: String
    var focus: FocusState<TranscriptFocus?>.Binding
    /// 挂在这句旁的标记（离它最近的句子是这句），按时间先后
    var marks: [TranscriptMark] = []
    var onSeek: () -> Void
    var onPlayMark: (TranscriptMark) -> Void
    var onDeleteMark: (TranscriptMark) -> Void
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
        .background(Color.accentColor.opacity(isRevealed ? 0.3 : isCurrent ? 0.15 : 0),
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
                ForEach(marks, id: \.id) { mark in
                    MarkFlag(mark: mark, onPlay: { onPlayMark(mark) }, onDelete: { onDeleteMark(mark) })
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
                if let speakerMenu {
                    Divider()
                    Menu("改说话人") {
                        ForEach(speakerMenu.choices) { choice in
                            Button(choice.name) { speakerMenu.onSet(choice.id) }
                        }
                        if !speakerMenu.choices.isEmpty { Divider() }
                        Button("新说话人", action: speakerMenu.onNew)
                    }
                    if let name = speakerMenu.restoreTo {
                        Button("恢复说话人（\(name)）", action: speakerMenu.onRestore)
                    }
                }
                // 旗子很小，右键这句也能删它旁边的标记
                if !marks.isEmpty {
                    Divider()
                    ForEach(marks, id: \.id) { mark in
                        Button("删除标记（\(formatDuration(mark.offset))）") { onDeleteMark(mark) }
                    }
                }
            }
        }
    }
}

private struct SpeakerChoice: Identifiable {
    var id: String
    var name: String
}

private struct SentenceSpeakerMenu {
    /// 可以改给的说话人，不含这句当前的
    var choices: [SpeakerChoice]
    /// 能恢复时为区分结果原来的说话人名字（可能是“未知”）
    var restoreTo: String?
    var onSet: (_ speakerID: String) -> Void
    var onNew: () -> Void
    var onRestore: () -> Void
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

/// 会中标记的旗子，挂在离标记最近的句子末尾：点击从标记的时刻播放（不是句子开头），右键删除
private struct MarkFlag: View {
    var mark: TranscriptMark
    var onPlay: () -> Void
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onPlay) {
            Image(systemName: "flag.fill")
                .font(.caption)
                .foregroundStyle(Color.orange.opacity(hovering ? 1 : 0.8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("会中标记（\(formatDuration(mark.offset))），点击从这里播放")
        .contextMenu {
            Button("从这里播放", action: onPlay)
            Divider()
            Button("删除标记", action: onDelete)
        }
    }
}

/// 会中笔记：不可编辑的一行，按时间插在句子之间，样式与句子、合盖空白都区分开。
/// 点击从笔记的时刻播放；右键修改文字、删除
private struct TranscriptNoteRow: View {
    var note: TranscriptNote
    var timeWidth: CGFloat
    var onPlay: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(formatDuration(note.offset))
                .monospacedDigit()
                .foregroundStyle(hovering ? Color.accentColor : .secondary)
                .frame(width: timeWidth, alignment: .leading)
            Label {
                Text("笔记：\(note.text)")
            } icon: {
                Image(systemName: "square.and.pencil")
            }
            .foregroundStyle(.purple)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.purple.opacity(hovering ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onPlay)
        .help("会中笔记，点击从这里播放；右键可修改或删除")
        .contextMenu {
            Button("从这里播放", action: onPlay)
            Divider()
            Button("修改笔记…", action: onEdit)
            Button("删除笔记…", action: onDelete)
        }
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
