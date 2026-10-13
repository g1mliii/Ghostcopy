#!/usr/bin/env python3
"""Install a built Linux bundle and KDE integration for the current user."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

# Beside this script in the repository and in the release archive.
import linux_integration
from linux_integration import owned_paths, remove_owned


def install(bundle: Path, prefix: Path) -> None:
    bundle = bundle.resolve(strict=True)
    prefix = prefix.resolve()
    executable = bundle / 'ghostcopy'
    if not executable.is_file() or not (bundle / 'data/flutter_assets').is_dir():
        raise ValueError('Expected a complete flutter build linux release bundle')
    target = prefix / 'lib/ghostcopy'
    if not target.resolve().is_relative_to(prefix):
        raise ValueError('Installation directory escapes the prefix')
    if target == bundle or target in bundle.parents or bundle in target.parents:
        raise ValueError('The build bundle and installation must be separate')
    # Refuse symlinks before copying into an existing installation. The bundle
    # itself may contain relative library symlinks, which copytree dereferences.
    if target.exists() and any(p.is_symlink() for p in [target, *target.rglob('*')]):
        raise ValueError('Installation contains symlinks; choose a clean prefix')
    manifest = target / 'install-manifest.json'
    previous = owned_paths(prefix, json.loads(manifest.read_text(encoding='utf-8'))
                           if manifest.is_file() else [])
    target.mkdir(parents=True, exist_ok=True)
    shutil.copytree(bundle, target, dirs_exist_ok=True)
    owned = [('lib/ghostcopy/' + p.relative_to(bundle).as_posix())
             for p in bundle.rglob('*') if p.is_file()]

    owned += linux_integration.install(prefix, cli=(bundle / 'ghostcopy-agent').is_file())
    # Record only our files. Uninstall does not touch credentials or history.
    manifest.write_text(json.dumps(owned, indent=2) + '\n', encoding='utf-8', newline='\n')
    # A reinstall overlays the new bundle, so drop what only the old one owned,
    # integration files included.
    current = {prefix / relative for relative in owned}
    remove_owned(prefix, [p for p in previous if p not in current])
    linux_integration.refresh_desktop(prefix)


def uninstall(prefix: Path) -> None:
    prefix = prefix.resolve()
    manifest = prefix / 'lib/ghostcopy/install-manifest.json'
    entries = json.loads(manifest.read_text(encoding='utf-8'))
    entries.append('lib/ghostcopy/install-manifest.json')
    paths = owned_paths(prefix, entries)
    # The updater's rollback copy is a whole previous install of ours.
    for backup in (prefix / 'lib').glob('.ghostcopy-backup-*'):
        if backup.is_dir() and not backup.is_symlink():
            shutil.rmtree(backup)
    paths.append(prefix / 'lib/.ghostcopy-update.lock')
    remove_owned(prefix, paths)
    # Remove the app's own login entry, if launch_at_startup created it.
    if sys.platform == 'linux' and prefix == Path.home() / '.local':
        config = Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home() / '.config')))
        autostart = config / 'autostart/ghostcopy.desktop'
        if autostart.is_file() and str(prefix / 'lib/ghostcopy/ghostcopy') in autostart.read_text():
            autostart.unlink()
    if sys.platform == 'linux' and shutil.which('update-desktop-database'):
        subprocess.run(['update-desktop-database', str(prefix / 'share/applications')], check=False)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, default=Path('build/linux/x64/release/bundle'))
    parser.add_argument('--prefix', type=Path, default=Path.home() / '.local')
    parser.add_argument('--uninstall', action='store_true')
    args = parser.parse_args()
    if sys.platform != 'linux':
        parser.error('Run the installer on Linux after building the Linux bundle')
    if os.geteuid() == 0:
        parser.error('Run without sudo: this is a per-user installation')
    if args.uninstall:
        uninstall(args.prefix)
        print('Removed GhostCopy application files. Saved account data was retained.')
    else:
        install(args.bundle, args.prefix)
        print('Installed. Launch GhostCopy from the application menu.')
        print('Restart Dolphin if Send with GhostCopy is not yet visible.')


if __name__ == '__main__':
    main()
