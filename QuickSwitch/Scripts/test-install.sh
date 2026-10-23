#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 - "$TASK_ROOT/Scripts/install.sh" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile

installer = Path(sys.argv[1])
source = installer.read_text()
source_digest = hashlib.sha256(source.encode()).hexdigest()
expected_id = "local.pakwingho.quickswitch"
assertions = 0
failures = []
results = []


def check(condition, label):
    global assertions
    assertions += 1
    if not condition:
        failures.append(label)


dispatcher = r'''
import json, os, pathlib, plistlib, shutil, subprocess, sys
tool, args = sys.argv[1], sys.argv[2:]
root = pathlib.Path(os.environ["QS_INSTALL_TEST_ROOT"])
scenario = os.environ["QS_INSTALL_TEST_SCENARIO"]

def bounded(value):
    path = pathlib.Path(value)
    if not path.is_absolute() or (path != root and root not in path.parents):
        raise SystemExit("Refusing an operation outside the test fixture: " + str(path))
    return path

with (root / "events.jsonl").open("a") as log:
    log.write(json.dumps({"tool": tool, "args": args}) + "\n")
if tool == "PlistBuddy":
    assert args[:2] == ["-c", "Print :CFBundleIdentifier"]
    with bounded(args[2]).open("rb") as handle:
        print(plistlib.load(handle)["CFBundleIdentifier"])
elif tool == "codesign":
    app = bounded(args[-1])
    if scenario == "starts-during-staging" and app.parent.name.startswith(".QuickSwitch-install."):
        (root / "running").write_text("started")
elif tool == "pgrep":
    raise SystemExit(0 if scenario == "running-app" or (root / "running").exists() else 1)
elif tool == "ditto":
    shutil.copytree(bounded(args[0]), bounded(args[1]), symlinks=True)
elif tool == "mktemp":
    assert args[0] == "-d"
    bounded(args[1])
    os.execv("/usr/bin/mktemp", ["/usr/bin/mktemp", *args])
elif tool == "mv":
    old, new = map(bounded, args)
    replacing = old.name == "QuickSwitch.app" and old.parent.name.startswith(".QuickSwitch-install.")
    restoring = old.name == "previous.app"
    if replacing and scenario in ("replacement-failure", "restoration-failure"):
        raise SystemExit(73)
    if restoring and scenario == "restoration-failure":
        raise SystemExit(74)
    os.execv("/bin/mv", ["/bin/mv", *args])
elif tool == "mkdir":
    assert args[0] == "-p"
    for name in args[1:]: bounded(name)
    os.execv("/bin/mkdir", ["/bin/mkdir", *args])
elif tool == "ln":
    assert args[0] == "-s"
    target, link = map(bounded, args[1:])
    os.symlink(target, link)
elif tool == "rm":
    for name in args:
        if not name.startswith("-"): bounded(name)
    os.execv("/bin/rm", ["/bin/rm", *args])
elif tool == "lsregister":
    bounded(args[-1])
    if args[0] == "-f" and scenario in ("registration-failure", "fresh-registration-failure"):
        raise SystemExit(75)
else:
    raise SystemExit("Unexpected test tool: " + tool)
'''


def bundle(path, marker, bundle_id=expected_id):
    (path / "Contents").mkdir(parents=True)
    (path / "marker").write_text(marker)
    with (path / "Contents/Info.plist").open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle_id}, handle)


def marker(path):
    try:
        return (path / "marker").read_text()
    except FileNotFoundError:
        return None


