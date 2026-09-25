#!/bin/bash
# Upload a release build's debug symbols to Sentry (spiderweb/flutter), so its
# native crash reports show functions and lines instead of addresses.
#
#   installer/upload-debug-symbols.sh <dSYMs dir or file>...
#
# The org auth token lives in the login Keychain, never in the repo:
#   security add-generic-password -U -a sentry -s ghostcopy-sentry-auth-token -w "$(pbpaste)"
# (from the clipboard: the interactive -w prompt cuts input at 128 characters,
# and Sentry org tokens are longer.)
#
# Symbols exist only while the build does, so this runs as part of it. No
# token or no sentry-cli skips with a warning; a failed upload fails the build.
set -euo pipefail
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <dSYMs dir or file>..." >&2
    exit 1
fi
token="$(security find-generic-password -a sentry -s ghostcopy-sentry-auth-token -w 2>/dev/null || true)"
if [[ -z "$token" ]]; then
    echo "warning: no Sentry token in the Keychain (ghostcopy-sentry-auth-token); symbols NOT uploaded" >&2
    exit 0
fi
if ! command -v sentry-cli >/dev/null; then
    echo "warning: sentry-cli missing (brew install getsentry/tools/sentry-cli); symbols NOT uploaded" >&2
    exit 0
fi
SENTRY_AUTH_TOKEN="$token" sentry-cli debug-files upload \
    --org spiderweb --project flutter --wait "$@"
