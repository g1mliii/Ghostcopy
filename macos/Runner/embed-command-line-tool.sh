#!/bin/bash
# Xcode build phase: compile the `ghostcopy` command (packages/ghostcopy_agent)
# into Contents/Helpers and sign it before Xcode signs the app around it.
# Archive export re-signs it with the app's Developer ID identity.
set -euo pipefail
helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$helpers"
cd "$SRCROOT/../packages/ghostcopy_agent"
"$FLUTTER_ROOT/bin/dart" pub get >/dev/null
"$FLUTTER_ROOT/bin/dart" compile exe bin/ghostcopy.dart -o "$helpers/ghostcopy"
# dart compile exe builds for the machine it runs on and cannot cross-compile
# to macOS, so the command is arm64 only - like the app, since Intel was dropped.
if [[ "$(lipo -archs "$helpers/ghostcopy")" != arm64 ]]; then
    echo "error: ghostcopy was compiled for $(lipo -archs "$helpers/ghostcopy"), not arm64; build on Apple silicon." >&2
    exit 1
fi
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == YES && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    # Hardened Runtime, which notarization requires, kills a Dart executable at
    # launch unless it may map its snapshot as executable memory.
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime \
        --timestamp=none --identifier com.ghostcopy.ghostcopy.cli \
        --entitlements "$SRCROOT/Runner/CommandLineTool.entitlements" \
        "$helpers/ghostcopy"
fi
