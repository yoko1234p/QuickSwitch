import Foundation

public enum AutomationPolicy {
    public static func registerHotkeys(configuration: AppConfiguration, originalRunning: Bool) -> [String:
        KeyboardShortcut]
    {
        guard configuration.hotkeysEnabled, !originalRunning else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: configuration.switches.compactMap { item in
                guard item.enabled, item.knownID != nil, let shortcut = item.shortcut, shortcut.valid else {
                    return nil
                }
                return (item.id, shortcut)
            })
    }
    public static func desiredDarkMode(
        configuration: AppConfiguration, originalRunning: Bool, now: Date, current: SwitchState?,
        calendar: Calendar = .current
    ) -> Bool? {
        guard configuration.restoreAutomations, !originalRunning, configuration.darkSchedule.enabled,
            let currentValue = current?.isOn
        else { return nil }
        let desired: Bool?
        switch configuration.effectiveDarkScheduleMode {
        case .sunsetToSunrise:
            desired = configuration.solarLocation.flatMap {
                SolarSchedule.day(at: now, location: $0, calendar: calendar)?.dark(at: now)
            }
        case .fixedTimes:
            desired = configuration.darkSchedule.desiredState(at: now, calendar: calendar)
        case .manual:
            desired = nil
        }
        guard let desired, desired != currentValue else { return nil }
        return desired
    }
}

public enum SwitchOrder {
    public static func moving(_ items: [SwitchConfiguration], id: String, relativeTo target: String, after: Bool)
        -> [SwitchConfiguration]
    {
        var ordered = items.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        guard id != target, let source = ordered.firstIndex(where: { $0.id == id }),
            ordered.contains(where: { $0.id == target })
        else { return ordered }
        let value = ordered.remove(at: source)
        guard let destination = ordered.firstIndex(where: { $0.id == target }) else { return items }
        ordered.insert(value, at: destination + (after ? 1 : 0))
        for index in ordered.indices { ordered[index].order = index }
        return ordered
    }
}
