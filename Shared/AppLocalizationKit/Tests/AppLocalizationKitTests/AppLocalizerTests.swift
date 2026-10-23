import AppLocalizationKit
import XCTest

final class AppLocalizerTests: XCTestCase {
  func testLanguageRegionsScriptsAndUnsupportedLanguageFallback() {
    for preference in ["zh-HK", "zh-TW", "zh_MO", "zh-Hant-CN"] {
      XCTAssertEqual(AppLocalizer.language(for: [preference]), "zh-Hant")
    }
    for preference in ["zh-CN", "zh-SG", "zh_Hans_HK"] {
      XCTAssertEqual(AppLocalizer.language(for: [preference]), "zh-Hans")
    }
    XCTAssertEqual(AppLocalizer.language(for: ["ja-JP", "en-GB"]), "en")
    XCTAssertEqual(AppLocalizer.language(for: ["fr", "zh-HK"]), "zh-Hant")
    XCTAssertEqual(AppLocalizer.language(for: []), "en")
  }

  func testReorderedRepeatedAndNonASCIIArgumentsPreserveUserText() {
    XCTAssertEqual(
      AppLocalizer.interpolate("%2$@ / %1$@ / %2$@", arguments: ["東京", "😀"]), "😀 / 東京 / 😀")
    XCTAssertEqual(
      AppLocalizer.interpolate("%1$@ — %2$@", arguments: ["%2$@", "100%"]), "%2$@ — 100%")
    XCTAssertEqual(AppLocalizer.interpolate("%1$@%", arguments: ["80"]), "80%")
    XCTAssertEqual(AppLocalizer.interpolate("%n %s %2$@", arguments: ["one"]), "%n %s %2$@")
  }

  func testUnknownUserContentIsNotTranslatedOrModified() {
    let localizer = AppLocalizer(bundle: .main)
    XCTAssertEqual(localizer.text("My note: 日本語 한국어 %n", language: "en"), "My note: 日本語 한국어 %n")
  }

  func testRealLocalizedResourcesAndMissingKeyFallback() throws {
    let url = try XCTUnwrap(
      Bundle.module.resourceURL?.appendingPathComponent("Fixtures/LocalizationFixture.bundle"))
    let bundle = try XCTUnwrap(Bundle(url: url))
    let localizer = AppLocalizer(bundle: bundle)
    XCTAssertEqual(localizer.text("選單列", language: "en"), "Menu bar")
    XCTAssertEqual(localizer.text("選單列", language: "zh-HK"), "選單列")
    XCTAssertEqual(localizer.text("選單列", language: "zh-CN"), "菜单栏")
    XCTAssertEqual(localizer.text("選單列", language: "fr"), "Menu bar")
    XCTAssertEqual(localizer.text("English-only key", language: "zh-Hant"), "English fallback")
    XCTAssertEqual(localizer.text("Missing everywhere", language: "zh-Hans"), "Missing everywhere")
    let resolved = AppLocalizer(resourceBundleName: "MissingResourceBundle", fallback: { bundle })
    XCTAssertEqual(resolved.text("選單列", language: "en"), "Menu bar")
  }
}
