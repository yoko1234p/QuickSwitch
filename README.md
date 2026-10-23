# QuickSwitch

Control common macOS settings from one compact menu-bar panel.

**系統效率系列：系統快捷開關、保持喚醒時間及工作配方。** Interfaces support English, Traditional Chinese and Simplified Chinese.

## Features

- Use common system switches from the menu bar.
- Keep the Mac awake for a duration or until a chosen time.
- Save reusable profiles for recurring work and meeting setups.

## Build and test

Requires macOS 14+, Xcode 27/Swift 6 and Python 3. This repository includes its required shared packages; keep `Shared/` and `scripts/` beside `QuickSwitch/`.

```sh
cd QuickSwitch
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh release
```

The app bundle is written to `QuickSwitch/dist/QuickSwitch.app`. Building does not install or launch it. See [SIGNING.md](SIGNING.md) for ad-hoc development and your own signing identity.

## Use and limitations

Some switches need native macOS permissions or depend on OS-specific APIs and connected hardware. The app reports unavailable controls; supported behavior varies by macOS release. Profiles and settings remain local.

## Development and license

This app is under active development. Report the macOS version, reproduction steps and actual validation results with changes. Use synthetic data for file, clipboard and permission tests. Validate interface catalogs from the repository root with `python3 scripts/localization/check-catalogs.py`.

Original maintained code is **GPL-3.0-only**. Keep the separate dependency/data notices listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). See [LICENSE](LICENSE) and [CONTRIBUTING.md](CONTRIBUTING.md).
