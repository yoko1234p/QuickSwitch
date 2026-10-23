import QuickSwitchCore
import SwiftUI

struct MusicPlayerMenu: View {
    @ObservedObject var model: AppModel
    private var selected: MusicPlayerChoice { model.configuration.musicPlayerChoice ?? .automatic }
    private var label: String {
        selected == .automatic ? model.observedMusicPlayer?.title ?? L10n.text("播放器") : selected.title
    }
    var body: some View {
        Menu {
            ForEach(MusicPlayerChoice.allCases, id: \.self) { choice in
                Button {
                    model.selectMusicPlayer(choice)
                } label: {
                    if choice == selected { Label(choice.title, systemImage: "checkmark") } else { Text(choice.title) }
                }.disabled(choice != .automatic && !model.installedMusicPlayers.contains(choice))
            }
        } label: {
            Text(label).font(.system(size: 10)).lineLimit(1)
        }.menuStyle(.borderlessButton).frame(width: 76)
            .disabled(model.busy.contains(.music))
            .help(L10n.text("選擇播放器；切換時暫停正在播放的舊選擇，不會自動播放新選擇。"))
            .accessibilityLabel(L10n.text("播放器：") + label)
            .accessibilityIdentifier("quickswitch.music.player")
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draggingID: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                QuickSwitchBadge(size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("QuickSwitch").font(.system(size: 18, weight: .semibold))
                    Text(L10n.text("安排你的開關、快捷鍵與日常習慣。"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
            HStack(spacing: 4) {
                navigationButton(L10n.text("一般"), symbol: "gearshape", section: "preferences")
                navigationButton(L10n.text("自訂"), symbol: "switch.2", section: "switches")
                navigationButton(L10n.text("快捷鍵"), symbol: "keyboard", section: "shortcuts")
                navigationButton(L10n.text("匯入"), symbol: "square.and.arrow.down", section: "migration")
                navigationButton(L10n.text("配方"), symbol: "square.stack.3d.up", section: "profiles")
            }.padding(5).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
                .padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            if model.diagnosticMode {
                Text(L10n.text("診斷模式 · 設定儲存在獨立資料夾；不會啟用系統操作、快捷鍵或排程。"))
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
            Group {
                switch model.settingsSection {
                case "preferences": preferences
                case "awake":
                    Form {
                        Section(L10n.text("保持清醒")) { KeepAwakeDurationSettings(model: model) }
                        Button(L10n.text("返回一般設定")) { model.settingsSection = "preferences" }
                    }.formStyle(.grouped)
                case "focus":
                    Form {
                        Section(L10n.text("勿擾模式")) { focusControls }
                        Button(L10n.text("返回一般設定")) { model.settingsSection = "preferences" }
                    }.formStyle(.grouped)
                case "shortcuts": shortcuts
                case "profiles": ProfileSettingsView(model: model)
                case "migration": migration
                default: switches
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 670, minHeight: 600)
            .onAppear {
                model.showingSettings = true
                model.requestRefresh()
            }
            .onDisappear {
                model.showingSettings = false
                model.panelVisibility(false)
            }
            .alert(
                L10n.text("操作未完成"),
                isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
            ) {
                Button(L10n.text("好")) { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
    }
    private func navigationButton(_ title: String, symbol: String, section: String) -> some View {
        let selected =
            model.settingsSection == section || (section == "preferences" && model.settingsSection == "awake")
        return Button {
            model.settingsSection = section
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }.frame(maxWidth: .infinity).frame(height: 34)
                .foregroundStyle(selected ? Color.blue : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(
                        selected ? Color(nsColor: .controlBackgroundColor) : Color.clear))
        }.buttonStyle(.plain).accessibilityIdentifier("quickswitch.navigation." + section)
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("錄製快捷鍵，直接切換你的開關。")).font(.headline)
            Text(model.originalRunning ? L10n.text("原版 One Switch 運行中，快捷鍵暫停註冊。") : L10n.text("與其他程式衝突的快捷鍵不會覆蓋原有註冊。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.configuration.orderedSwitches.filter { $0.knownID != nil }) { item in
                        HStack {
                            SwitchGlyph(id: item.knownID!, size: 28)
                            Text(item.title).font(.system(size: 13)).foregroundStyle(
                                item.enabled ? .primary : .secondary)
                            Spacer()
                            ShortcutRecorder(
                                value: Binding(get: { item.shortcut }, set: { model.setShortcut(item.id, value: $0) })
                            ).frame(width: 165, height: 26)
                            Button {
                                model.setShortcut(item.id, value: nil)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }.buttonStyle(.borderless).disabled(item.shortcut == nil)
                        }.padding(8)
                    }
                }
            }
            Toggle(L10n.text("啟用全域快捷鍵"), isOn: $model.configuration.hotkeysEnabled).onChange(
                of: model.configuration.hotkeysEnabled
            ) { _, _ in model.save() }
            ForEach(model.hotkeyErrors, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        }.padding(20)
    }
    private var switches: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("拖動 ⠿ 排序；關閉顯示只會隱藏入口，不會改動系統開關。")).font(.callout).foregroundStyle(.secondary)
            if model.originalRunning {
                Label(L10n.text("原版 One Switch 運行中，全域快捷鍵已暫停。"), systemImage: "pause.circle").font(.callout)
                    .foregroundStyle(
                        .orange)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.configuration.orderedSwitches) { item in
                        HStack {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).onDrag {
                                draggingID = item.id
                                return NSItemProvider(object: item.id as NSString)
                            }
                            if let id = item.knownID { SwitchGlyph(id: id, size: 28) }
                            Toggle(
                                item.title, isOn: Binding(get: { item.enabled }, set: { model.setEnabled(item.id, $0) })
                            ).toggleStyle(.checkbox).disabled(item.knownID == nil)
                            Spacer()
                            if item.knownID != nil {
                                ShortcutRecorder(
                                    value: Binding(
                                        get: { item.shortcut }, set: { model.setShortcut(item.id, value: $0) })
                                ).frame(width: 165, height: 24)
                                Button {
                                    model.setShortcut(item.id, value: nil)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                }.buttonStyle(.borderless).disabled(item.shortcut == nil)
                            } else {
                                Text(L10n.text("未支援，原始資料已保留")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.horizontal, 12).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
                            .onDrop(
                                of: [.text],
                                delegate: SwitchDropDelegate(moving: $draggingID, target: item.id, model: model))
                    }
                }
            }
            Toggle(L10n.text("啟用全域快捷鍵"), isOn: $model.configuration.hotkeysEnabled).onChange(
                of: model.configuration.hotkeysEnabled
            ) { _, _ in model.save() }
            ForEach(model.hotkeyErrors, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        }.padding(12)
    }
    private var preferences: some View {
        Form {
            Section(L10n.text("一般")) {
                Toggle(L10n.text("登入時啟動"), isOn: Binding(get: { model.loginEnabled }, set: model.setLogin)).disabled(
                    model.originalRunning && !model.loginEnabled)
                if let observed = model.configuration.sourceSystemObservation {
                    Text(
                        L10n.text("原版登入啟動：") + (observed.loginAtStartup ? L10n.text("已開啟") : L10n.text("已關閉"))
                            + L10n.text("（已保留；新版需關閉原版後再啟用）")
                    ).font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(L10n.text("輔助使用權限設定")) {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                Text(L10n.text("麥克風硬件靜音、Bluetooth、顯示器及電源模式按實際裝置支援顯示。系統操作失敗會顯示原因。")).font(.caption).foregroundStyle(
                    .secondary)
            }
            Section(L10n.text("保持清醒")) {
                KeepAwakeDurationSettings(model: model)
                Toggle(L10n.text("同時阻止系統閒置休眠"), isOn: $model.configuration.preventSystemSleep).onChange(
                    of: model.configuration.preventSystemSleep
                ) { _, _ in model.save() }
                Toggle(
                    L10n.text("合蓋時繼續運行（系統設定）"),
                    isOn: Binding(get: { model.lidSleepDisabled }, set: { model.setLidSleep($0) }))
                Text(L10n.text("此項需要管理員授權並保持電源接駁。匯入原設定不會自動更改系統合蓋行為。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("鎖定鍵盤及清潔螢幕")) {
                Picker(
                    L10n.text("自動解鎖"),
                    selection: Binding(
                        get: { model.configuration.effectiveKeyboardLockSeconds },
                        set: {
                            model.configuration.keyboardLockSeconds = $0
                            model.save()
                        })
                ) {
                    Text(L10n.text("30 秒")).tag(30.0)
                    Text(L10n.text("1 分鐘")).tag(60.0)
                    Text(L10n.text("2 分鐘")).tag(120.0)
                    Text(L10n.text("5 分鐘")).tag(300.0)
                    Text(L10n.text("10 分鐘")).tag(600.0)
                }
                Text(L10n.text("連按三次 Esc 或點清潔畫面可提早結束。系統停用事件監聽或權限改變時會自動解除；重複開啟不會延長目前時限。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("深色模式排程")) {
                Toggle(L10n.text("啟用自動排程"), isOn: $model.configuration.restoreAutomations).onChange(
                    of: model.configuration.restoreAutomations
                ) { _, enabled in
                    model.configuration.darkSchedule.enabled = enabled
                    model.save()
                }
                Picker(
                    L10n.text("排程方式"),
                    selection: Binding(
                        get: { model.configuration.effectiveDarkScheduleMode },
                        set: { value in
                            model.configuration.darkScheduleMode = value
                            model.configuration.usesSolarSchedule = value == .sunsetToSunrise
                            model.save()
                        })
                ) {
                    Text(L10n.text("手動切換")).tag(DarkScheduleMode.manual)
                    Text(L10n.text("指定時段")).tag(DarkScheduleMode.fixedTimes)
                    Text(L10n.text("日落至日出")).tag(DarkScheduleMode.sunsetToSunrise)
                }
                if model.configuration.effectiveDarkScheduleMode == .sunsetToSunrise {
                    HStack {
                        TextField(
                            L10n.text("緯度"),
                            value: Binding(
                                get: { model.configuration.solarLocation?.latitude ?? 22.3 },
                                set: {
                                    model.configuration.solarLocation = SolarLocation(
                                        latitude: $0, longitude: model.configuration.solarLocation?.longitude ?? 114.2)
                                    model.save()
                                }), format: .number)
                        TextField(
                            L10n.text("經度"),
                            value: Binding(
                                get: { model.configuration.solarLocation?.longitude ?? 114.2 },
                                set: {
                                    model.configuration.solarLocation = SolarLocation(
                                        latitude: model.configuration.solarLocation?.latitude ?? 22.3, longitude: $0)
                                    model.save()
                                }), format: .number)
                        Button(L10n.text("香港")) {
                            model.configuration.solarLocation = SolarLocation(latitude: 22.3, longitude: 114.2)
                            model.save()
                        }
                    }
                    if model.configuration.solarLocation == nil {
                        Text(L10n.text("請輸入位置或按「香港」，才會啟用日落排程。")).font(.caption).foregroundStyle(.orange)
                    }
                    if let location = model.configuration.solarLocation,
                        let solar = SolarSchedule.day(at: Date(), location: location),
                        case .events(let rise, let set) = solar
                    {
                        Text(
                            L10n.text(
                                "今日約 %1$@ 日出 · %2$@ 日落",
                                String(describing: rise.formatted(date: .omitted, time: .shortened)),
                                String(describing: set.formatted(date: .omitted, time: .shortened)))
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.configuration.effectiveDarkScheduleMode == .fixedTimes {
                    HStack {
                        DatePicker(
                            L10n.text("開啟"), selection: timeBinding(on: true), displayedComponents: .hourAndMinute)
                        DatePicker(
                            L10n.text("關閉"), selection: timeBinding(on: false), displayedComponents: .hourAndMinute)
                    }
                }
                if model.configuration.effectiveDarkScheduleMode == .manual {
                    Text(L10n.text("沿用手動切換；不會按時間自動更改外觀。")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L10n.text("耳機")) {
                Picker(
                    L10n.text("已配對耳機"),
                    selection: Binding(
                        get: { model.configuration.selectedHeadphone ?? "" },
                        set: {
                            model.configuration.selectedHeadphone = $0.isEmpty ? nil : $0
                            model.save()
                            model.requestRefresh()
                        })
                ) {
                    Text(L10n.text("自動選擇已連線耳機")).tag("")
                    ForEach(
                        model.devices.compactMap { value -> DeviceDisplay? in
                            guard let address = value["address"] as? String else { return nil }
                            return DeviceDisplay(id: address, name: value["name"] as? String ?? L10n.text("耳機"))
                        }
                    ) { device in Text(device.name).tag(device.id) }
                }
                Button(L10n.text("重新讀取")) { model.requestRefresh() }
            }
            Section(L10n.text("音樂")) {
                Picker(
                    L10n.text("播放器"),
                    selection: Binding(
                        get: { model.configuration.musicPlayerChoice ?? .automatic },
                        set: model.selectMusicPlayer)
                ) {
                    ForEach(MusicPlayerChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(model.busy.contains(.music))
                Text(L10n.text("沿用原版已選播放器。開啟會播放，關閉只會暫停；不會為暫停而啟動另一個 App。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("勿擾模式")) {
                focusControls
            }
            Section(L10n.text("磁碟及顯示器")) {
                Button(L10n.text("選擇顯示器與解像度…")) { model.presentResolution() }
                    .accessibilityIdentifier("quickswitch.resolution.open")
                TextField(
                    L10n.text("不推出的磁碟（每行一個名稱／路徑／UUID）"),
                    text: Binding(
                        get: { model.configuration.excludedVolumes.joined(separator: "\n") },
                        set: {
                            model.configuration.excludedVolumes = $0.split(separator: "\n").map(String.init)
                            model.save()
                        }), axis: .vertical)
                Toggle(L10n.text("只顯示 HiDPI 解像度"), isOn: $model.configuration.onlyHiDPI).onChange(
                    of: model.configuration.onlyHiDPI
                ) { _, _ in
                    model.save()
                    model.loadResolutions()
                }
            }
        }.formStyle(.grouped)
    }
    @ViewBuilder private var focusControls: some View {
        Text(model.focusSetupSummary).font(.caption).foregroundStyle(.secondary)
        HStack {
            Label(
                model.focusOnInstalled ? L10n.text("開啟捷徑已就緒") : L10n.text("開啟捷徑未安裝"),
                systemImage: model.focusOnInstalled ? "checkmark.circle.fill" : "circle.dashed")
            Spacer()
            Button(L10n.text("安裝開啟捷徑")) { model.installFocusShortcut(enabled: true) }
                .disabled(model.focusInstallationBusy)
        }
        HStack {
            Label(
                model.focusOffInstalled ? L10n.text("關閉捷徑已就緒") : L10n.text("關閉捷徑未安裝"),
                systemImage: model.focusOffInstalled ? "checkmark.circle.fill" : "circle.dashed")
            Spacer()
            Button(L10n.text("安裝關閉捷徑")) { model.installFocusShortcut(enabled: false) }
                .disabled(model.focusInstallationBusy)
        }
        if model.focusInstallationBusy { ProgressView(L10n.text("正用系統工具準備捷徑…")).controlSize(.small) }
        Button(L10n.text("重新檢查安裝及系統狀態")) { model.refreshFocusSetup() }
        Text(L10n.text("安裝會開啟 macOS 捷徑預覽；需由你按「加入捷徑」，之後返回此處重新檢查。加入不會立即切換勿擾，也不會改動原有捷徑。"))
            .font(.caption).foregroundStyle(.secondary)
        DisclosureGroup(L10n.text("沿用自訂捷徑")) {
            TextField(L10n.text("開啟捷徑名稱"), text: $model.configuration.focusOnShortcut).onSubmit {
                model.save()
                model.refreshFocusSetup()
            }
            TextField(L10n.text("關閉捷徑名稱"), text: $model.configuration.focusOffShortcut).onSubmit {
                model.save()
                model.refreshFocusSetup()
            }
        }
        Picker(L10n.text("關閉時限"), selection: $model.configuration.focusSeconds) {
            Text(L10n.text("手動關閉")).tag(0.0)
            Text(L10n.text("25 分鐘")).tag(1500.0)
            Text(L10n.text("30 分鐘")).tag(1800.0)
            Text(L10n.text("1 小時")).tag(3600.0)
            Text(L10n.text("2 小時")).tag(7200.0)
            Text(L10n.text("5 小時")).tag(18000.0)
            if ![0.0, 1500, 1800, 3600, 7200, 18000].contains(model.configuration.focusSeconds) {
                Text(L10n.text("原有時限：%1$@ 分鐘", String(describing: Int(model.configuration.focusSeconds / 60)))).tag(
                    model.configuration.focusSeconds)
            }
        }.onChange(of: model.configuration.focusSeconds) { _, _ in model.save() }
        Text(L10n.text("讀不到目前狀態時只會顯示上次成功操作。原版運行時，關閉時限暫停；失敗時會保留時限並稍後重試。"))
            .font(.caption).foregroundStyle(.secondary)
    }
    private func timeBinding(on: Bool) -> Binding<Date> {
        Binding(
            get: {
                let minutes =
                    on ? model.configuration.darkSchedule.onMinute : model.configuration.darkSchedule.offMinute
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date())
                    ?? Date()
            },
            set: { date in
                let minute =
                    Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
                if on {
                    model.configuration.darkSchedule.onMinute = minute
                } else {
                    model.configuration.darkSchedule.offMinute = minute
                }
                model.configuration.darkScheduleMode = .fixedTimes
                model.save()
            })
    }
    private var migration: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("One Switch 設定匯入")).font(.title2.bold())
                if let report = model.configuration.migration {
                    Text(
                        L10n.text(
                            "原版 %1$@ · %2$@ 個開關 · %3$@ 個已轉換偏好", String(describing: report.sourceVersion),
                            String(describing: report.descriptorCount),
                            String(describing: report.translatedPreferenceCount))
                    )
                    Text(
                        L10n.text(
                            "保留但未執行：%1$@ 個設定鍵、%2$@ 個未知開關、%3$@ 個快捷鍵封裝",
                            String(describing: report.untranslatedPreferenceKeys.count),
                            String(describing: report.unknownSwitchIDs.count),
                            String(describing: report.untranslatedShortcutCount))
                    ).foregroundStyle(.secondary)
                    ForEach(report.notes, id: \.self) { Text("• " + $0).font(.callout) }
                } else {
                    Text(L10n.text("尚未匯入原版設定。"))
                }
                Text(L10n.text("首次匯入及重新匯入都只讀取原版。重新匯入會先備份新版設定。登入啟動及新自動排程需要你在新版啟用。")).font(.callout)
                HStack {
                    Button(L10n.text("備份並重新匯入…")) { model.reimport() }
                    Button(L10n.text("匯出新版設定…")) { model.exportSettings() }
                    Button(L10n.text("開啟設定資料夾")) {
                        NSWorkspace.shared.open(
                            model.dataDirectory)
                    }
                }
                Text(model.importSummary).font(.caption)
                Divider()
                Text(L10n.text("原版資料庫、設定、圖案、授權及程式碼都不會被新版修改。新版以獨立 bundle ID 儲存資料，使用自行編寫的控制程式及 UI。")).font(.caption)
                    .foregroundStyle(
                        .secondary)
            }.padding(16)
        }
    }
}
private struct DeviceDisplay: Identifiable {
    let id: String
    let name: String
}

struct ResolutionView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    private var visibleModes: [DisplayModeDescriptor] {
        model.resolutionChoices.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("螢幕解像度")).font(.title2.bold())
            Text(L10n.text("更改後有 15 秒確認；沒有確認便自動還原。關閉 QuickSwitch 亦會還原未確認的更改。")).font(.callout).foregroundStyle(
                .secondary)
            Picker(
                L10n.text("顯示器"),
                selection: Binding(get: { model.selectedResolutionDisplay }, set: model.selectResolutionDisplay)
            ) {
                if model.selectedResolutionDisplay == nil { Text(L10n.text("所選顯示器未連接")).tag(UInt32?.none) }
                ForEach(model.resolutionDisplays) { display in
                    Text("\(display.sourceIndex + 1) · \(display.title)").tag(Optional(display.id))
                }
            }.accessibilityIdentifier("quickswitch.resolution.display")
            if model.savedResolutionDisplayMissing {
                Text(L10n.text("已儲存的顯示器未連接。請選擇已連接的螢幕；不會自動改用另一個顯示器。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let current = model.currentResolutionMode {
                    Label(L10n.text("目前：") + current.title, systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    "HiDPI",
                    isOn: Binding(
                        get: { model.configuration.onlyHiDPI },
                        set: {
                            model.configuration.onlyHiDPI = $0
                            model.save()
                            model.loadResolutions()
                        })
                ).toggleStyle(.checkbox)
            }
            TextField(L10n.text("搜尋解像度或更新率"), text: $query).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("quickswitch.resolution.search")
            if let deadline = model.resolutionConfirmationDeadline {
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(
                            L10n.text(
                                "%1$@ 秒內確認",
                                String(describing: max(0, Int(ceil(deadline.timeIntervalSince(context.date)))))))
                    }
                    Button(L10n.text("保留")) { model.keepResolution() }
                    Button(L10n.text("還原")) { model.restoreResolution() }
                }
            }
            List(visibleModes) { choice in
                HStack {
                    Text(choice.title)
                    Spacer()
                    if choice.modeID == model.currentResolutionMode?.modeID {
                        Label(L10n.text("目前"), systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(L10n.text("使用")) { model.applyResolution(choice.id) }.disabled(
                            model.resolutionConfirmationDeadline != nil || model.diagnosticMode)
                    }
                }
            }
            if visibleModes.isEmpty {
                Text(L10n.text("沒有符合的可用模式。試下更改搜尋或 HiDPI 篩選。")).font(.caption).foregroundStyle(.secondary)
            }
            if model.diagnosticMode {
                Text(L10n.text("診斷模式只讀取顯示器及模式，不會更改解像度。")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).frame(width: 650, height: 560)
            .alert(
                L10n.text("操作未完成"),
                isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
            ) {
                Button(L10n.text("好")) { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
    }
}
struct EnergyView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("電源模式")).font(.title2.bold())
            Text(L10n.text("macOS 可能需要管理員密碼。高耗電模式只供支援的 Mac 使用；不支援時會回報系統錯誤。")).font(.callout)
            Button(L10n.text("自動")) {
                Task {
                    do {
                        try await model.backend.setHighPowerMode(0)
                        model.requestRefresh()
                    } catch { model.error = error.localizedDescription }
                }
            }
            Button(L10n.text("低耗電")) {
                Task {
                    do {
                        try await model.backend.setHighPowerMode(1)
                        model.requestRefresh()
                    } catch { model.error = error.localizedDescription }
                }
            }
            Button(L10n.text("高耗電")) {
                Task {
                    do {
                        try await model.backend.setHighPowerMode(2)
                        model.requestRefresh()
                    } catch { model.error = error.localizedDescription }
                }
            }
        }.padding(24).frame(width: 430, height: 270)
            .alert(
                L10n.text("操作未完成"),
                isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
            ) {
                Button(L10n.text("好")) { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
    }
}

@MainActor
private struct SwitchDropDelegate: DropDelegate {
    @Binding var moving: String?
    let target: String
    let model: AppModel
    func validateDrop(info: DropInfo) -> Bool { moving != nil && moving != target }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard let moving, moving != target else {
            self.moving = nil
            return false
        }
        model.move(moving, relativeTo: target, after: info.location.y > 20)
        self.moving = nil
        return true
    }
}
