# QuickSwitch

[**English**](README.md) · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)

![QuickSwitch banner](assets/hero.svg)

![preview](https://img.shields.io/badge/release-0.4.0--preview.1-56d2b1?style=flat-square) ![GPLv3](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)

**Your frequent Mac switches in one place.** A standalone project in the personal macOS tools collection.

## What it does

- Control supported macOS switches from a compact menu-bar panel.
- Keep the Mac awake for a duration or until a selected clock time.
- Save reusable profiles for meetings and recurring work.

## Install a preview

Download the macOS ZIP from [Releases](https://github.com/yoko1234p/QuickSwitch/releases/tag/v0.4.0-preview.1), unzip, and move `QuickSwitch.app` to Applications. This preview uses ad-hoc signing and is **not notarized**. On first launch, use Finder’s **Open** context menu; if macOS blocks it, review **System Settings → Privacy & Security → Open Anyway**. Grant only the permissions you need. Do not install over a working copy without backing up local data.

## Build from source

```sh
cd QuickSwitch
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh release
```

The required local `Shared/` packages and build helpers are included. Building does not install or launch the app.

## Requirements and limits

macOS 14+; Xcode 27/Swift 6 and Python 3 for source builds. Available switches depend on macOS, connected hardware and native permissions. Profiles and settings are stored locally.

## Contribute and license

Original application code is GPL-3.0-only. Keep bundled third-party and data notices; see [LICENSE](LICENSE), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [CONTRIBUTING.md](CONTRIBUTING.md), and [SECURITY.md](SECURITY.md).
