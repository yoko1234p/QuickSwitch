# Localization development

## Runtime and resources

The native apps share `Shared/AppLocalizationKit`, a Foundation-only resource resolver and safe numbered-placeholder renderer. Each project keeps its own small static `Resources/Localization/{en,zh-Hant,zh-Hans}.lproj/Localizable.strings` catalogs. DeskTools shares one catalog across its three apps. Language choice and resource bundles are cached; there is no localization timer, network translation call or translation model in the apps.

Follow macOS per-app language settings. `APP_UI_LANGUAGE=en`, `zh-Hant` or `zh-Hans` is an optional process-local QA override and does not change system preferences. Unsupported language preferences fall back to English.

```swift
L10n.text("取消")
L10n.text("搜尋結果：%1$@", String(count))
```

Historical Chinese text remains a stable translation key. Use a context-specific key such as `calendar.day` when one short source word has multiple meanings. Numbered placeholders may be reordered in translations. Substitution touches the template only, so percentages, Unicode and placeholder-like text inside user input stay literal. Do not pass a translated string to `String(format:)`; format numeric values separately.

## Preserve behavior and content

Do not translate persisted enum values, action/category IDs, URLs, filenames, unit aliases, regular expressions, native Accessibility matching alternatives or executable script text. Translate fixed display labels at their UI boundary. User notes, custom names, vocabulary and imported extension content are data. BarPilot retains unambiguous saved IDs for the suite's status items so a translated tooltip cannot reset a layout.

App Intents retain their native `LocalizedStringResource` declarations. The Xcode application packages their translations in the main bundle. SuperPilot's Finder extension resolves the host app's resource catalog. Permission descriptions use localized `InfoPlist.strings` files.

TG Local uses static `locales/*.json` dictionaries and generated `src/locales.js` for its page-context UI. Chrome manifest metadata lives under `_locales/`. No additional extension permissions are needed. Its controls use text substitution, not HTML evaluation.

## Update and validate

Edit all three language tables for a new key. English terminology overrides and context-specific entries are maintained under `scripts/localization/`. Optional migration/draft tools use Xcode's SwiftSyntax and already-installed Apple on-device translation models; these tools are not needed to build or run the apps. Simplified Chinese generation includes regional macOS terminology and still needs editorial review when adding new wording.

```sh
python3 scripts/localization/check-catalogs.py
APP_UI_LANGUAGE=zh-Hant swift test -j 4  # run inside the affected package
python3 scripts/localization/check-catalogs.py --packaged
APP_UI_LANGUAGE=en path/to/App.app/Contents/MacOS/App --localization-status
```

The diagnostic exits before starting GUI, profiles, hooks or system adapters. It checks real packaged catalog counts and reports whether resources came from the application rather than a developer build directory. Keep test languages explicit where older fixtures assert exact Chinese wording. Shared tests verify English/Chinese resources, fallback and literal placeholder handling; project tests protect stable IDs and existing behavior. Check visible layout in addition to catalog completeness.
