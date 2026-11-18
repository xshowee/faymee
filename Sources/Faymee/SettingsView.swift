import AppKit
import FaymeeCore
import SwiftUI

/// 设置窗口：录音与字幕开关、转写与纪要引擎（本机 / 在线）及服务商配置、连接测试、
/// 区分说话人开关、声纹管理入口、本机模型管理、自动更新（发布构建）
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        @Bindable var online = model.onlineSettings

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

                if model.liveCaptionsEnabled {
                    ModelPicker(role: .liveCaptions, title: "字幕模型",
                                deleteBlockedReason: { m in
                                    model.liveCaptionModelID == m.id ? "正在用它显示本场录音的字幕，录音结束后才能删除" : nil
                                })
                    if let note = liveCaptionModelNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ModelPicker(role: .liveFinalize, title: "实时字幕定稿",
                                deleteBlockedReason: { m in model.asrModelDeleteBlockedReason(m) })
                    Text(liveFinalizeNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("转写") {
                Picker("转写引擎", selection: $online.transcriptionMode) {
                    Text("本机识别").tag(EngineMode.local)
                    Text("在线模型").tag(EngineMode.online)
                }
                .pickerStyle(.segmented)

                Toggle("区分说话人", isOn: $model.diarizeSpeakers)
                Text("转写完成后始终在这台 Mac 本机区分谁在说话，录音与声纹不离开本机。关闭后只转写文字，更快；之后可以在会议里单独补上")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("纠错转写稿", isOn: $model.correctTranscripts)
                Text(CorrectionCaption.text(correctionEngine))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if online.transcriptionMode == .local {
                    ModelPicker(role: .transcription, title: "转写模型",
                                deleteBlockedReason: { m in model.asrModelDeleteBlockedReason(m) })
                    if model.modelSelections.selected(for: .transcription)?.family == .speechAnalyzer {
                        // 已有安装升级后默认还用 SpeechAnalyzer：只提示，不弹窗
                        Label("有更准的本机模型可以下载", systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("全程在本机转写，录音不离开这台 Mac。换模型后从下一场起生效，正在转写的照常转完；所选模型没下载完时，录完的会议排队等下载")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    OnlineEndpointFields(
                        provider: $online.transcriptionProvider,
                        modelName: $online.transcriptionModel,
                        baseURL: $online.transcriptionBaseURL,
                        apiKey: $online.transcriptionAPIKey,
                        config: online.activeTranscriptionConfig,
                        credentialError: online.transcriptionCredentialError,
                        testState: model.transcriptionTestState,
                        privacyCaption: "会后转写将上传完整录音音频到所选服务商",
                        onFlushSync: { model.flushOnlineSettingsSync() },
                        onTestConnection: { model.testTranscriptionConnection() }
                    )
                }
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

                ModelPicker(role: .voiceprint, title: "声纹模型",
                            deleteBlockedReason: { _ in model.voiceprintModelDeleteBlockedReason })
                VoiceprintRecomputeControls()
            }

            Section("纪要") {
                Picker("纪要引擎", selection: $online.minutesMode) {
                    Text("本机模型").tag(EngineMode.local)
                    Text("在线模型").tag(EngineMode.online)
                }
                .pickerStyle(.segmented)

                Toggle("转写完成后自动生成纪要", isOn: $model.autoGenerateMinutes)
                Text(online.minutesMode == .local
                     ? "只在接通电源时自动开始；用电池时排队，接上电源后再生成"
                     : "使用电池供电时也会在转写完成后自动开始生成")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if online.minutesMode == .local {
                    ModelPicker(role: .minutes, title: "纪要模型",
                                deleteBlockedReason: { _ in
                                    model.canDeleteModel ? nil : "正在生成纪要，生成完才能删除模型"
                                })
                    Text("纪要和纠错都在本机进行，不上传任何数据。模型只在点“下载”后才开始下载，可以暂停，中断后能续传")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    OnlineEndpointFields(
                        provider: $online.minutesProvider,
                        modelName: $online.minutesModel,
                        baseURL: $online.minutesBaseURL,
                        apiKey: $online.minutesAPIKey,
                        config: online.activeMinutesConfig,
                        credentialError: online.minutesCredentialError,
                        testState: model.minutesTestState,
                        privacyCaption: "仅上传转写文字（用于纪要和纠错）、热词、会议标题与会中笔记，录音与声纹不上传",
                        onFlushSync: { model.flushOnlineSettingsSync() },
                        onTestConnection: { model.testMinutesConnection() }
                    )
                }
            }

            // 放在最后：发布构建多这一节，窗口高度不变，要往下滚才看得到
            if model.updater.isEnabled {
                UpdateSettings(updater: model.updater)
            }
        }
        .formStyle(.grouped)
        // grouped Form 自带滚动，不给高度会被压扁；放宽尺寸以舒适容纳展开的在线配置控件
        .frame(width: 540, height: 780)
        .onDisappear {
            model.flushOnlineSettingsSync()
            model.cancelInFlightConnectionTests()
        }
    }
}

extension SettingsView {
    /// 字幕模型的说明：所选模型没下载完时说明正在用 SpeechAnalyzer；录音中改了选择时说明从下一场起生效
    private var liveCaptionModelNote: String? {
        guard let selected = model.modelSelections.selected(for: .liveCaptions) else { return nil }
        let ready = isDownloaded(selected)
        if let inUse = model.liveCaptionModelID, inUse != (ready ? selected.id : ModelCatalog.speechAnalyzerID) {
            let name = modelName(inUse)
            return "本场录音的字幕仍用 \(name)，下一场录音起生效"
        }
        guard !ready else { return nil }
        return "\(selected.name) 还没下载，实时字幕暂时用 SpeechAnalyzer（系统自带）；下载完成后，下一场录音起改用它"
    }

    /// 「纠错转写稿」说明里的纪要引擎：纠错用纪要的引擎，没就绪（模型没下载、在线配置没补齐）时说明要等它
    private var correctionEngine: CorrectionCaption.Engine {
        guard model.minutes.isModelDownloaded else { return .notReady }
        let online = model.onlineSettings
        if online.minutesMode == .online {
            return .online(provider: online.minutesProvider.displayName, model: online.minutesModel)
        }
        // 目录项名字带量化标注，如「Qwen3.5 4B（Q4_K_M）」，说明里只要模型名
        let name = MinutesEngine.selectedModel(model.modelSelections).name
        return .local(modelName: name.components(separatedBy: "（").first ?? name)
    }

    /// 实时字幕定稿的说明：做什么；所选模型没下载完时说明暂时不用；录音中改了选择时说明从下一场起生效
    private var liveFinalizeNote: String {
        let about = "每句说完后用整段模型再转一遍、替换面板里的这一句，更准但更占内存；只影响会中面板"
        let selected = model.modelSelections.selected(for: .liveFinalize)
        let ready = selected.map(isDownloaded) ?? true
        let wanted = ready ? selected?.id : nil
        if model.isRecording, model.liveFinalizeModelID != wanted {
            let inUse = model.liveFinalizeModelID.map(modelName)
            return about + "。" + (inUse.map { "本场录音仍用 \($0)" } ?? "本场录音不做实时字幕定稿") + "，下一场录音起生效"
        }
        guard let selected, !ready else { return about }
        return about + "。\(selected.name) 还没下载，实时字幕定稿暂时不用；下载完成后，下一场录音起改用它"
    }

    /// 模型能不能用：读下载器的状态（可观察），下载完成、删除后说明跟着变；不用下载的总能用
    private func isDownloaded(_ entry: CatalogModel) -> Bool {
        model.modelDownloads.downloader(for: entry)?.isReady ?? true
    }

    /// 目录项 id 的显示名
    private func modelName(_ id: String) -> String {
        model.modelSelections.catalog.model(id: id)?.name ?? id
    }
}

private protocol OnlineProviderOption: Hashable, CaseIterable {
    var displayName: String { get }
    var defaultBaseURL: String { get }
    var defaultModel: String { get }
    var suggestedModels: [String] { get }
    var requiresAPIKey: Bool { get }
    var isCustom: Bool { get }
}

extension OnlineTranscriptionProvider: OnlineProviderOption {
    var isCustom: Bool { self == .custom }
}

extension OnlineMinutesProvider: OnlineProviderOption {
    var isCustom: Bool { self == .custom }
}

/// 在线服务商端点配置表单：转写与纪要共用同一套预设、模型、接口地址、钥匙串密钥与连接测试交互
private struct OnlineEndpointFields<Provider: OnlineProviderOption>: View {
    private enum Field: Hashable { case model, baseURL, apiKey }

    @Binding var provider: Provider
    @Binding var modelName: String
    @Binding var baseURL: String
    @Binding var apiKey: String
    var config: OnlineEndpointConfig
    var credentialError: String?
    var testState: ConnectionTestState
    var privacyCaption: String
    var onFlushSync: () -> Void
    var onTestConnection: () -> Void

    @FocusState private var focusedField: Field?

    var body: some View {
        Picker("服务商", selection: $provider) {
            ForEach(Array(Provider.allCases), id: \.self) { item in
                Text(item.displayName).tag(item)
            }
        }

        LabeledContent("模型") {
            HStack(spacing: 6) {
                TextField("", text: $modelName,
                          prompt: Text(provider.defaultModel.isEmpty ? "填写模型标识" : provider.defaultModel))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .model)
                    .onSubmit(onFlushSync)
                    .frame(maxWidth: .infinity)

                if !provider.suggestedModels.isEmpty {
                    Menu {
                        ForEach(provider.suggestedModels, id: \.self) { candidate in
                            Button {
                                modelName = candidate
                                onFlushSync()
                            } label: {
                                if modelName == candidate {
                                    Label(candidate, systemImage: "checkmark")
                                } else {
                                    Text(candidate)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("选择常用模型")
                }
            }
            .frame(width: 280)
        }

        LabeledContent("接口地址") {
            HStack(spacing: 6) {
                TextField("", text: $baseURL,
                          prompt: Text(provider.isCustom
                                       ? "https://example.com/v1 或 http://192.168.1.10:8000/v1"
                                       : provider.defaultBaseURL))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .baseURL)
                    .onSubmit(onFlushSync)
                    .frame(maxWidth: .infinity)

                if !provider.isCustom, baseURL != provider.defaultBaseURL {
                    Button("恢复默认") {
                        baseURL = provider.defaultBaseURL
                        onFlushSync()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .frame(width: 280)
        }

        if let urlError = config.urlValidationError,
           !(provider.isCustom && config.trimmedBaseURL.isEmpty) {
            Label(urlError, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let warning = config.plaintextHTTPWarning {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        LabeledContent(provider.requiresAPIKey ? "API Key" : "API Key（可选）") {
            SecureField("", text: $apiKey,
                        prompt: Text(provider.requiresAPIKey ? "填写 API Key" : "可留空（免鉴权服务）"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .apiKey)
                .onSubmit(onFlushSync)
                .frame(width: 280)
        }

        if let credentialError {
            Label("钥匙串保存失败：\(credentialError)", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 8) {
            Button("测试连接") {
                onTestConnection()
            }
            .disabled(testState.isTesting)

            switch testState {
            case .idle, .failed:
                EmptyView()
            case .testing:
                ProgressView().controlSize(.small)
                Text("正在测试连接…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .succeeded:
                Label("连接成功", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Spacer()
        }

        if case let .failed(message) = testState {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text(privacyCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: focusedField) { old, _ in
                if old != nil { onFlushSync() }
            }
    }
}

/// 模型的状态、进度和操作按钮。设置里显示完整状态并可以取消；
/// 详情页（纪要、转写等任务在等模型时）只显示一句说明和下一步该点的按钮
struct ModelDownloadControls: View {
    enum Style: Equatable {
        case settings
        case minutes
        /// 某个用途的任务在等这个模型，说明写成“等待下载转写模型”
        case waiting(ModelRole)
    }

    @Environment(AppModel.self) private var model
    var style: Style
    /// 哪个模型的下载器；不给时是纪要模型的
    var downloader: ModelDownloader?

    var body: some View {
        let downloader = downloader ?? model.modelDownloader
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
            Text(text(status))
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

extension ModelDownloadControls {
    private func text(_ status: ModelDownloadStatus) -> String {
        switch style {
        case .settings: status.text
        case .minutes: status.minutesText
        case let .waiting(role): status.waitText(for: role)
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

/// 「声纹」一节里的重算声纹库：所选声纹模型与声纹库里有人的模型不同时说明人数、给出按钮；
/// 进行中显示进度和取消；结束后列出结果和受影响的人
private struct VoiceprintRecomputeControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let recomputation = model.voiceprintRecomputation
        let selected = model.selectedVoiceprintModel
        let pending = selected.map { model.voiceprints.library.peopleNeedingReenrollment(voiceprintModel: $0) } ?? []

        switch recomputation.state {
        case let .running(done, total):
            LabeledContent("重算声纹库") {
                HStack {
                    ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                        .frame(width: 120)
                    Text("\(done) / \(total) 个样本")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("取消") { recomputation.cancel() }
                }
            }
        default:
            if !pending.isEmpty {
                // 所选模型要下载、还没下好时不能重算（ModelPicker 里有下载按钮）
                let ready = model.selectedVoiceprintModelIsReady
                LabeledContent("已登记的 \(pending.count) 人需要用新模型重算") {
                    Button("重算声纹库") { model.recomputeVoiceprints() }
                        .disabled(!ready)
                }
                Text(ready
                     ? "从这些人登记时的会议录音里取他们的发言，用所选模型重新算声纹。重算前他们不参与识别"
                     : "所选声纹模型下载好后才能重算。重算前这些人不参与识别")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        switch recomputation.state {
        case let .finished(report):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(report.summary.enumerated()), id: \.offset) { _, line in Text(line) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}
