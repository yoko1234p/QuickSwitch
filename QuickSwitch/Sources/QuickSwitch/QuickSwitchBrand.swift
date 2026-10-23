import AppKit
import QuickSwitchCore
import SwiftUI

enum QuickSwitchBrand {
    static func statusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let track = NSBezierPath(
                roundedRect: NSRect(x: 0.9, y: 3.3, width: 16.2, height: 9.4), xRadius: 4.7, yRadius: 4.7)
            track.lineWidth = 1.4
            track.stroke()
            NSBezierPath(ovalIn: NSRect(x: 10.1, y: 5.4, width: 5.2, height: 5.2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = L10n.text("QuickSwitch — 系統開關")
        return image
    }
}

struct QuickSwitchBadge: View {
    var size: CGFloat = 30
    var body: some View {
        Image(nsImage: QuickSwitchBrand.statusImage())
            .resizable().renderingMode(.template).scaledToFit()
            .padding(size * 0.20).frame(width: size, height: size)
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: [Color.blue.opacity(0.8), .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.27)
            )
            .accessibilityHidden(true)
    }
}

enum DashboardCategory: String, CaseIterable, Identifiable {
    case all, display, work, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return L10n.text("全部")
        case .display: return L10n.text("顯示")
        case .work: return L10n.text("工作")
        case .system: return L10n.text("系統")
        }
    }
    var tint: Color {
        switch self {
        case .all, .display: return .blue
        case .work: return .indigo
        case .system: return .teal
        }
    }
    func includes(_ id: SwitchID) -> Bool { self == .all || id.dashboardCategory == self }
}

extension SwitchID {
    var dashboardCategory: DashboardCategory {
        switch self {
        case .stageManager, .hideWidgets, .hideDesktop, .darkMode, .screenSaver, .nightShift, .trueTone,
            .hiddenFiles, .displaySleep, .resolution, .screenClean, .hideDock:
            return .display
        case .muteMicrophone, .keepAwake, .headphones, .focus, .music, .lockKeyboard, .hideWindows:
            return .work
        case .lockScreen, .xcodeClean, .emptyTrash, .ejectDisks, .clearClipboard, .lowPower, .energyMode:
            return .system
        }
    }
}

struct SwitchGlyph: View {
    let id: SwitchID
    var size: CGFloat = 32
    var active = false
    var body: some View {
        Image(systemName: id.symbol).font(.system(size: size * 0.55, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(id.dashboardCategory.tint)
            .frame(width: size, height: size)
            .background(
                id.dashboardCategory.tint.opacity(active ? 0.15 : 0.085),
                in: RoundedRectangle(cornerRadius: size * 0.28)
            )
            .accessibilityHidden(true)
    }
}
