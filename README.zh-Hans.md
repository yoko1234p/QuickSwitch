# QuickSwitch

[English](README.md) · [繁體中文](README.zh-Hant.md) · [**简体中文**](README.zh-Hans.md)

![QuickSwitch banner](assets/hero.svg)

![preview](https://img.shields.io/badge/release-0.4.0--preview.1-56d2b1?style=flat-square) ![GPLv3](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)

**常用 Mac 开关，一处处理。** 个人 macOS 工具系列的独立 App。

## 主要功能

- 从精简的菜单栏面板控制支持的 macOS 开关。
- 可设置保持唤醒的时长或指定结束时间。
- 保存会议和日常工作常用的设置组合。

## 安装预览版

从 [Releases](https://github.com/yoko1234p/QuickSwitch/releases/tag/v0.4.0-preview.1) 下载 macOS ZIP，解压后将 `QuickSwitch.app` 移至“应用程序”。预览版使用临时签名，**未经 Apple 公证**。首次打开时在 Finder 右键选择“打开”；若系统阻止，请到“系统设置 → 隐私与安全性 → 仍要打开”核对。只授予所需权限，覆盖现用版本前先备份本地数据。

## 从源代码构建

```sh
cd QuickSwitch
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh release
```

所需的本地 `Shared/` 包和构建工具已包含在仓库；构建不会自动安装或启动应用。

## 系统要求与限制

macOS 14 或更高版本；源代码构建需 Xcode 27／Swift 6 和 Python 3。 可用开关取决于 macOS 版本、硬件及系统权限；配置和设置保存在本机。

## 参与及授权

原创应用代码按 GPL-3.0-only 发布；附带的第三方及数据许可须分别保留。详见 [LICENSE](LICENSE)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、[CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。
