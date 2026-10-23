import Foundation

/// Explicit resource profiling uses its own store and cannot activate system controls.
public struct GUIStartupOptions: Equatable, Sendable {
    public let dataDirectory: URL
    public let diagnosticMode: Bool
    public let showSettings: Bool
    public let importOriginalOnFirstLaunch: Bool

    public static func parse(arguments: [String], home: URL) throws -> Self {
        var directory: URL?
        var diagnostic = false
        var settings = false
        var seen: Set<String> = []
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard seen.insert(flag).inserted else {
                throw ConfigurationError.invalid("Duplicate argument: \(flag)")
            }
            switch flag {
            case "--data-directory":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/"),
                    !arguments[index].utf8.contains(0)
                else { throw ConfigurationError.invalid("--data-directory requires an absolute directory path") }
                directory = URL(fileURLWithPath: arguments[index], isDirectory: true).standardizedFileURL
            case "--diagnostic-mode": diagnostic = true
            case "--show-settings": settings = true
            default: throw ConfigurationError.invalid("Unknown GUI argument: \(flag)")
            }
            index += 1
        }
        guard !diagnostic || directory != nil else {
            throw ConfigurationError.invalid("--diagnostic-mode requires an explicit --data-directory")
        }
        let live = home.appendingPathComponent("Library/Application Support/QuickSwitch", isDirectory: true)
            .standardizedFileURL
        if diagnostic, let directory {
            let isolatedStore = directory.appendingPathComponent("settings.json").resolvingSymlinksInPath()
            let liveStore = live.appendingPathComponent("settings.json").resolvingSymlinksInPath()
            guard directory.resolvingSymlinksInPath() != live.resolvingSymlinksInPath(), isolatedStore != liveStore
            else {
                throw ConfigurationError.invalid("Diagnostic mode cannot use the live QuickSwitch store")
            }
        }
        return Self(
            dataDirectory: directory ?? live, diagnosticMode: diagnostic, showSettings: settings,
            importOriginalOnFirstLaunch: directory == nil && !diagnostic)
    }
}
