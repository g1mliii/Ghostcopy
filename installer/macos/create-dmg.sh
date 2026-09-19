#!/bin/bash
# Package an already exported/signed app. Never modify or re-sign its bundle.
set -euo pipefail
if [[ $# -ne 2 || ! -d "$1/Contents" ]]; then
    echo "Usage: $0 /path/to/exported.app /path/to/GhostCopy.dmg" >&2
    exit 1
fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir -p "$(dirname "$2")"
output="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
[[ ! -e "$output" ]] || { echo "Output already exists: $output" >&2; exit 1; }
# Finder addresses the mounted disk by name. Avoid editing another mounted
# candidate's window (or a read-only previous DMG) when packaging repeatedly.
if [[ -e /Volumes/GhostCopy ]]; then
    echo 'Eject the mounted GhostCopy disk image before packaging another.' >&2
    exit 1
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/ghostcopy-dmg.XXXXXX")"
mounted=false
mountpoint=""
cleanup() {
    if $mounted; then hdiutil detach "$mountpoint" -quiet || true; fi
    rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/stage/.background"
ditto "$app" "$work/stage/GhostCopy.app"
ln -s /Applications "$work/stage/Applications"
xcrun swift "$script_dir/background.swift" "$work/stage/.background/background.png"
hdiutil create -quiet -volname GhostCopy -srcfolder "$work/stage" -format UDRW -fs HFS+ "$work/writable.dmg"
hdiutil attach -nobrowse -plist "$work/writable.dmg" > "$work/mount.plist"
mountpoint="$(python3 -c 'import plistlib,sys; print(next(e["mount-point"] for e in plistlib.load(open(sys.argv[1], "rb"))["system-entities"] if "mount-point" in e))' "$work/mount.plist")"
mounted=true
osascript "$script_dir/layout.applescript" "$mountpoint"
[[ -f "$mountpoint/.DS_Store" ]] || { echo 'Finder did not save the installer layout.' >&2; exit 1; }
sync
hdiutil detach -quiet "$mountpoint"
mounted=false
hdiutil convert -quiet "$work/writable.dmg" -format UDZO -imagekey zlib-level=9 -o "$output"
echo "Created $output"
