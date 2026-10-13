#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter pub get
flutter build linux --release "$@"
# The CLI/MCP binary accompanies the GUI, without colliding with its filename.
(
  cd packages/ghostcopy_agent
  dart pub get
  dart compile exe bin/ghostcopy.dart -o ../../build/linux/x64/release/bundle/ghostcopy-agent
)
python3 tool/package_linux.py --prepare-only
printf '%s\n' 'Build complete. Quit GhostCopy, then run: python3 tool/install_linux.py'
