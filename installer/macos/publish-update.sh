#!/bin/bash
# Explicit publication step. Run only for an approved release candidate.
set -euo pipefail
if [[ $# -ne 3 ]]; then
    echo "Usage: $0 RELEASE_DIRECTORY PUSHED_COMMIT_SHA RELEASE_NOTES_FILE" >&2
    exit 1
fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
release="$(cd "$1" && pwd)"
commit="$2"
notes="$3"
[[ "$commit" =~ ^[0-9a-f]{40}$ && -f "$notes" ]] || { echo 'Supply a full pushed commit SHA and release notes file.' >&2; exit 1; }
[[ -f "$release/source-commit.txt" && -f "$release/source-dirty.txt" ]] || {
    echo 'Missing source provenance. Build with build-release.sh.' >&2; exit 1;
}
[[ "$(cat "$release/source-commit.txt")" = "$commit" && ! -s "$release/source-dirty.txt" ]] || {
    echo 'Publish only a candidate built from the supplied clean commit.' >&2; exit 1;
}
updates="$release/updates"
tag="$(cat "$updates/release-tag.txt")"
repo='g1mliii/Ghostcopy'
bin="$("$script_dir/sparkle-tools.sh")"
"$bin/sign_update" --account com.ghostcopy.ghostcopy --verify "$updates/appcast.xml"
# Validate the commit exists remotely before creating any release.
gh api "repos/$repo/commits/$commit" --silent
# Upload binary before exposing it in the stable feed. Never overwrite binaries.
gh release create "$tag" "$updates/"*.dmg --repo "$repo" --target "$commit" \
    --title "GhostCopy ${tag#macos-v} for macOS" --notes-file "$notes" --draft
gh release edit "$tag" --repo "$repo" --draft=false --latest=false
# The feed has its own fixed tag so Windows/Android releases cannot change it.
if gh release view macos-updates --repo "$repo" >/dev/null 2>&1; then
    gh release upload macos-updates "$updates/appcast.xml" --repo "$repo" --clobber
else
    gh release create macos-updates "$updates/appcast.xml" --repo "$repo" \
        --target "$commit" --title 'GhostCopy macOS update feed' \
        --notes 'Signed Sparkle update feed. Installers are in the versioned macOS releases.' \
        --prerelease --latest=false
fi
curl --fail --location --silent --show-error \
    https://github.com/g1mliii/Ghostcopy/releases/download/macos-updates/appcast.xml \
    -o "$release/published-appcast.xml"
cmp "$updates/appcast.xml" "$release/published-appcast.xml"
echo "Published $tag and verified the live update feed."
