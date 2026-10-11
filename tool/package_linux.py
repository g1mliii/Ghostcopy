#!/usr/bin/env python3
"""Prepare a Linux test/release archive and its update feed. Never publishes."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
import xml.etree.ElementTree as ET

from linux_update import RELEASE_BASE, validate_release, version_key


def prepare_bundle(bundle):
    assets = json.loads((bundle / 'data/flutter_assets/version.json').read_text())
    version = assets['version'] + '+' + assets['build_number']
    version_key(version)
    if not (bundle / 'ghostcopy-agent').is_file():
        raise ValueError('Build the companion CLI before packaging')
    (bundle / 'linux-version.json').write_text(json.dumps({'version': version}) + '\n')
    shutil.copy2(Path(__file__).with_name('linux_update.py'), bundle / 'linux_update.py')
    protocol = Path(__file__).resolve().parent.parent / 'linux/protocols/wlr-data-control-unstable-v1.xml'
    notice = ET.parse(protocol).getroot().findtext('copyright')
    if not notice:
        raise ValueError('Missing native Wayland protocol license')
    (bundle / 'wlr-data-control-LICENSE.txt').write_text(notice.strip() + '\n')
    return version


def package(bundle, output):
    version = prepare_bundle(bundle)
    output.mkdir(parents=True, exist_ok=True)
    archive = output / 'ghostcopy-linux-x64.tar.gz'
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix='ghostcopy-package-') as directory:
        package_root = Path(directory) / 'ghostcopy-linux-x64'
        shutil.copytree(bundle, package_root / 'bundle')
        for name in ('install_linux.py', 'linux_doctor.sh'):
            shutil.copy2(root / 'tool' / name, package_root / name)
        shutil.copy2(root / 'docs/linux-cachyos.md', package_root / 'README.md')
        with tarfile.open(archive, 'w:gz', dereference=True) as target:
            target.add(package_root, arcname=package_root.name)
    with archive.open('rb') as source:
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
    feed = validate_release({
        'schema': 1, 'version': version, 'sha256': digest,
        'size': archive.stat().st_size,
        'url': RELEASE_BASE + 'linux-v' + version + '/ghostcopy-linux-x64.tar.gz',
    })
    (output / 'latest.json').write_text(json.dumps(feed, indent=2) + '\n')
    (output / 'ghostcopy-linux-x64.tar.gz.sha256').write_text(digest + '  ' + archive.name + '\n')
    print(f'Prepared {archive} for linux-v{version}. Nothing was published.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, default=Path('build/linux/x64/release/bundle'))
    parser.add_argument('--output', type=Path, default=Path('build/linux-package'))
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    if sys.platform != 'linux':
        parser.error('Package on Linux to preserve executable permissions')
    if args.prepare_only:
        prepare_bundle(args.bundle)
    else:
        package(args.bundle, args.output)
