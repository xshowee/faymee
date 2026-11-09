import FaymeeCore
import SwiftUI

/// 全局热词表：一行一个词，边输入边保存
struct HotwordsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Text("一行一个词，比如人名、产品名、公司术语。转写时会优先识别这些词。")
                .fixedSize(horizontal: false, vertical: true)

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
    }
}
