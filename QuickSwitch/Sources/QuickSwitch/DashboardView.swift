import QuickSwitchCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var category: DashboardCategory = .all

    private var items: [SwitchConfiguration] {
        model.visibleItems.filter { $0.knownID.map(category.includes) == true }
    }
    private var panelHeight: CGFloat {
        let notices: CGFloat = (model.originalRunning ? 28 : 0) + (model.diagnosticMode ? 40 : 0)
        let accessorySpace: CGFloat =
            (items.contains { $0.knownID == .music } ? 16 : 0)
            + (items.contains { $0.knownID == .keepAwake } ? 16 : 0)
        return min(model.dashboardMaximumHeight, max(320, 188 + notices + CGFloat(items.count) * 56 + accessorySpace))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            search
            categories
            if model.diagnosticMode {
                Label(L10n.text("診斷模式 · 系統操作已停用"), systemImage: "stethoscope")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
            }
            if model.originalRunning {
                Label(L10n.text("One Switch 運行中 · 快捷鍵與排程暫停"), systemImage: "pause.circle")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 6)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        if let id = item.knownID {
                            DashboardSwitchRow(
                                item: item, id: id, state: model.states[id] ?? .unknown(L10n.text("讀取中")),
                                busy: model.busy.contains(id), canMutate: !model.diagnosticMode,
                                musicMenu: id == .music ? MusicPlayerMenu(model: model) : nil,
                                awakeMenu: id == .keepAwake ? KeepAwakeDurationMenu(model: model) : nil
                            ) { desired in model.activate(id, desired: desired) }
                            if item.id != items.last?.id {
                                Divider().opacity(0.6).padding(.leading, 54).padding(.trailing, 8)
                            }
                        }
                    }
                    if items.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "switch.2").font(.system(size: 22)).foregroundStyle(.tertiary)
                            Text(L10n.text("沒有符合的開關")).font(.system(size: 12, weight: .semibold))
                            Text(L10n.text("試試其他分類或搜尋字詞，亦可在下方自訂開關。"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).frame(maxWidth: 250)
                        }.frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }.padding(.horizontal, 8).padding(.vertical, 4)
            }.scrollIndicators(.automatic)
            footer
        }.frame(width: 352, height: panelHeight)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear { model.panelVisibility(true) }
            .onDisappear { model.panelVisibility(false) }
            .alert(
                L10n.text("操作未完成"),
                isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
            ) {
                Button(L10n.text("好")) { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
    }

    private var header: some View {
        HStack(spacing: 10) {
            QuickSwitchBadge(size: 28)
            Text("QuickSwitch").font(.system(size: 14, weight: .semibold))
            Spacer()
            QuickSwitchProfileMenu(model: model)
            Button {
                model.requestRefresh()
            } label: {
                Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
            }.help(L10n.text("重新讀取系統狀態")).accessibilityLabel(L10n.text("重新讀取系統狀態"))
        }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }
    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(L10n.text("搜尋開關"), text: $model.query).textFieldStyle(.plain).font(.system(size: 12))
                .accessibilityLabel(L10n.text("搜尋開關")).accessibilityIdentifier("quickswitch.search")
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityLabel(L10n.text("清除搜尋"))
            }
        }.padding(.horizontal, 10).frame(height: 31)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 14)
    }
    private var categories: some View {
        HStack(spacing: 4) {
            ForEach(DashboardCategory.allCases) { value in
                Button {
                    category = value
                } label: {
                    Text(value.title).font(.system(size: 11.5, weight: category == value ? .semibold : .regular))
                        .frame(maxWidth: .infinity).frame(height: 27)
                        .foregroundStyle(category == value ? Color.primary : Color.secondary)
                        .background(
                            category == value ? Color.primary.opacity(0.075) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
                    .accessibilityValue(category == value ? "已選取" : "未選取")
                    .accessibilityIdentifier("quickswitch.category." + value.rawValue)
            }
        }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 9)
    }
    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.6)
            HStack {
                Button {
                    model.settingsSection = "preferences"
                    model.openSettings?()
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 15)).frame(width: 30, height: 30)
                }.help(L10n.text("偏好設定")).accessibilityLabel(L10n.text("偏好設定")).accessibilityIdentifier(
                    "quickswitch.settings")
                Spacer()
                Button {
                    model.settingsSection = "switches"
                    model.openSettings?()
                } label: {
                    Text(L10n.text("自訂開關")).font(.system(size: 12, weight: .medium))
                        .frame(width: 140, height: 28)
                        .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityIdentifier("quickswitch.customize")
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power").font(.system(size: 15)).frame(width: 30, height: 30)
                }.help(L10n.text("結束 QuickSwitch")).keyboardShortcut("q").accessibilityLabel(
                    L10n.text("結束 QuickSwitch")
                )
                .accessibilityIdentifier("quickswitch.quit")
            }.buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 8)
        }.background(Color.primary.opacity(0.018))
    }
}

private struct DashboardSwitchRow: View {
    let item: SwitchConfiguration
    let id: SwitchID
    let state: SwitchState
    let busy: Bool
    let canMutate: Bool
    let musicMenu: MusicPlayerMenu?
    let awakeMenu: KeepAwakeDurationMenu?
    let action: (Bool?) -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 11) {
            SwitchGlyph(id: id, active: state.isOn == true)
                .opacity(state.canActivate ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1).help(item.title)
                if !state.detail.isEmpty {
                    Text(state.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        .help(state.detail)
                }
                if let musicMenu { musicMenu }
                if let awakeMenu { awakeMenu }
            }
            Spacer(minLength: 6)
            control
        }.padding(.horizontal, 9).padding(.vertical, 8).frame(minHeight: 55)
            .background(
                hovered ? Color.primary.opacity(0.045) : state.isOn == true ? Color.blue.opacity(0.035) : .clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9)).onHover { hovered = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("quickswitch.item.\(id.rawValue)")
            .contextMenu {
                if !id.isAction {
                    Button(L10n.text("開啟")) { action(true) }.disabled(!state.canActivate || !canMutate)
                    Button(L10n.text("關閉")) { action(false) }.disabled(!state.canActivate || !canMutate)
                }
            }
    }

    @ViewBuilder private var control: some View {
        if busy {
            ProgressView().controlSize(.small).frame(width: 42)
        } else if let isOn = state.isOn, !id.isAction {
            Toggle(item.title, isOn: Binding(get: { isOn }, set: { action($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.regular).tint(.blue)
                .disabled(!canMutate)
        } else if id == .focus {
            Menu {
                Button(L10n.text("開啟勿擾")) { action(true) }
                Button(L10n.text("關閉勿擾")) { action(false) }
            } label: {
                Text(L10n.text("選擇")).font(.system(size: 11, weight: .medium))
            }.menuStyle(.borderlessButton).frame(width: 52)
                .help(L10n.text("目前狀態未能確認；選擇開啟或關閉"))
                .disabled(!canMutate)
        } else if !state.canActivate {
            Text(L10n.text("不可用")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                .help(state.detail).frame(minWidth: 42)
        } else {
            Button {
                action(nil)
            } label: {
                HStack(spacing: 3) {
                    Text(id.isAction ? L10n.text("執行") : L10n.text("切換"))
                    Image(systemName: id.isAction ? "chevron.right" : "arrow.triangle.2.circlepath").font(
                        .system(size: 8))
                }.font(.system(size: 10.5, weight: .medium)).frame(width: 49, height: 26)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).disabled(!canMutate).help(state.detail.isEmpty ? L10n.text("執行") : state.detail)
        }
    }
}
