import FaymeeCore
import SwiftUI

/// 全局热词表：一行一个词，边输入边保存
struct HotwordsView: View {
    @Environment(AppModel.self) private var model
    /// 会后转写所选模型用不用得上热词表（要读 tokenizer，在后台算）
    @State private var usageNote: String?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Text("一行一个词，比如人名、产品名、公司术语。转写时会优先识别这些词。")
                .fixedSize(horizontal: false, vertical: true)
            if let usageNote {
                Label(usageNote, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = liveCaptionsNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $model.hotwordsText)
                .font(.body)
                .autocorrectionDisabled()
                .border(.separator)

            if let error = model.hotwordsError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("共 \(model.hotwords.count) 个词")
                Spacer()
                Text("只影响之后的转写，已有会议不会自动重新转写")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(minWidth: 300, minHeight: 240)
        // 文件可能在 App 外被改过，打开时重新载入；关窗口时把还没写盘的修改存下
        .onAppear { model.reloadHotwords() }
        .onDisappear { model.saveHotwords() }
        .task(id: UsageInput(model: transcriptionModel, hotwords: model.hotwords,
                             downloaded: transcriptionModel.flatMap { model.modelDownloads.downloader(for: $0)?.isReady })) {
            await refreshUsageNote()
        }
    }
}

extension HotwordsView {
    private struct UsageInput: Equatable {
        var model: CatalogModel?
        var hotwords: [String]
        /// 下载完成后才有 tokenizer 算预算，下好时重算
        var downloaded: Bool?
    }

    /// 本机转写时选中的会后转写模型；在线转写时为 nil（热词交给在线服务，这里不评判）
    private var transcriptionModel: CatalogModel? {
        model.onlineSettings.transcriptionMode == .local ? model.modelSelections.selected(for: .transcription) : nil
    }

    /// 停止输入一会儿后在后台算一次（读 tokenizer 约 0.1 秒）
    private func refreshUsageNote() async {
        guard let selected = transcriptionModel else {
            usageNote = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let hotwords = model.hotwords
        let directory = model.modelDownloads.directory
        let note = await Task.detached(priority: .utility) {
            HotwordUsage(model: selected, hotwords: hotwords, modelDirectory: directory).note
        }.value
        guard !Task.isCancelled else { return }
        usageNote = note
    }

    /// 实时字幕选的是 X-ASR 时它不用热词表（用了只能等停顿才定稿，字幕晚十几秒），说明一下，免得以为字幕里也会生效
    private var liveCaptionsNote: String? {
        guard model.liveCaptionsEnabled, let selected = model.modelSelections.selected(for: .liveCaptions),
              selected.family == .sherpaOnlineTransducer else { return nil }
        return "实时字幕（\(selected.name)）不使用热词表；会后转写照常使用"
    }
}
