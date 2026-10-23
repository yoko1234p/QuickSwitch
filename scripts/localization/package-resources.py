#!/usr/bin/env python3
"""Package only static localization resources before signing an application."""
import json
import plistlib
import shutil
import sys
from pathlib import Path

source = Path(sys.argv[1])
application = Path(sys.argv[2])
bundle_name = sys.argv[3]
resources = application / "Contents/Resources"
resources.mkdir(parents=True, exist_ok=True)
license_file = Path(__file__).resolve().parents[2] / "LICENSE"
if license_file.is_file():
    licenses = resources / "Licenses"
    licenses.mkdir(exist_ok=True)
    shutil.copy2(license_file, licenses / "GPL-3.0-only.txt")
if bundle_name != "main":
    bundle = source / (bundle_name + ".bundle")
    if not bundle.is_dir():
        raise SystemExit(f"Missing localization bundle: {bundle}")
    shutil.copytree(bundle, resources / bundle.name, dirs_exist_ok=True)

# Copy maintained catalogs last, so incremental builds cannot retain stale cached tables.
projects = {
    "BarPilot_BarPilotCore": ("BarPilot", "BarPilotCore"),
    "DeskTools_DeskCore": ("DeskTools", "DeskCore"),
    "QuickSwitch_QuickSwitchCore": ("QuickSwitch", "QuickSwitchCore"),
    "SelectionBar_SelectionBarCore": ("SelectionBar", "SelectionBarCore"),
    "SuperPilot_SuperPilotCore": ("SuperPilot", "SuperPilotCore"),
    "main": ("NotchHub", "NotchHub"),
}
project, module = projects[bundle_name]
maintained = Path(__file__).resolve().parents[2] / project / "Sources" / module / "Resources/Localization"
destination = resources if bundle_name == "main" else resources / (bundle_name + ".bundle")
for language in ("en", "zh-Hant", "zh-Hans"):
    locale = destination / (language + ".lproj")
    locale.mkdir(parents=True, exist_ok=True)
    shutil.copy2(maintained / (language + ".lproj") / "Localizable.strings", locale / "Localizable.strings")

info_file = application / "Contents/Info.plist"
info = plistlib.loads(info_file.read_bytes())
info["CFBundleDevelopmentRegion"] = "en"
info["CFBundleLocalizations"] = ["en", "zh-Hant", "zh-Hans"]
metadata_file = Path(__file__).with_name("app-info.json")
metadata = json.loads(metadata_file.read_text()).get(info["CFBundleName"], {})
for key, values in metadata.items():
    if key in info:
        info[key] = values["en"]
info_file.write_bytes(plistlib.dumps(info))
for language in info["CFBundleLocalizations"]:
    table = {key: values[language] for key, values in metadata.items() if key in info}
    locale = resources / (language + ".lproj")
    locale.mkdir(exist_ok=True)
    content = "/* Localized permission and application metadata. */\n"
    for key, value in sorted(table.items()):
        content += json.dumps(key, ensure_ascii=False) + " = " + json.dumps(value, ensure_ascii=False) + ";\n"
    (locale / "InfoPlist.strings").write_text(content)
print(f"Localized resources: {application.name}")
