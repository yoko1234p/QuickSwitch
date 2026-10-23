#!/usr/bin/env python3
"""Collect fixed UI keys while excluding canonical grammar, matching rules and user data."""
import argparse
import json
import re
import subprocess
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROJECTS = ["BarPilot", "DeskTools", "NotchHub", "QuickSwitch", "SelectionBar", "SuperPilot"]
CATALOG_DATA = {"enum raw value", "action category ID", "canonical binding: categories"}


class PopupKeys(HTMLParser):
    def __init__(self):
        super().__init__()
        self.keys = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if "data-i18n" in values:
            self.keys.append(values["data-i18n"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scanner", default=str(ROOT / ".build/localization/localize-swift"))
    parser.add_argument("--output", default=str(ROOT / ".build/localization/source-index.json"))
    args = parser.parse_args()
    files = []
    for project in PROJECTS:
        for path in (ROOT / project / "Sources").rglob("*.swift"):
            relative = path.relative_to(ROOT)
            if project == "BarPilot" and ("Pro" in relative.parts or "Automation" in relative.parts):
                continue
            if path.name in ("VocabularyAtlasRenderer.swift", "VocabularyIllustration.swift", "JapaneseRuby.swift"):
                continue
            files.append(str(relative))
    result = subprocess.run([args.scanner, *files], cwd=ROOT, check=True, capture_output=True, text=True)
    scanned = json.loads(result.stdout)
    records = []
    for record in scanned:
        reason = record["skip"]
        if reason == "localized key" or reason in CATALOG_DATA or record["file"].endswith("/AppIntents.swift"):
            records.append({"file": record["file"], "key": record["key"], "skip": ""})
    native = ROOT / "BarPilot/Sources/BarPilotNative/AssessmentAssertion.m"
    for key in re.findall(r'BPLocalized\(@"([^"\n]+)"', native.read_text()):
        records.append({"file": str(native.relative_to(ROOT)), "key": key, "skip": ""})
    result = subprocess.run(["node", "scripts/localize-source.mjs"], cwd=ROOT / "TGLocal", check=True, capture_output=True, text=True)
    for record in json.loads(result.stdout):
        record["file"] = "TGLocal/" + record["file"]
        records.append(record)
    popup = PopupKeys()
    popup.feed((ROOT / "TGLocal/src/popup.html").read_text())
    records.extend({"file": "TGLocal/src/popup.html", "key": key, "skip": ""} for key in popup.keys)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(records, ensure_ascii=False, indent=2))
    print(f"Collected {len(set(record['key'] for record in records))} distinct keys")


if __name__ == "__main__":
    main()
