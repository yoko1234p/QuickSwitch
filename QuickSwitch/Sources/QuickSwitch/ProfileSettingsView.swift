import QuickSwitchCore
import SwiftUI

struct ProfileSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var editing = SwitchProfile(name: L10n.text("新配方"), steps: [.init(.keepAwake, enabled: true)])
    @State private var clock = false
    @State private var clockTime = Calendar.current.date(bySettingHour: 19, minute: 30, second: 0, of: Date()) ?? Date()
    @State private var durationMinutes = 60
    @State private var originalDuration: TimeInterval = 3600
    @State private var originalMinutes = 60
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("工作與開會配方")).font(.title3.bold())
                Text(L10n.text("只套用明確選取的開關。儲存不會執行，系統原有排程繼續有效。")).font(.caption).foregroundStyle(.secondary)
                ForEach(model.configuration.effectiveProfiles) { profile in
                    HStack {
                        Text(profile.name).font(.headline)
                        Spacer()
                        Button(L10n.text("編輯")) { load(profile) }
                        Button(L10n.text("複製捷徑連結")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                "quickswitch://profile/" + profile.id.uuidString, forType: .string)
                        }
                        Button(L10n.text("套用")) { model.applyProfile(profile.id) }.disabled(
                            model.diagnosticMode || model.applyingProfile != nil)
                        Button(role: .destructive) {
                            model.deleteProfile(profile.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                if !model.profileStatus.isEmpty { Text(model.profileStatus).font(.caption).textSelection(.enabled) }
                Divider()
                TextField(L10n.text("配方名稱"), text: $editing.name).textFieldStyle(.roundedBorder)
                ForEach(SwitchProfile.controls) { id in
                    HStack {
                        Toggle(
                            id.title,
                            isOn: Binding(
                                get: { editing.steps.contains { $0.control == id } },
                                set: { enabled in
                                    if enabled {
                                        editing.steps.append(.init(id, enabled: true))
                                    } else {
                                        editing.steps.removeAll { $0.control == id }
                                    }
                                }
                            ))
                        Spacer()
                        if editing.steps.contains(where: { $0.control == id }) {
                            Picker(
                                L10n.text("狀態"),
                                selection: Binding(
                                    get: { editing.steps.first(where: { $0.control == id })?.enabled ?? true },
                                    set: { value in
                                        if let current = editing.steps.firstIndex(where: { $0.control == id }) {
                                            editing.steps[current].enabled = value
                                        }
                                    })
                            ) {
                                Text(L10n.text("開")).tag(true)
                                Text(L10n.text("關")).tag(false)
                            }.labelsHidden().frame(width: 95)
                        }
                    }
                }
                if editing.steps.contains(where: { $0.control == .keepAwake && $0.enabled }) {
                    Toggle(L10n.text("保持清醒至指定鐘數"), isOn: $clock)
                    if clock {
                        DatePicker(L10n.text("結束時間"), selection: $clockTime, displayedComponents: .hourAndMinute)
                    } else {
                        HStack {
                            Text(L10n.text("保持清醒"))
                            TextField(L10n.text("分鐘"), value: $durationMinutes, format: .number).textFieldStyle(
                                .roundedBorder
                            ).frame(width: 85)
                            Text(L10n.text("分鐘（1–10,080）")).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button(L10n.text("新增配方")) {
                        load(.init(name: L10n.text("新配方"), steps: [.init(.keepAwake, enabled: true)]))
                    }
                    Spacer()
                    Button(L10n.text("儲存配方")) {
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: clockTime)
                        editing.awakeSeconds =
                            durationMinutes == originalMinutes ? originalDuration : TimeInterval(durationMinutes * 60)
                        editing.awakeClockMinute = clock ? (parts.hour ?? 19) * 60 + (parts.minute ?? 30) : nil
                        model.saveProfile(editing)
                    }.disabled(
                        editing.steps.isEmpty || editing.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !(1...10_080).contains(durationMinutes))
                }
            }.padding(24)
        }.onAppear { if let first = model.configuration.effectiveProfiles.first { load(first) } }
    }
    private func load(_ profile: SwitchProfile) {
        editing = profile
        clock = profile.awakeClockMinute != nil
        originalDuration = profile.awakeSeconds
        durationMinutes = max(1, min(10_080, Int(ceil(profile.awakeSeconds / 60))))
        originalMinutes = durationMinutes
        let minute = profile.awakeClockMinute ?? 1170
        clockTime =
            Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }
}

struct QuickSwitchProfileMenu: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Menu {
            ForEach(model.configuration.effectiveProfiles) { profile in
                Button(profile.name) { model.applyProfile(profile.id) }.disabled(
                    model.diagnosticMode || model.applyingProfile != nil)
            }
            Divider()
            Button(L10n.text("管理配方…")) {
                model.settingsSection = "profiles"
                model.openSettings?()
            }
        } label: {
            Image(systemName: "square.stack.3d.up").frame(width: 24, height: 28)
        }
        .help(model.profileStatus.isEmpty ? L10n.text("套用工作／開會配方") : model.profileStatus)
        .accessibilityIdentifier("quickswitch.profiles.menu")
    }
}
