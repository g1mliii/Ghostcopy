#!/bin/bash
# Prepare a signed appcast + versioned DMG locally. This never publishes.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 build/installer/RELEASE_DIRECTORY [RELEASE_NOTES_HTML]" >&2
    exit 1
fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
release="$(cd "$1" && pwd)"
notes="${2:-}"
[[ -z "$notes" || -f "$notes" ]] || { echo "No such release notes file: $notes" >&2; exit 1; }
app="$release/export/ghostcopy.app"
bin="$("$script_dir/sparkle-tools.sh")"
# --sparkle-bin so a standalone run of this script gets the signing-key
# comparison too, not only the one build-release.sh performs.
python3 "$script_dir/verify-app.py" "$app" --require-updater --sparkle-bin "$bin"
xcrun stapler validate "$release/GhostCopy.dmg"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[1-9][0-9]*$ ]] || {
    echo 'Release version must be x.y.z and build number a positive integer.' >&2; exit 1;
}
# The signing key is compared with the app's SUPublicEDKey by verify-app.py
# above, which build-release.sh also runs before it notarizes anything. It
# lived here first, which meant a mismatch surfaced only after both
# notarization round trips and was missed entirely by any path that did not
# come through this script.

# Read from the app rather than written out again. This asks "what build is
# already published?", and it has to ask the feed the shipped app actually
# reads - a second copy here could point somewhere else, and a 404 from the
# wrong URL is treated below as "nothing published yet", which silently
# disables the build-number check.
feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app/Contents/Info.plist")"
# A real previous feed must be reachable and valid. Only 404 permits bootstrap.
status="$(curl --location --silent --show-error --output "$release/previous-appcast.xml" --write-out '%{http_code}' "$feed_url")"
case "$status" in
    200)
        python3 - "$release/previous-appcast.xml" "$build" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
versions = [int(node.text) for node in ET.parse(sys.argv[1]).iter(ns + 'version')]
if versions and int(sys.argv[2]) <= max(versions):
    raise SystemExit('Increase --build-number beyond the published macOS build.')
PY
        ;;
    404) ;;
    *) echo "Cannot check published version: HTTP $status" >&2; exit 1 ;;
esac
tag="macos-v$version-$build"
updates="$release/updates"
[[ ! -e "$updates" ]] || { echo "Already prepared: $updates" >&2; exit 1; }
mkdir -p "$updates"
ditto "$release/GhostCopy.dmg" "$updates/GhostCopy-$version-$build.dmg"
# Release notes reach the update dialog only as an HTML fragment named after
# the archive. generate_appcast embeds such a fragment into the signed appcast;
# a .md file or a full HTML document becomes a releaseNotesLink instead,
# pointing at a URL nothing in this pipeline uploads.
if [[ -n "$notes" ]]; then
    if grep -qi '<!DOCTYPE\|<body' "$notes"; then
        echo 'Release notes must be an HTML fragment: no DOCTYPE, no <body>.' >&2
        exit 1
    fi
    cp "$notes" "$updates/GhostCopy-$version-$build.html"
fi
"$bin/generate_appcast" --account com.ghostcopy.ghostcopy --maximum-deltas 0 \
    --download-url-prefix "https://github.com/g1mliii/Ghostcopy/releases/download/$tag/" \
    "$updates"
python3 "$script_dir/check-release-notes.py" "$updates/appcast.xml" --warn
"$bin/sign_update" --account com.ghostcopy.ghostcopy --verify "$updates/appcast.xml"
python3 - "$updates" <<'PY'
import pathlib, sys, xml.etree.ElementTree as ET
root = pathlib.Path(sys.argv[1])
enclosure = ET.parse(root / 'appcast.xml').find('./channel/item/enclosure')
assert enclosure is not None
signature = enclosure.attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature']
(root / 'archive-signature.txt').write_text(signature + '\n')
PY
"$bin/sign_update" --account com.ghostcopy.ghostcopy --verify \
    "$updates/GhostCopy-$version-$build.dmg" "$(cat "$updates/archive-signature.txt")"
printf '%s\n' "$tag" > "$updates/release-tag.txt"
echo "Prepared and signature-verified $updates"
echo 'Review the app and release notes before publishing with publish-update.sh.'
