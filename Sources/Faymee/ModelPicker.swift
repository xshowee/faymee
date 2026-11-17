import AppKit
import FaymeeCore
import SwiftUI

/// 设置里一个用途的“模型选择 + 下载”：选择框列出目录里适用于这个用途的模型（可以不用的用途多一项“不用”），
/// 下面是所选模型的下载大小、内存、速度、能力、评估结论，以及下载 / 暂停 / 继续 / 删除；
/// 再下面列出这个用途里其他已下载的模型，不用先选上就能删。
/// 选择立即写进设置；所选模型没下载也能选（用到它的任务会排队等下载）。删除前确认，说明按现在选着它的各用途说后果
struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    let role: ModelRole
    /// 选择框的标题；不给时用用途名
    var title: String?
    /// 能不能删除这个模型（比如正在用它生成纪要时不能）；不能时给出原因
    var deleteBlockedReason: (CatalogModel) -> String? = { _ in nil }
    /// 删除后要做的事（如通知管线）；删除本身由下载器完成
    var onDeleted: (CatalogModel) -> Void = { _ in }

    @State private var confirmingDelete: CatalogModel?
    @State private var deleteError: String?

    var body: some View {
        let selections: ModelSelections = model.modelSelections
        let options = selections.catalog.models(for: role)
        let selected = selections.selected(for: role)

        Picker(title ?? role.displayName, selection: Binding(
            get: { selections.selectedID(for: role) },
            set: { selections.select($0, for: role) }
        )) {
            if role.allowsNone {
                Text("不用").tag(String?.none)
            }
            ForEach(options) { option in
                Text(optionLabel(option)).tag(Optional(option.id))
            }
        }
        // 挂在总会显示的选择框上：Form 里每个顶层子视图各占一行，单独放一个空视图会多出一行
        .confirmationDialog("删除\(confirmingDelete?.name ?? "")？", isPresented: Binding(
            get: { confirmingDelete != nil },
            set: { if !$0 { confirmingDelete = nil } }
        ), presenting: confirmingDelete) { target in
            Button("删除模型", role: .destructive) { delete(target) }
        } message: { target in
            Text(deleteMessage(target))
        }

        if let selected {
            ModelDetails(model: selected, role: role, downloadBytes: downloadBytes(selected))
            if let downloader = model.modelDownloads.downloader(for: selected) {
                LabeledContent("模型文件") {
                    ModelDownloadControls(style: .settings, downloader: downloader)
                }
                if downloader.isReady {
                    let blocked = deleteBlockedReason(selected)
                    HStack {
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [downloader.model.directoryName.isEmpty
                                    ? downloader.model.url(in: downloader.directory)
                                    : downloader.model.directory(in: downloader.directory)])
                        }
                        Spacer()
                        Button("删除模型…", role: .destructive) { confirmingDelete = selected }
                            .disabled(blocked != nil)
                    }
                    if let blocked {
                        Text(blocked)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        ForEach(otherDownloaded(options, selected: selected)) { other in
            LabeledContent("已下载：\(other.name)") {
                Button("删除…", role: .destructive) { confirmingDelete = other }
                    .disabled(deleteBlockedReason(other) != nil)
                    .help(deleteBlockedReason(other) ?? "删除这个没选用的模型，释放空间")
            }
        }
        if let deleteError {
            Label(deleteError, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// 这个用途里没选、但已下载的模型（换过模型后留下的）：可以直接删
    private func otherDownloaded(_ options: [CatalogModel], selected: CatalogModel?) -> [CatalogModel] {
        options.filter { $0.id != selected?.id && model.modelDownloads.downloader(for: $0)?.isReady == true }
    }

    /// 选择框里每一项：名字和下载大小
    private func optionLabel(_ option: CatalogModel) -> String {
        guard let size = downloadBytes(option) else { return option.name }
        return "\(option.name)（\(formatModelSize(size))）"
    }

    /// 要下载的总大小（含辅助模型）；不用下载时为 nil
    private func downloadBytes(_ option: CatalogModel) -> Int64? {
        model.modelDownloads.downloader(for: option)?.totalBytes
    }

    private func deleteMessage(_ target: CatalogModel) -> String {
        ModelDeletion.message(size: downloadBytes(target).map(formatModelSize) ?? "",
                              selectedFor: model.modelSelections.roles(selecting: target))
    }

    private func delete(_ target: CatalogModel) {
        // 确认框弹出期间可能开始用这个模型了（如开始生成纪要），再查一次
        guard let downloader = model.modelDownloads.downloader(for: target), deleteBlockedReason(target) == nil else {
            return
        }
        Task {
            do {
                try await downloader.delete()
                deleteError = nil
                onDeleted(target)
            } catch {
                deleteError = "删除模型失败：\(error.localizedDescription)"
            }
        }
    }
}

/// 一个目录项的说明：下载大小、内存、速度、能力和评估结论
struct ModelDetails: View {
    let model: CatalogModel
    let role: ModelRole
    /// 要下载的总大小（含辅助模型）
    var downloadBytes: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let facts = facts { Text(facts) }
            if let capabilities = capabilitiesText { Text(capabilities) }
            if let verdict = model.verdict(for: role) { Text(verdict) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var facts: String? {
        var parts: [String] = []
        switch model.source {
        case .system: parts.append("系统自带")
        case .bundled: parts.append("已打进 App")
        case let .download(local): parts.append("下载 \(formatModelSize(downloadBytes ?? local.size))")
        }
        if let memory = model.memory { parts.append("内存\(memory)") }
        if let speed = model.speed { parts.append(speed) }
        return parts.joined(separator: " · ")
    }

    private var capabilitiesText: String? {
        guard let c = model.capabilities else { return nil }
        let timings = switch c.wordTimings {
        case .real: "逐字时间"
        case .estimated: "逐字时间：估算"
        }
        return [
            c.punctuation ? "带标点" : "无标点",
            timings,
            c.hotwords ? "支持热词" : "不使用热词表",
        ].joined(separator: " · ")
    }
}
