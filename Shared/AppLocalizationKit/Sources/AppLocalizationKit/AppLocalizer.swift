import Foundation

/// Resolves an app's small static catalog; translation models are never a runtime dependency.
public struct AppLocalizer: @unchecked Sendable {
  public static let supportedLanguages = ["en", "zh-Hant", "zh-Hans"]
  private static let placeholders = try! NSRegularExpression(pattern: "%([1-9][0-9]*)\\$@")
  private let catalogs: [String: Bundle]
  public let language: String
  public let resourceLocation: String

  public init(bundle: Bundle) {
    resourceLocation =
      bundle.bundleURL.pathComponents.contains(where: { $0.hasSuffix(".app") })
      ? "application" : "development"
    catalogs = Dictionary(
      uniqueKeysWithValues: Self.supportedLanguages.compactMap { language in
        bundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)).map {
          (language, $0)
        }
      })
    if let override = ProcessInfo.processInfo.environment["APP_UI_LANGUAGE"], !override.isEmpty {
      language = Self.language(for: [override])
    } else {
      language = Self.language(for: Locale.preferredLanguages)
    }
  }

  public init(resourceBundleName: String, fallback: () -> Bundle) {
    // Finder extensions use the host application's resource bundle, too.
    var candidates = [
      Bundle.main.resourceURL, Bundle.main.bundleURL,
      URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
    ].compactMap { $0 }
    var ancestor = Bundle.main.bundleURL
    for _ in 0..<5 {
      candidates.append(ancestor.appendingPathComponent("Contents/Resources", isDirectory: true))
      ancestor.deleteLastPathComponent()
    }
    let bundle =
      candidates.lazy.compactMap {
        Bundle(url: $0.appendingPathComponent(resourceBundleName + ".bundle", isDirectory: true))
      }.first ?? fallback()
    self.init(bundle: bundle)
  }

  public static func language(for preferences: [String]) -> String {
    for preference in preferences {
      let identifier = preference.replacingOccurrences(of: "_", with: "-").lowercased()
      if identifier == "en" || identifier.hasPrefix("en-") { return "en" }
      if identifier == "zh" || identifier.hasPrefix("zh-") {
        if identifier.contains("hans") { return "zh-Hans" }
        if identifier.contains("hant") { return "zh-Hant" }
        let region = identifier.split(separator: "-").last.map(String.init) ?? ""
        return ["tw", "hk", "mo"].contains(region) ? "zh-Hant" : "zh-Hans"
      }
    }
    return "en"
  }

  public func text(_ key: String, arguments: [String] = [], language: String? = nil) -> String {
    let requested = language.map { Self.language(for: [$0]) } ?? self.language
    let localizedBundle = catalogs[requested]
    let english = catalogs["en"]
    let fallback = english?.localizedString(forKey: key, value: key, table: nil) ?? key
    let template =
      localizedBundle?.localizedString(forKey: key, value: fallback, table: nil) ?? fallback
    return Self.interpolate(template, arguments: arguments)
  }

  /// A read-only packaging check that exits before any GUI, profile, hook or system adapter starts.
  public func printDiagnosticsIfRequested(_ arguments: [String] = CommandLine.arguments) -> Bool {
    guard arguments.contains("--localization-status") else { return false }
    var counts: [String: Int] = [:]
    var keys: Set<String> = []
    for (language, catalog) in catalogs {
      if let file = catalog.url(forResource: "Localizable", withExtension: "strings"),
        let data = try? Data(contentsOf: file),
        let table = try? PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: String]
      {
        counts[language] = table.count
        keys.formUnion(table.keys)
      } else {
        counts[language] = 0
      }
    }
    let common = ["取消", "設定", "關閉", "重新整理", "開啟"].filter { keys.contains($0) }
    let probes = common.isEmpty ? Array(keys.sorted().prefix(3)) : common
    let output: [String: Any] = [
      "language": language, "supportedLanguages": Self.supportedLanguages,
      "resourceLocation": resourceLocation, "catalogCounts": counts,
      "samples": Dictionary(uniqueKeysWithValues: probes.map { ($0, text($0)) }),
    ]
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
    }
    return true
  }

  /// Replace only numbered placeholders in the template, never placeholders inside user input.
  /// Literal percentages and arbitrary user text cannot become printf format instructions.
  public static func interpolate(_ template: String, arguments: [String]) -> String {
    guard !arguments.isEmpty else { return template }
    let source = template as NSString
    var result = template
    let matches = placeholders.matches(
      in: template, range: NSRange(location: 0, length: source.length))
    for match in matches.reversed() {
      guard let number = Int(source.substring(with: match.range(at: 1))), number <= arguments.count,
        let range = Range(match.range, in: result)
      else { continue }
      result.replaceSubrange(range, with: arguments[number - 1])
    }
    return result
  }
}
