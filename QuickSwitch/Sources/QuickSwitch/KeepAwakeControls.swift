import QuickSwitchCore
import SwiftUI

struct KeepAwakeDurationMenu: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Menu {
            ForEach(KeepAwakeDuration.presets, id: \.self) { seconds in
                Button {
                    model.setKeepAwakeDuration(seconds)
                } label: {
                    if model.configuration.awakeClockMinute == nil && model.configuration.keepAwakeSeconds == seconds {
                        Label(KeepAwakeDuration.title(seconds), systemImage: "checkmark")
                    } else {
                        Text(KeepAwakeDuration.title(seconds))
                    }
                }
            }
            Divider()
            Button(L10n.text("自訂時長…")) {
                model.settingsSection = "awake"
                model.openSettings?()
            }
            Button(L10n.text("指定結束時間…")) {
                _ = model.setKeepAwakeClock(model.configuration.awakeClockMinute ?? 1170)
                model.settingsSection = "awake"
                model.openSettings?()
            }
            if model.backend.awakeIsActive {
                Button(L10n.text("套用時限並重新計時")) {
                    if let minute = model.configuration.awakeClockMinute {
                        model.setKeepAwakeClock(minute, restartCurrent: true)
                    } else {
                        model.setKeepAwakeDuration(model.configuration.keepAwakeSeconds, restartCurrent: true)
                    }
                }.disabled(model.diagnosticMode)
            }
        } label: {
            Label(model.awakePlanTitle, systemImage: "clock")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
        }.menuStyle(.borderlessButton).fixedSize(horizontal: true, vertical: false)
            .disabled(model.busy.contains(.keepAwake))
            .help(L10n.text("設定下次保持清醒的時長；已開啟時可選擇重新計時。"))
            .accessibilityLabel(L10n.text("保持清醒時限：") + model.awakePlanTitle)
            .accessibilityIdentifier("quickswitch.awake.duration-menu")
    }
}

struct KeepAwakeDurationSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Picker(
            L10n.text("設定方式"),
            selection: Binding(
                get: { model.configuration.awakeClockMinute == nil ? "duration" : "clock" },
                set: { value in
                    if value == "clock" {
                        model.setKeepAwakeClock(1170)
                    } else {
                        model.setKeepAwakeDuration(model.configuration.keepAwakeSeconds)
                    }
                }
            )
        ) {
            Text(L10n.text("一段時間")).tag("duration")
            Text(L10n.text("指定鐘數")).tag("clock")
        }
        if model.configuration.awakeClockMinute != nil {
            AwakeClockSettings(model: model)
        } else {
            KeepAwakeDurationEditor(model: model)
        }
    }
}

struct AwakeClockSettings: View {
    @ObservedObject var model: AppModel
    @State private var hour = "19"
    @State private var minute = "30"
    @State private var saved = ""
    private var selected: Int? {
        guard let h = Int(hour), let m = Int(minute), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
    var body: some View {
        Group {
            HStack {
                TextField(L10n.text("時"), text: $hour).labelsHidden().frame(width: 55).accessibilityIdentifier(
                    "quickswitch.awake.clock-hour")
                Text(":")
                TextField(L10n.text("分"), text: $minute).labelsHidden().frame(width: 55).accessibilityIdentifier(
                    "quickswitch.awake.clock-minute")
                Spacer()
                Button(L10n.text("儲存時間")) {
                    if let selected, model.setKeepAwakeClock(selected) {
                        saved = L10n.text("已儲存：") + AwakeClock.title(selected)
                    }
                }
                .disabled(selected == nil).accessibilityIdentifier("quickswitch.awake.clock-save")
            }.textFieldStyle(.roundedBorder)
            if let selected, let deadline = try? AwakeClock.next(minute: selected, after: Date()) {
                Text(
                    (Calendar.current.isDateInToday(deadline) ? L10n.text("今日 ") : L10n.text("聽日 "))
                        + deadline.formatted(date: .omitted, time: .shortened) + L10n.text(" 結束。儲存只影響下次開啟。")
                )
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L10n.text("請輸入 00:00 至 23:59。")).font(.caption).foregroundStyle(.orange)
            }
            if !saved.isEmpty { Text(saved).font(.caption).foregroundStyle(.secondary) }
            if model.backend.awakeIsActive {
                Button(L10n.text("套用至本次保持清醒")) {
                    if let selected { model.setKeepAwakeClock(selected, restartCurrent: true) }
                }
                .disabled(selected == nil || model.diagnosticMode)
            }
            Text(L10n.text("使用 Mac 目前時區。已過的鐘數會安排到翌日；不會自動開啟保持清醒。")).font(.caption).foregroundStyle(.secondary)
        }.onAppear {
            let value = model.configuration.awakeClockMinute ?? 1170
            hour = String(value / 60)
            minute = String(value % 60)
        }
    }
}

