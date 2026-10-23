import Foundation

/// Retain exact application instances, not reusable PIDs or every hidden application.
/// Failed restores stay owned so an explicit Off can retry them.
@MainActor
public final class HiddenApplicationsSession<Application> {
    private struct Entry {
        let application: Application
        var confirmed = false
    }
    private var owned: [Entry] = []
    private var changing = false
    private let applications: () -> [Application]
    private let terminated: (Application) -> Bool
    private let hidden: (Application) -> Bool
    private let hide: (Application) -> Bool
    private let unhide: (Application) -> Bool
    private let sameInstance: (Application, Application) -> Bool

    public init(
        applications: @escaping () -> [Application], terminated: @escaping (Application) -> Bool,
        hidden: @escaping (Application) -> Bool, hide: @escaping (Application) -> Bool,
        unhide: @escaping (Application) -> Bool, sameInstance: @escaping (Application, Application) -> Bool
    ) {
        self.applications = applications
        self.terminated = terminated
        self.hidden = hidden
        self.hide = hide
        self.unhide = unhide
        self.sameInstance = sameInstance
    }

    public var isActive: Bool {
        discardReleasedApplications()
        return !owned.isEmpty
    }

    public var state: SwitchState {
        discardReleasedApplications()
        if changing || owned.contains(where: { !$0.confirmed }) {
            return .unknown(L10n.text("隱藏請求尚未確認；可按關閉還原，或重新開啟再試。"))
        }
        return .toggle(!owned.isEmpty, L10n.text("關閉只還原由 QuickSwitch 隱藏的 App"))
    }

    public func set(_ desired: Bool?) async throws {
        guard !changing else { throw ConfigurationError.invalid(L10n.text("視窗操作尚未完成")) }
        changing = true
        defer { changing = false }
        discardReleasedApplications()
        let enabled = desired ?? owned.isEmpty
        var failures = 0
        if enabled {
            for application in applications() where !terminated(application) && !hidden(application) {
                guard !owned.contains(where: { sameInstance($0.application, application) }) else { continue }
                try Task.checkCancellation()
                if hide(application) { owned.append(Entry(application: application)) } else { failures += 1 }
            }
            // AppKit caches running-application properties until the run loop turns. A successful
            // send is not proof of a hidden window. Keep unconfirmed ownership for an explicit Off.
            for attempt in 0..<5 {
                discardReleasedApplications()
                if !owned.contains(where: { !$0.confirmed }) { break }
                try Task.checkCancellation()
                if attempt < 4 { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            failures += owned.filter { !$0.confirmed }.count
        } else {
            let pending = owned
            owned = []
            var accepted: [Entry] = []
            for entry in pending {
                if unhide(entry.application) {
                    accepted.append(entry)
                } else {
                    owned.append(entry)
                    failures += 1
                }
            }
            // Cancellation must retain every still-owned instance for a later recovery attempt.
            owned.append(contentsOf: accepted)
            for attempt in 0..<5 {
                accepted.removeAll { terminated($0.application) || !hidden($0.application) }
                if accepted.isEmpty { break }
                try Task.checkCancellation()
                if attempt < 4 { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            failures += accepted.count
            owned.removeAll { terminated($0.application) || !hidden($0.application) }
        }
        if failures > 0 {
            throw ConfigurationError.invalid(
                enabled
                    ? L10n.text("有 %1$@ 個 App 未能隱藏；已保留成功項目，可按關閉還原。", String(describing: failures))
                    : L10n.text("有 %1$@ 個 App 未能還原；已保留記錄，可再次按關閉。", String(describing: failures)))
        }
    }

    private func discardReleasedApplications() {
        owned.removeAll { terminated($0.application) || ($0.confirmed && !hidden($0.application)) }
        for index in owned.indices where hidden(owned[index].application) { owned[index].confirmed = true }
    }
}
