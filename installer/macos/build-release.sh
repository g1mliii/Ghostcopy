#!/bin/bash
# Archive/export preserves Xcode's resolved entitlements and distribution profile.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$script_dir/../.." && pwd)"
cd "$root"
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 NOTARY_KEYCHAIN_PROFILE [flutter build options...]" >&2
    exit 1
fi
profile="$1"
shift
output="$root/build/installer/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$output"
git rev-parse HEAD > "$output/source-commit.txt"
git status --porcelain --untracked-files=normal > "$output/source-dirty.txt"
# macOS 27 rejects some Rust proc-macro dylibs stripped by older toolchains.
# Keep host build-dependency debug info; Xcode still strips the shipped app.
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG=true
export CARGO_PROFILE_RELEASE_STRIP=none
flutter build macos --release --config-only "$@"
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner \
    -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$output/GhostCopy.xcarchive" -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath "$output/GhostCopy.xcarchive" \
    -exportPath "$output/export" -exportOptionsPlist "$script_dir/ExportOptions.plist" \
    -allowProvisioningUpdates
app="$output/export/ghostcopy.app"
# --sparkle-bin so the signing key is compared with the app's SUPublicEDKey
# here, seconds in, rather than after both notarization round trips.
python3 "$script_dir/verify-app.py" "$app" --require-updater \
    --sparkle-bin "$("$script_dir/sparkle-tools.sh")"
# The certificate Xcode signed the app with, by fingerprint. Three Keychain
# certificates share the name "Developer ID Application: Subaig Suri", so
# signing the DMG by name was ambiguous - and the old authority's ones stop
# being able to sign anything on 2027-02-01. Refuse anything but G2 here,
# minutes in, rather than after two notarization round trips.
certs="$(mktemp -d)"
(cd "$certs" && codesign -d --extract-certificates=cert "$app" 2>/dev/null)
identity="$(openssl x509 -inform DER -in "$certs/cert0" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
# Spaces stripped: LibreSSL prints OU=G2, OpenSSL 3 (Homebrew's) OU = G2.
issuer="$(openssl x509 -inform DER -in "$certs/cert0" -noout -issuer | tr -d ' ')"
rm -rf "$certs"
if [[ "$issuer" != *"OU=G2"* ]]; then
    echo "The app was signed by a certificate from the old Developer ID authority" >&2
    echo "($identity, $issuer), which cannot sign after 2027-02-01." >&2
    echo "Revoke or remove it so Xcode picks the G2 one, then rebuild." >&2
    exit 1
fi
echo "Signing with the app's own G2 certificate: $identity"
# Crash reports from this build need its symbols; they exist only now.
"$root/installer/upload-debug-symbols.sh" "$output/GhostCopy.xcarchive/dSYMs"
# Notarize/staple the app too, so the copy dragged out of the DMG has a ticket.
ditto -c -k --keepParent "$app" "$output/GhostCopy.zip"
xcrun notarytool submit "$output/GhostCopy.zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
"$script_dir/create-dmg.sh" "$app" "$output/GhostCopy.dmg"
codesign --sign "$identity" --timestamp "$output/GhostCopy.dmg"
xcrun notarytool submit "$output/GhostCopy.dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$output/GhostCopy.dmg"
xcrun stapler validate "$output/GhostCopy.dmg"
# RELEASE_NOTES is an HTML fragment; without it the update dialog is blank
# and publish-update.sh will refuse the candidate.
"$script_dir/prepare-update.sh" "$output" ${RELEASE_NOTES:+"$RELEASE_NOTES"}
echo "Signed and notarized: $output/GhostCopy.dmg"
echo 'Still required: install from this DMG and run the LaunchServices smoke test (see README).'
