import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isRecording {
            HStack(spacing: 4) {
                Image(systemName: model.isSilent || model.hasRecordingError || model.isLidGapOpen
                      ? "exclamationmark.triangle.fill" : "record.circle.fill")
                Text(formatDuration(model.elapsed))
                    .monospacedDigit()
            }
        } else {
            Image(systemName: "waveform")
        }
    }
}

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isRecording {
                recordingSection
            } else {
                MicrophonePicker()
                Button {
                    Task { await model.start() }
                } label: {
                    Label("开始录音", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button("会议记录…") {
                openWindow(id: "meetings")
                NSApp.activate()
            }
            .buttonStyle(.plain)

            Button(model.isRecording ? "停止录音并退出" : "退出 Faymee") {
                // 正在整理的录音下次启动时会自动续上
                model.stop()
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 280)
        .task { await model.refreshSleepState() }
    }

    @ViewBuilder private var recordingSection: some View {
        HStack {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text("录音中")
            Spacer()
            Text(formatDuration(model.elapsed))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }

        LevelMeter(db: model.levelDB)

        MicrophonePicker()

        if model.isLidGapOpen {
            Label("已合盖，内置麦克风被断开，现在没有在录。请打开盖子，或改用外接麦克风。",
                  systemImage: "mic.slash.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.isSilent {
            Label("长时间没有声音，请检查麦克风。", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        let missed = model.current?.lidGaps.filter { $0.end != nil } ?? []
        if !missed.isEmpty {
            Text("本次有 \(missed.count) 段因合盖没有录到声音，可在会议记录里查看")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if SystemState.isLidClosed != true {
            Button {
                SystemState.sleepDisplay()
            } label: {
                Label("熄屏继续录音", systemImage: "moon.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            Text(model.sleepDisabled
                 ? "熄屏后请保持盖子打开，内置麦克风才能收音"
                 : "Caffy 未开启：熄屏后系统可能会休眠，录音会中断")
                .font(.caption)
                .foregroundStyle(model.sleepDisabled ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        Button {
            model.stop()
        } label: {
            Label("停止录音", systemImage: "stop.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
    }
}

/// 麦克风选择，以及实际在用（或将要用）哪个设备
struct MicrophonePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: $model.inputSelection) {
                Text("自动").tag(InputSelection.automatic)
                Text("跟随系统设置").tag(InputSelection.systemDefault)
                Divider()
                ForEach(model.inputDevices) { d in
                    Text("\(d.name)（\(d.kind.label)）").tag(InputSelection.device(uid: d.uid))
                }
                if let missing = missingSelection {
                    Text("\(model.selectedDeviceName ?? "已选设备")（未连接）").tag(missing)
                }
            } label: {
                Image(systemName: "mic")
            }
            .pickerStyle(.menu)

            ForEach(notes, id: \.text) { note in
                Text(note.text)
                    .font(.caption)
                    .foregroundStyle(note.warning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 指定的设备当前没连接
    private var missingSelection: InputSelection? {
        guard case let .device(uid) = model.inputSelection,
              !model.inputDevices.contains(where: { $0.uid == uid })
        else { return nil }
        return model.inputSelection
    }

    private var notes: [(text: String, warning: Bool)] {
        let device = model.isRecording ? model.recordingDevice : model.plannedDevice
        guard let device else { return [("没有可用的麦克风", true)] }
        var notes: [(String, Bool)] = []
        if missingSelection != nil {
            notes.append(("“\(model.selectedDeviceName ?? "已选设备")”未连接，暂时使用 \(device.name)，连上后自动切回", true))
        } else {
            notes.append(((model.isRecording ? "正在使用：" : "将使用：") + device.name, false))
        }
        switch device.kind {
        case .builtIn where SystemState.isLidClosed == true && !model.isRecording:
            notes.append(("已合盖，内置麦克风无法收音。请打开盖子或接入外接麦克风", true))
        case .bluetooth:
            notes.append(("蓝牙耳机做麦克风时音质较差，且只能收到佩戴者的声音", true))
        case .virtual:
            notes.append(("这是虚拟音频设备，不是真实麦克风", true))
        default:
            break
        }
        return notes
    }
}

/// 电平条：-60 dB 到 0 dB 线性映射
struct LevelMeter: View {
    var db: Float

    var body: some View {
        GeometryReader { geo in
            let fraction = CGFloat(min(max((db + 60) / 60, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(fraction > 0.9 ? Color.orange : Color.green)
                    .frame(width: geo.size.width * fraction)
                    .animation(.linear(duration: 0.08), value: fraction)
            }
        }
        .frame(height: 6)
    }
}
