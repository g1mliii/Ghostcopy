#!/usr/bin/env bash
# Point ghostcopy-bin at a published Linux release and regenerate .SRCINFO.
#
#   installer/linux/aur/update-pkgbuild.sh 1.0.10 26
#
# Reads the archive digest from the release's .sha256 asset, so run it only
# after linux-v<version>+<build> is published. The LICENSE digest comes from
# the same tag.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 VERSION BUILD   (e.g. 1.0.10 26)" >&2
  exit 2
fi
version=$1
build=$2
here=$(cd "$(dirname "$0")/ghostcopy-bin" && pwd)
tag="linux-v${version}+${build}"
base=https://github.com/g1mliii/Ghostcopy

archive_sha=$(curl -fsSL "$base/releases/download/$tag/ghostcopy-linux-x64.tar.gz.sha256" | cut -d' ' -f1)
license_sha=$(curl -fsSL "https://raw.githubusercontent.com/g1mliii/Ghostcopy/$tag/LICENSE" | sha256sum | cut -d' ' -f1)
[[ $archive_sha =~ ^[0-9a-f]{64}$ ]] || { echo "No checksum published for $tag" >&2; exit 1; }

current=$(sed -n 's/^pkgver=//p' "$here/PKGBUILD")
current_build=$(sed -n 's/^_build=//p' "$here/PKGBUILD")
rel=1
if [[ $current == "$version" && $current_build == "$build" ]]; then
  # Same upstream release, packaging change only.
  rel=$(( $(sed -n 's/^pkgrel=//p' "$here/PKGBUILD") + 1 ))
fi

python3 - "$here/PKGBUILD" "$version" "$build" "$rel" "$archive_sha" "$license_sha" <<'EOF'
import re, sys
path, version, build, rel, archive, license_ = sys.argv[1:]
text = open(path).read()
text = re.sub(r'(?m)^pkgver=.*$', f'pkgver={version}', text)
text = re.sub(r'(?m)^_build=.*$', f'_build={build}', text)
text = re.sub(r'(?m)^pkgrel=.*$', f'pkgrel={rel}', text)
text = re.sub(r"sha256sums=\('[0-9a-f]{64}'\n(\s+)'[0-9a-f]{64}'\)",
              lambda m: f"sha256sums=('{archive}'\n{m.group(1)}'{license_}')", text)
open(path, 'w').write(text)
EOF

(cd "$here" && makepkg --printsrcinfo > .SRCINFO)
echo "ghostcopy-bin -> ${version}+${build}, pkgrel ${rel}. Test with makepkg, then publish (README.md)."
