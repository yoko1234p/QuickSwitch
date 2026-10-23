#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$TASK_ROOT/dist/QuickSwitch.app"
PHYSICAL_APP="/Applications/QuickSwitch.app"
WORK_APP="/Applications/QuickSwitch.app"
EXPECTED_ID='local.pakwingho.quickswitch'
[ -d "$SOURCE_APP" ] || { echo 'Build QuickSwitch first.' >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")" = "$EXPECTED_ID" ] || exit 1
codesign --verify --deep --strict "$SOURCE_APP"
validate_destinations() {
    if [ -e "$PHYSICAL_APP" ]; then
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PHYSICAL_APP/Contents/Info.plist")" = "$EXPECTED_ID" ] || { echo 'Existing application has another identity.' >&2; exit 1; }
        if pgrep -x QuickSwitch >/dev/null; then echo 'Quit QuickSwitch before updating.' >&2; exit 1; fi
    fi
    if [ -e "$WORK_APP" ] || [ -L "$WORK_APP" ]; then
        [ -L "$WORK_APP" ] && [ "$(readlink "$WORK_APP")" = "$PHYSICAL_APP" ] || { echo 'Work application destination is occupied; left unchanged.' >&2; exit 1; }
    fi
}
validate_destinations
STAGING="$(mktemp -d /Applications/.QuickSwitch-install.XXXXXX)"
INSTALL_COMMITTED=0
cleanup() {
    local outcome=$?
    trap - EXIT
    if [ "$INSTALL_COMMITTED" -eq 0 ] && { [ -e "$STAGING/previous.app" ] || [ -L "$STAGING/previous.app" ]; }; then
        if [ ! -e "$PHYSICAL_APP" ] && [ ! -L "$PHYSICAL_APP" ]; then
            if mv "$STAGING/previous.app" "$PHYSICAL_APP"; then
                printf 'Installation failed; previous version restored at %s.\n' "$PHYSICAL_APP" >&2
            else
                printf 'Installation failed; automatic restoration failed.\n' >&2
            fi
        else
            printf 'Installation did not finish; application entry kept at %s.\n' "$PHYSICAL_APP" >&2
        fi
        if [ -e "$STAGING/previous.app" ] || [ -L "$STAGING/previous.app" ]; then
            printf 'Recovery copy kept at %s.\n' "$STAGING/previous.app" >&2
            exit "$outcome"
        fi
    elif [ "$INSTALL_COMMITTED" -eq 0 ] && { [ -e "$PHYSICAL_APP" ] || [ -L "$PHYSICAL_APP" ]; }; then
        printf 'Installation did not finish; application entry kept at %s.\n' "$PHYSICAL_APP" >&2
    fi
    if ! rm -rf "$STAGING"; then
        printf 'Could not remove installation staging directory: %s.\n' "$STAGING" >&2
        if [ "$outcome" -eq 0 ]; then outcome=1; fi
    fi
    exit "$outcome"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
ditto "$SOURCE_APP" "$STAGING/QuickSwitch.app"
codesign --verify --deep --strict "$STAGING/QuickSwitch.app"
validate_destinations
if [ -e "$PHYSICAL_APP" ]; then mv "$PHYSICAL_APP" "$STAGING/previous.app"; fi
mv "$STAGING/QuickSwitch.app" "$PHYSICAL_APP"
mkdir -p /Applications
if [ ! -L "$WORK_APP" ]; then ln -s "$PHYSICAL_APP" "$WORK_APP"; fi
REGISTER_TOOL='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
"$REGISTER_TOOL" -u "$SOURCE_APP" >/dev/null 2>&1 || true
"$REGISTER_TOOL" -f "$PHYSICAL_APP"
INSTALL_COMMITTED=1
echo "Installed: $WORK_APP"
# Deliberately do not launch or enable login: the originals remain running until the user switches.