with tempfile.TemporaryDirectory(prefix="quickswitch-install-tests-") as scratch:
    for scenario in (
        "success-existing", "success-new", "replacement-failure", "restoration-failure",
        "registration-failure", "fresh-registration-failure", "formal-directory-conflict", "formal-symlink-conflict",
        "physical-identity-conflict", "source-identity-conflict", "running-app", "starts-during-staging",
    ):
        root = Path(scratch) / scenario
        repo = root / "repository"
        scripts = repo / "Scripts"
        scripts.mkdir(parents=True)
        physical = root / "Applications/QuickSwitch.app"
        formal = root / "Work/Applications/QuickSwitch.app"
        physical.parent.mkdir(parents=True)
        formal.parent.mkdir(parents=True)
        source_app = repo / "dist/QuickSwitch.app"
        bundle(source_app, "new", "other.source" if scenario == "source-identity-conflict" else expected_id)
        if scenario not in ("success-new", "fresh-registration-failure"):
            bundle(physical, "old", "other.physical" if scenario == "physical-identity-conflict" else expected_id)
        if scenario == "formal-directory-conflict":
            bundle(formal, "unrelated", "other.formal")
        elif scenario == "formal-symlink-conflict":
            os.symlink(root / "unrelated.app", formal)
        elif scenario not in ("success-new", "fresh-registration-failure"):
            os.symlink(physical, formal)
        tools = root / "tools"
        tools.mkdir()
        dispatch_file = tools / "dispatch.py"
        dispatch_file.write_text(dispatcher)
        for name in ("PlistBuddy", "codesign", "pgrep", "ditto", "mktemp", "mv", "mkdir", "ln", "rm", "lsregister"):
            tool = tools / name
            tool.write_text("#!/bin/bash\nexec " + shlex.quote(sys.executable) + " "
                            + shlex.quote(str(dispatch_file)) + " " + shlex.quote(name) + ' "$@"\n')
            tool.chmod(0o700)
        replacements = (
            ('PHYSICAL_APP="/Applications/QuickSwitch.app"', "PHYSICAL_APP=" + shlex.quote(str(physical)), 1),
            ('WORK_APP="/Applications/QuickSwitch.app"', "WORK_APP=" + shlex.quote(str(formal)), 1),
            ('mktemp -d /Applications/.QuickSwitch-install.XXXXXX',
             "mktemp -d " + shlex.quote(str(physical.parent / ".QuickSwitch-install.XXXXXX")), 1),
            ('mkdir -p /Applications', "mkdir -p " + shlex.quote(str(formal.parent)), 1),
            ("REGISTER_TOOL='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'",
             "REGISTER_TOOL=" + shlex.quote(str(tools / "lsregister")), 1),
            ('/usr/libexec/PlistBuddy', shlex.quote(str(tools / "PlistBuddy")), 2),
        )
        rewritten = source
        for old, new, count in replacements:
            if rewritten.count(old) != count:
                raise SystemExit("Installer fixture rewrite no longer matches source: " + old)
            rewritten = rewritten.replace(old, new)
        fixture = scripts / "install.sh"
        fixture.write_text(rewritten)
        fixture.chmod(0o700)
        # Every mutation tool validates its arguments against this private root.
        # Neither a production destination nor LaunchServices can be reached.
        env = {"PATH": str(tools) + ":/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C",
               "QS_INSTALL_TEST_ROOT": str(root), "QS_INSTALL_TEST_SCENARIO": scenario}
        run = subprocess.run(["/bin/bash", str(fixture)], env=env, capture_output=True, text=True, timeout=15)
        stages = list(physical.parent.glob(".QuickSwitch-install.*"))
        backups = [stage / "previous.app" for stage in stages if (stage / "previous.app").exists()]
        events = [json.loads(line) for line in (root / "events.jsonl").read_text().splitlines()]
        before = len(failures)
        check(marker(source_app) == "new", scenario + ": build artifact preserved")
        if scenario.startswith("success-"):
            check(run.returncode == 0, scenario + ": successful exit")
            check(marker(physical) == "new", scenario + ": new physical bundle")
            check(formal.is_symlink() and os.readlink(formal) == str(physical), scenario + ": exact formal symlink")
            check(not stages, scenario + ": committed backup and staging removed")
        elif scenario == "replacement-failure":
            check(run.returncode == 73, scenario + ": original failure status retained")
            check(marker(physical) == "old", scenario + ": previous bundle restored")
            check(not stages, scenario + ": restored staging cleaned")
            check("previous version restored" in run.stderr, scenario + ": restoration reported")
        elif scenario == "restoration-failure":
            check(run.returncode == 73, scenario + ": original failure status retained")
            check(not physical.exists(), scenario + ": no false installed bundle")
            check(len(backups) == 1 and marker(backups[0]) == "old", scenario + ": recovery bundle retained")
            check("Recovery copy kept at " + str(backups[0]) in run.stderr, scenario + ": recovery location reported")
        elif scenario in ("registration-failure", "fresh-registration-failure"):
            check(run.returncode == 75, scenario + ": registration error retained")
            check(marker(physical) == "new", scenario + ": new bundle remains available")
            if scenario == "registration-failure":
                check(len(backups) == 1 and marker(backups[0]) == "old", scenario + ": previous bundle retained")
            else:
                check(not stages, scenario + ": empty staging removed without a previous bundle")
            check("application entry kept at " + str(physical) in run.stderr, scenario + ": incomplete install reported")
        elif scenario == "starts-during-staging":
            check(run.returncode != 0, scenario + ": recheck rejected running application")
            check(marker(physical) == "old", scenario + ": previous bundle never moved")
            check(not stages, scenario + ": uncommitted staging removed")
            check(any(event["tool"] == "ditto" for event in events), scenario + ": launch simulated after staging")
            check(not any(event["tool"] in ("mv", "ln", "lsregister") for event in events),
                  scenario + ": aborted before replacement or registration")
        else:
            check(run.returncode != 0, scenario + ": conflict rejected")
            check(marker(physical) == "old", scenario + ": existing physical bundle preserved")
            check(not stages, scenario + ": rejected before staging")
            check(not any(event["tool"] in ("ditto", "mv", "ln", "lsregister") for event in events),
                  scenario + ": no install mutation after rejection")
            if scenario == "formal-directory-conflict":
                check(marker(formal) == "unrelated", scenario + ": conflicting directory preserved")
            if scenario == "formal-symlink-conflict":
                check(formal.is_symlink() and os.readlink(formal) == str(root / "unrelated.app"),
                      scenario + ": conflicting dangling link preserved")
        if not scenario.startswith("success-"):
            check("Installed:" not in run.stdout, scenario + ": no false success message")
        results.append({"scenario": scenario, "exit_status": run.returncode,
                        "passed": len(failures) == before, "recovery_bundles": len(backups),
                        "stderr": run.stderr.strip()})

check(hashlib.sha256(installer.read_bytes()).hexdigest() == source_digest, "production source unchanged during fixture execution")
report = {"installer": str(installer), "source_sha256": source_digest,
          "scenarios": results, "assertions": assertions, "failures": failures,
          "production_paths_mutated": False, "app_launched": False}
print(json.dumps(report, indent=2))
raise SystemExit(1 if failures else 0)
PY