struct KeepAwakeDurationEditor: View {
    @ObservedObject var model: AppModel
    @State private var editingCustom = false
    @State private var hours = ""
    @State private var minutes = ""
    @State private var savedMessage: String?

    private var customSelected: Bool {
        editingCustom || !KeepAwakeDuration.presets.contains(model.configuration.keepAwakeSeconds)
    }
    private var customResult: Result<TimeInterval, Error> {
        Result { try KeepAwakeDuration.custom(hours: hours, minutes: minutes) }
    }
    private var selectedSeconds: TimeInterval? {
        customSelected ? try? customResult.get() : model.configuration.keepAwakeSeconds
    }

    var body: some View {
        Picker(
            L10n.text("時限"),
            selection: Binding(
                get: { customSelected ? -1.0 : model.configuration.keepAwakeSeconds },
                set: { seconds in
                    savedMessage = nil
                    if seconds == -1 {
                        loadFields()
                        editingCustom = true
                    } else if model.setKeepAwakeDuration(seconds) {
                        editingCustom = false
                        loadFields()
                    }
                })
        ) {
            ForEach(KeepAwakeDuration.presets, id: \.self) { seconds in
                Text(KeepAwakeDuration.title(seconds)).tag(seconds)
            }
            Text(L10n.text("自訂時長…")).tag(-1.0)
        }.accessibilityIdentifier("quickswitch.awake.duration-picker").onAppear(perform: loadFields)
        if customSelected {
            HStack(spacing: 8) {
                TextField(L10n.text("小時"), text: $hours).labelsHidden().frame(width: 64)
                    .accessibilityLabel(L10n.text("自訂小時")).accessibilityIdentifier("quickswitch.awake.hours")
                Text(L10n.text("小時"))
                TextField(L10n.text("分鐘"), text: $minutes).labelsHidden().frame(width: 64)
                    .accessibilityLabel(L10n.text("自訂分鐘")).accessibilityIdentifier("quickswitch.awake.minutes")
                Text(L10n.text("分鐘"))
                Spacer()
                Button(L10n.text("儲存時長")) { save(restart: false) }
                    .disabled(selectedSeconds == nil || model.busy.contains(.keepAwake))
                    .accessibilityIdentifier("quickswitch.awake.save")
            }.textFieldStyle(.roundedBorder)
                .onChange(of: hours) { _, _ in savedMessage = nil }
                .onChange(of: minutes) { _, _ in savedMessage = nil }
            if case .failure(let error) = customResult {
                Text(error.localizedDescription).font(.caption).foregroundStyle(.orange)
            } else {
                Text(L10n.text("自訂 1 分鐘至 7 日。")).font(.caption).foregroundStyle(.secondary)
            }
        }
        if let savedMessage {
            Text(savedMessage).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("quickswitch.awake.saved")
        }
        if model.backend.awakeIsActive {
            HStack {
                Label(model.states[.keepAwake]?.detail ?? L10n.text("保持清醒中"), systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("套用並重新計時")) { save(restart: true) }
                    .disabled(selectedSeconds == nil || model.busy.contains(.keepAwake) || model.diagnosticMode)
                    .accessibilityIdentifier("quickswitch.awake.restart")
            }
            Text(L10n.text("修改時長只影響下次開啟；要更新本次結束時間，請按「套用並重新計時」。"))
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(L10n.text("下次開啟時開始計時；儲存設定不會自行開啟保持清醒。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadFields() {
        let value = model.configuration.keepAwakeSeconds
        let totalMinutes = value > 0 ? Int(ceil(value / 60)) : 30
        hours = String(totalMinutes / 60)
        minutes = String(totalMinutes % 60)
    }
    private func save(restart: Bool) {
        guard let seconds = selectedSeconds else { return }
        if model.setKeepAwakeDuration(seconds, restartCurrent: restart) {
            savedMessage = (restart ? L10n.text("已重新計時：") : L10n.text("已儲存：")) + KeepAwakeDuration.title(seconds)
        }
    }
}
