#!/bin/bash
# Print the directory of the pinned, checksum-verified Sparkle release tools.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$script_dir/../.." && pwd)"
cache="$root/build/installer/sparkle-2.10.0"
if [[ ! -x "$cache/bin/generate_appcast" ]]; then
    mkdir -p "$cache"
    curl --fail --location --silent --show-error \
        https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz \
        -o "$cache/Sparkle.tar.xz"
    echo "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c  $cache/Sparkle.tar.xz" | shasum -a 256 -c - >&2
    tar -xf "$cache/Sparkle.tar.xz" -C "$cache"
fi
printf '%s\n' "$cache/bin"
