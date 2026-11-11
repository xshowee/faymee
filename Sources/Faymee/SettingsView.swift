import AppKit
import FaymeeCore
import SwiftUI

/// 设置窗口：全局快捷键和实时字幕开关、区分说话人开关、声纹管理入口、纪要的自动生成开关、本机模型的下载与删除、
/// 自动更新（发布构建）
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingDelete = false
    @State private var deleteError: String?

    var body: some View {
        @Bindable var model = model
        let downloader = model.modelDownloader

        Form {
            Section("录音") {
                Toggle("全局快捷键", isOn: $model.globalShortcutsEnabled)
                Text("录音时在任何 App 里按 \(LiveShortcut.mark.label) 标记重点、\(LiveShortcut.note.label) 记一笔。只在录音期间生效，不录音时不占用这两个组合键")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("实时字幕", isOn: $model.liveCaptionsEnabled)
                Text("录音时在会中面板里显示正在说的话，全程在本机识别、不存盘，只在面板看得见时运行。关闭后面板只显示标注和笔记输入框；会后照常转写")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("转写") {
                Toggle("区分说话人", isOn: $model.diarizeSpeakers)
                Text("转写时在本机区分谁在说话。关闭后只转写文字，更快；之后可以在会议里单独补上")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("声纹") {
                LabeledContent(model.voiceprints.loadError == nil
                               ? "已登记 \(model.voiceprints.library.people.count) 人" : "声纹库读取失败") {
                    Button("管理声纹…") { openWindow(id: "voiceprints") }
                }
                Text("登记过的人在之后的会议里会被自动认出。声纹只存在本机，只在你在会议里点“记住这个声音”时登记")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("纪要") {
                Toggle("转写完成后自动生成纪要", isOn: $model.autoGenerateMinutes)
                Text("只在接通电源时自动开始；用电池时排队，接上电源后再生成")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("本机模型") {
                LabeledContent("Qwen3 4B（Q4_K_M）") {
                    ModelDownloadControls(style: .settings)
                }
                Text("纪要在本机生成，不上传任何数据。模型约 \(formatGigabytes(downloader.model.size))，只在点“下载”后才开始下载，可以暂停，中断后能续传")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if downloader.isReady {
                    HStack {
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([downloader.model.url(in: downloader.directory)])
                        }
                        Spacer()
                        Button("删除模型…", role: .destructive) { confirmingDelete = true }
                            .disabled(!model.canDeleteModel)
                    }
                    if !model.canDeleteModel {
                        Text("正在生成纪要，生成完才能删除模型")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let deleteError {
                    Label(deleteError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            // 放在最后：发布构建多这一节，窗口高度不变，要往下滚才看得到
            if model.updater.isEnabled {
                UpdateSettings(updater: model.updater)
            }
        }
        .formStyle(.grouped)
        // grouped Form 自带滚动，不给高度会被压扁；开发构建内容最多时（已就绪 + 删除说明 + 错误）也放得下
        .frame(width: 480, height: 730)
        .confirmationDialog("删除纪要模型？", isPresented: $confirmingDelete) {
            Button("删除模型", role: .destructive) {
                Task {
                    do {
                        try await model.deleteModel()
                        deleteError = nil
                    } catch {
                        deleteError = "删除模型失败：\(error.localizedDescription)"
                    }
                }
            }
        } message: {
            Text("释放约 \(formatGigabytes(downloader.model.size)) 空间。之后生成纪要需要重新下载，已生成的纪要不受影响。")
        }
    }
}

/// 模型的状态、进度和操作按钮。设置里显示完整状态并可以取消；
/// 详情页（纪要在等模型时）只显示一句说明和下一步该点的按钮
struct ModelDownloadControls: View {
    enum Style { case settings, minutes }

    @Environment(AppModel.self) private var model
    var style: Style

    var body: some View {
        let downloader = model.modelDownloader
        let status = downloader.status

        HStack(spacing: 6) {
            switch status.phase {
            case .downloading, .paused:
                ProgressView(value: status.progress)
                    .frame(width: 80)
            case .verifying:
                ProgressView().controlSize(.small)
            default:
                EmptyView()
            }
            Text(style == .settings ? status.text : status.minutesText)
                .monospacedDigit()
                .foregroundStyle(status.phase.isFailed ? Color.orange : Color.secondary)
                .lineLimit(2)

            switch status.phase {
            case .notDownloaded:
                Button("下载") { downloader.start() }
            case .downloading:
                Button("暂停") { downloader.pause() }
            case .paused:
                Button("继续下载") { downloader.start() }
            case .failed:
                Button("重试") { downloader.start() }
            case .verifying, .ready:
                EmptyView()
            }
            if style == .settings, status.phase.isCancellable, status.receivedBytes > 0 {
                Button("取消") { Task { await downloader.cancel() } }
                    .help("停止下载并删掉已下载的部分")
            }
        }
    }
}

private extension ModelDownloadPhase {
    var isFailed: Bool {
        if case .failed = self { true } else { false }
    }

    /// 有没下完的部分可以丢掉
    var isCancellable: Bool {
        switch self {
        case .downloading, .paused, .failed: true
        default: false
        }
    }
}

/// 设置里的“更新”一节：当前版本、自动检查开关、手动检查。只在发布构建显示
private struct UpdateSettings: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        Section("更新") {
            LabeledContent("当前版本 \(Self.version)") {
                Button("检查更新…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            Toggle("自动检查更新", isOn: $updater.automaticallyChecks)
            Text("每天在 GitHub 上查一次有没有新版本，只取版本信息，不上传任何会议内容。发现新版本时在菜单栏面板里提示，不会弹窗打断")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
}
