#!/usr/bin/env python3
"""Install a built Linux bundle and KDE integration for the current user."""

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

APP_ID = 'com.ghostcopy.ghostcopy'


def desktop_exec(value: str) -> str:
    """Quote one Exec argument through both desktop-entry escaping layers."""
    if '\n' in value or '\r' in value:
        raise ValueError('Desktop executable path contains a newline')
    escaped = ''.join('\\' + ch if ch in '\\"`$' else ch for ch in value)
    return '"' + escaped.replace('\\', '\\\\').replace('%', '%%') + '"'


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
    target.mkdir(parents=True, exist_ok=True)
    shutil.copytree(bundle, target, dirs_exist_ok=True)
    owned = [('lib/ghostcopy/' + p.relative_to(bundle).as_posix())
             for p in bundle.rglob('*') if p.is_file()]

    def write(relative: str, content: str, executable_file: bool = False) -> None:
        output = prefix / relative
        if output.is_symlink() or not output.resolve().is_relative_to(prefix):
            raise ValueError(f'Refusing to replace a symlink: {output}')
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(content, encoding='utf-8', newline='\n')
        if executable_file:
            output.chmod(0o755)
        owned.append(relative)

    launcher = prefix / 'bin/ghostcopy-desktop'
    write('bin/ghostcopy-desktop',
          '#!/bin/sh\nexec ' + shlex.quote(str(target / 'ghostcopy')) + ' "$@"\n', True)
    # A real argv array preserves spaces, percent signs, quotes and newlines.
    # One headless process per file matches Windows Explorer's send behavior.
    write('bin/ghostcopy-send',
          '#!/usr/bin/env python3\nimport subprocess\nimport sys\n'
          f'app = {str(target / "ghostcopy")!r}\n'
          'status = 0\n'
          'for filename in sys.argv[1:]:\n'
          '    result = subprocess.run([app, "--send-file", filename], check=False)\n'
          '    if result.returncode != 0:\n'
          '        status = 1\n'
          'sys.exit(status)\n', True)
    # The CLI is separately named from the GUI and keeps its documented name.
    if (target / 'ghostcopy-agent').is_file():
        write('bin/ghostcopy', '#!/bin/sh\nexec ' +
              shlex.quote(str(target / 'ghostcopy-agent')) + ' "$@"\n', True)

    icon = target / 'data/flutter_assets/assets/icons/app_icon.png'
    write(f'share/applications/{APP_ID}.desktop',
          '[Desktop Entry]\nType=Application\nName=GhostCopy\n'
          'Comment=Sync your clipboard across devices\n'
          f'Exec={desktop_exec(str(launcher))} %u\n'
          f'Icon={str(icon).replace(chr(92), chr(92) * 2)}\n'
          'Terminal=false\nCategories=Utility;\n'
          'MimeType=x-scheme-handler/ghostcopy;\n'
          f'StartupWMClass={APP_ID}\nStartupNotify=false\n')
    write(f'share/kio/servicemenus/{APP_ID}.send.desktop',
          '[Desktop Entry]\nType=Service\nMimeType=all/allfiles;\n'
          'Actions=send;\nX-KDE-Protocols=file\n'
          '\n[Desktop Action send]\nName=Send with GhostCopy\n'
          'Icon=edit-paste\n'
          f'Exec={desktop_exec(str(prefix / "bin/ghostcopy-send"))} %F\n', True)
    # Record only our files. Uninstall does not touch credentials or history.
    write('lib/ghostcopy/install-manifest.json', json.dumps(owned, indent=2) + '\n')
    refresh_desktop(prefix)


def refresh_desktop(prefix: Path) -> None:
    if sys.platform != 'linux':
        return
    desktop_dir = prefix / 'share/applications'
    if shutil.which('update-desktop-database'):
        subprocess.run(['update-desktop-database', str(desktop_dir)], check=True)
    # Only set a default handler when this prefix is actually discoverable by
    # the desktop. Custom staging prefixes must never change the user's MIME map.
    data_home = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share')))
    if prefix / 'share' == data_home and shutil.which('xdg-mime'):
        subprocess.run(['xdg-mime', 'default', APP_ID + '.desktop',
                        'x-scheme-handler/ghostcopy'], check=True)


def uninstall(prefix: Path) -> None:
    prefix = prefix.resolve()
    manifest = prefix / 'lib/ghostcopy/install-manifest.json'
    entries = json.loads(manifest.read_text(encoding='utf-8'))
    entries.append('lib/ghostcopy/install-manifest.json')
    paths = []
    for relative in entries:
        candidate = prefix / relative
        if not candidate.resolve().is_relative_to(prefix) or candidate.is_symlink():
            raise ValueError('Unsafe installation manifest path')
        paths.append(candidate)
    # No recursive deletion. Remove only recorded files and now-empty parents.
    for candidate in paths:
        candidate.unlink(missing_ok=True)
    for parent in sorted({p.parent for p in paths}, key=lambda p: len(p.parts), reverse=True):
        while parent != prefix:
            try:
                parent.rmdir()
            except OSError:
                break
            parent = parent.parent
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
