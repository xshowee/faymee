import FaymeeCore
import Observation
import SwiftUI

/// 界面上的声纹库：所有写入都经过这里，写完重读，菜单和管理窗口跟着变。
/// 转写管线识别时自己从磁盘读（只读），不经过这里。只在用户主动操作时写
@MainActor @Observable
final class VoiceprintLibraryModel {
    @ObservationIgnored let store: VoiceprintStore
    private(set) var library = VoiceprintLibrary()
    /// 声纹库文件读不出来的原因。这时 library 为空，只能全部删除
    private(set) var loadError: String?

    init(store: VoiceprintStore = VoiceprintStore()) {
        self.store = store
        reload()
    }

    /// 管理窗口打开时、每次写入后重读
    func reload() {
        do {
            library = try store.load()
            loadError = nil
        } catch {
            library = VoiceprintLibrary()
            loadError = "声纹库读取失败：\(error.localizedDescription)"
        }
    }

    /// 记住这个声音 / 把本场声音也加进去。只在用户点菜单时调用
    @discardableResult
    func enroll(speaker id: String, from transcript: Transcript, meetingID: String) throws -> String {
        try update { try $0.enroll(speaker: id, from: transcript, meetingID: meetingID) }
    }

    func rename(_ id: String, to name: String) throws {
        try update { try $0.rename(id, to: name) }
    }

    func remove(_ id: String) throws {
        try update { $0.remove(id) }
    }

    /// 全部删除：直接删文件，文件坏了也能删
    func removeAll() throws {
        defer { reload() }
        try store.removeAll()
    }

    private func update<T>(_ body: (inout VoiceprintLibrary) throws -> T) throws -> T {
        defer { reload() }
        return try store.update(body)
    }
}

/// 声纹管理窗口（从设置进入）：登记过的人、样本数、需要重新登记的标记；改名、删除、全部删除。
/// 都不回写过去的会议
struct VoiceprintsView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: VoiceprintPerson?
    @State private var renameDraft = ""
    @State private var deleting: VoiceprintPerson?
    @State private var confirmingDeleteAll = false
    @State private var actionError: String?

    var body: some View {
        let voiceprints = model.voiceprints
        let people = voiceprints.library.people
        let currentModel = model.transcription.voiceprintModel

        VStack(alignment: .leading, spacing: 8) {
            Text("登记过的人会在之后的会议里被自动认出。声纹只存在这台 Mac 上，只在你在会议里点“记住这个声音”时登记。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let loadError = voiceprints.loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if people.isEmpty {
                Text(voiceprints.loadError == nil ? "还没有登记任何人" : "")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                List(people, id: \.id) { person in
                    VoiceprintPersonRow(
                        person: person,
                        // 没有区分引擎时不知道当前模型，不标
                        needsReenrollment: currentModel.map(person.needsReenrollment(voiceprintModel:)) ?? false,
                        onRename: { beginRename(person) },
                        onDelete: { deleting = person })
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds()
            }

            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("共 \(people.count) 人")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("全部删除…", role: .destructive) { confirmingDeleteAll = true }
                    // 文件坏了也要能清除
                    .disabled(people.isEmpty && voiceprints.loadError == nil)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(minWidth: 360, minHeight: 280)
        // 声纹库只在本 App 里改，打开时重读一次以防文件在别处被动过
        .onAppear {
            voiceprints.reload()
            actionError = nil
        }
        .alert("给声纹改名", isPresented: isPresent($renaming), presenting: renaming) { person in
            TextField(person.name, text: $renameDraft)
            Button("改名") { perform { try voiceprints.rename(person.id, to: renameDraft) } }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("只影响之后的会议，过去会议里已经显示的名字不变。")
        }
        .confirmationDialog(deleting.map { "删除“\($0.name)”的声纹？" } ?? "",
                            isPresented: isPresent($deleting), presenting: deleting) { person in
            Button("删除", role: .destructive) { perform { try voiceprints.remove(person.id) } }
        } message: { _ in
            Text("之后的会议不再认出此人，过去会议里已经显示的名字不变。")
        }
        .confirmationDialog("删除全部声纹？", isPresented: $confirmingDeleteAll) {
            Button("全部删除", role: .destructive) { perform { try voiceprints.removeAll() } }
        } message: {
            Text("声纹库里的所有人和样本都会删掉，之后的会议不再自动认出任何人。过去会议里已经显示的名字不变。")
        }
    }

    private func beginRename(_ person: VoiceprintPerson) {
        renameDraft = person.name
        renaming = person
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// 把可选值绑定成 alert / confirmationDialog 的 isPresented：关掉时置空
    private func isPresent<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

private struct VoiceprintPersonRow: View {
    var person: VoiceprintPerson
    var needsReenrollment: Bool
    var onRename: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(person.name)
            if needsReenrollment {
                Text("需要重新登记")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("换过区分说话人的引擎，旧声纹不再用来认人。在有此人的会议里重新点“记住这个声音”")
            }
            Spacer()
            Text("\(person.samples.count) 个样本")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Menu {
                Button("改名…", action: onRename)
                Button("删除…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("改名…", action: onRename)
            Button("删除…", role: .destructive, action: onDelete)
        }
    }
}
