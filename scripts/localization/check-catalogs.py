#!/usr/bin/env python3
"""Validate source catalogs and optionally the actual packaged applications."""
import argparse
import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROJECTS = {
    "BarPilot": "BarPilotCore", "DeskTools": "DeskCore", "NotchHub": "NotchHub",
    "QuickSwitch": "QuickSwitchCore", "SelectionBar": "SelectionBarCore", "SuperPilot": "SuperPilotCore",
}
LANGUAGES = ("en", "zh-Hant", "zh-Hans")
PLACEHOLDERS = re.compile(r"%[1-9][0-9]*\$@")
ENTRY = re.compile(r'("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");')


def table(path):
    content = path.read_text()
    pairs = [(json.loads(key), json.loads(value)) for key, value in ENTRY.findall(content)]
    if len(pairs) != len(dict(pairs)):
        raise ValueError(f"Duplicate localization key: {path}")
    return dict(pairs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--packaged", action="store_true")
    parser.add_argument("--project", action="append", choices=[*PROJECTS, "TGLocal"],
                        help="Validate only this project; may be repeated. Defaults to projects present in this checkout.")
    args = parser.parse_args()
    available = [name for name in [*PROJECTS, "TGLocal"] if (ROOT / name).is_dir()]
    requested = list(dict.fromkeys(args.project or available))
    if not requested:
        parser.error("No supported projects are present in this checkout")
    missing = set(requested) - set(available)
    if missing:
        parser.error("Requested projects are absent: " + ", ".join(sorted(missing)))
    selected = {name: module for name, module in PROJECTS.items() if name in requested}
    counts = {}
    for project, module in selected.items():
        directory = ROOT / project / "Sources" / module / "Resources/Localization"
        catalogs = {language: table(directory / (language + ".lproj") / "Localizable.strings") for language in LANGUAGES}
        keys = set(catalogs["en"])
        assert keys, project
        for language, values in catalogs.items():
            assert set(values) == keys, (project, language, "key coverage")
            for key, value in values.items():
                assert sorted(PLACEHOLDERS.findall(value)) == sorted(PLACEHOLDERS.findall(key)), (project, language, key)
                assert value.strip(), (project, language, key, "empty translation")
        counts[project] = len(keys)
    if "TGLocal" in requested:
        extension = ROOT / "TGLocal"
        chrome = {language: json.loads((extension / "locales" / (language + ".json")).read_text()) for language in LANGUAGES}
        for language, values in chrome.items():
            assert set(values) == set(chrome["en"]), language
            for key, value in values.items():
                assert sorted(PLACEHOLDERS.findall(key)) == sorted(PLACEHOLDERS.findall(value)), (language, key)
        counts["TGLocal"] = len(chrome["en"])
        for language in ("en", "zh_TW", "zh_CN"):
            messages = json.loads((extension / "_locales" / language / "messages.json").read_text())
            assert len(messages["extensionDescription"]["message"]) <= 132
    packaged = {}
    if args.packaged:
        apps = []
        if "DeskTools" in selected:
            apps += [(name, ROOT / "DeskTools/dist" / (name + ".app")) for name in ("CaptureText", "DevWorkbench", "EdgeNotes")
                     if (ROOT / "DeskTools/Sources" / name).is_dir()]
        apps += [(name, ROOT / name / "dist" / (name + ".app")) for name in selected if name != "DeskTools"]
        for name, application in apps:
            reports = {}
            for language in LANGUAGES:
                environment = os.environ.copy()
                environment["APP_UI_LANGUAGE"] = language
                process = subprocess.run([str(application / "Contents/MacOS" / name), "--localization-status"],
                                         env=environment, capture_output=True, text=True, check=True, timeout=20)
                report = json.loads(process.stdout)
                assert report["language"] == language, (name, language, report)
                assert report["resourceLocation"] == "application", (name, "used development fallback")
                assert set(report["catalogCounts"]) == set(LANGUAGES), (name, report)
                expected = counts["DeskTools" if name in ("CaptureText", "DevWorkbench", "EdgeNotes") else name]
                assert all(value == expected for value in report["catalogCounts"].values()), (name, report)
                reports[language] = report
            packaged[name] = reports
    output = {"catalogCounts": counts, "packaged": packaged}
    artifact = ROOT / ".build/localization/validation.json"
    artifact.parent.mkdir(parents=True, exist_ok=True)
    artifact.write_text(json.dumps(output, ensure_ascii=False, indent=2))
    print(json.dumps({"catalogCounts": counts, "packagedApplications": len(packaged)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
