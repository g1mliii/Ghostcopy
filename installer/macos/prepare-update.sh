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
python3 "$script_dir/verify-app.py" "$app" --require-updater
xcrun stapler validate "$release/GhostCopy.dmg"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[1-9][0-9]*$ ]] || {
    echo 'Release version must be x.y.z and build number a positive integer.' >&2; exit 1;
}
bin="$("$script_dir/sparkle-tools.sh")"

# The signing key must be the one the shipped app will check against.
#
# generate_appcast signs with the Keychain account below, and both verification
# steps at the end of this script check against that SAME account - so a
# regenerated, imported or otherwise wrong key there passes every local check
# while every installed copy rejects the update, because each verifies against
# the SUPublicEDKey baked into its own bundle. verify-app.py confirms the app
# carries the expected key but never compares it with the signing account, so
# nothing in the pipeline related the two.
#
# Checked here, before anything is written, so a mismatch costs nothing to
# recover from.
embedded_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")"
signing_key="$("$bin/generate_keys" --account com.ghostcopy.ghostcopy -p)"
if [[ "$signing_key" != "$embedded_key" ]]; then
    echo 'The Sparkle signing key does not match the one embedded in the app.' >&2
    echo "  app SUPublicEDKey: $embedded_key" >&2
    echo "  keychain account:  $signing_key" >&2
    echo 'Signing with this key would ship an update every install rejects.' >&2
    exit 1
fi

feed_url='https://github.com/g1mliii/Ghostcopy/releases/download/macos-updates/appcast.xml'
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
