#!/bin/bash
# Build the App Store archive for TestFlight, upload its debug symbols to
# Sentry, and open it in Xcode's Organizer for Distribute App.
#
#   installer/ios/build-testflight.sh --build-name=1.0.0 --build-number=8
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
if [[ ! -f ios/Runner/GoogleService-Info.plist ]]; then
    echo "ios/Runner/GoogleService-Info.plist is missing (gitignored; copy it in)" >&2
    exit 1
fi
flutter build ipa --release "$@"
archive="$root/build/ios/archive/Runner.xcarchive"
"$root/installer/upload-debug-symbols.sh" "$archive/dSYMs"
open "$archive"
echo "In Organizer: Distribute App > App Store Connect > Distribute."
