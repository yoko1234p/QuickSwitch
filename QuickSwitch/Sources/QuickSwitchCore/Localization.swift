import Foundation

#if canImport(AppLocalizationKit)
    import AppLocalizationKit
#endif

/// Fixed UI text only. User names, note contents and persisted identifiers stay unchanged.
public enum L10n {
    public static let catalog = AppLocalizer(
        resourceBundleName: "QuickSwitch_QuickSwitchCore",
        fallback: {
            #if SWIFT_PACKAGE
                return .module
            #else
                return .main
            #endif
        })

    public static func text(_ key: String, _ arguments: String...) -> String {
        catalog.text(key, arguments: arguments)
    }
}
