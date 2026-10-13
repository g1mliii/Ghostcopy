#!/usr/bin/env python3
"""GhostCopy's Linux desktop integration: launchers, menu entry, Dolphin action.

The one definition of these files. install_linux.py writes them for a per-user
install, the AUR PKGBUILD for /usr, and the in-app updater rewrites them after
it swaps a bundle. The module ships inside the bundle, so the updater uses the
copy from the release it just installed and a release that changes any of
these files reaches people who update in-app.
"""

import argparse
import os
from pathlib import Path, PurePosixPath
import shlex
import shutil
import subprocess
import sys

APP_ID = 'com.ghostcopy.ghostcopy'
APP_DIR = 'lib/ghostcopy'
ICON = 'data/flutter_assets/assets/icons/app_icon.png'


def desktop_exec(value: str) -> str:
    """Quote one Exec argument through both desktop-entry escaping layers."""
    if '\n' in value or '\r' in value:
        raise ValueError('Desktop executable path contains a newline')
    escaped = ''.join('\\' + ch if ch in '\\"`$' else ch for ch in value)
    return '"' + escaped.replace('\\', '\\\\').replace('%', '%%') + '"'


def entries(app_dir, bin_dir, icon, cli=True):
    """The integration files, keyed by their path under the prefix.

    Each value is (content, executable). Paths inside the content are where
    things are installed - [app_dir] for the bundle, [bin_dir] for the
    commands - which for a package differ from where the files are written.
    """
    app = shlex.quote(str(PurePosixPath(app_dir) / 'ghostcopy'))
    files = {
        'bin/ghostcopy-desktop': ('#!/bin/sh\nexec ' + app + ' "$@"\n', True),
        # "$@" passes each selected file exactly, spaces, quotes and newlines
        # included. One headless send per file, as Windows Explorer does.
        'bin/ghostcopy-send': (
            '#!/bin/sh\nstatus=0\nfor file in "$@"; do\n'
            '  ' + app + ' --send-file "$file" || status=1\n'
            'done\nexit "$status"\n', True),
        f'share/applications/{APP_ID}.desktop': (
            '[Desktop Entry]\nType=Application\nName=GhostCopy\n'
            'Comment=Sync your clipboard across devices\n'
            f'Exec={desktop_exec(str(PurePosixPath(bin_dir) / "ghostcopy-desktop"))} %u\n'
            f'Icon={str(icon).replace(chr(92), chr(92) * 2)}\n'
            'Terminal=false\nCategories=Utility;\n'
            'MimeType=x-scheme-handler/ghostcopy;\n'
            f'StartupWMClass={APP_ID}\nStartupNotify=false\n', False),
        f'share/kio/servicemenus/{APP_ID}.send.desktop': (
            '[Desktop Entry]\nType=Service\nMimeType=all/allfiles;\n'
            'Actions=send;\nX-KDE-Protocols=file\n'
            '\n[Desktop Action send]\nName=Send with GhostCopy\n'
            'Icon=edit-paste\n'
            f'Exec={desktop_exec(str(PurePosixPath(bin_dir) / "ghostcopy-send"))} %F\n', True),
    }
    # The CLI is separately named from the GUI and keeps its documented name.
    if cli:
        files['bin/ghostcopy'] = (
            '#!/bin/sh\nexec ' + shlex.quote(str(PurePosixPath(app_dir) / 'ghostcopy-agent')) +
            ' "$@"\n', True)
    return files


def write(root, files):
    """Write [files] under [root], all or none; returns their relative paths.

    Every file is checked and staged beside its target before any is
    replaced, so a symlink, a permission error or a full disk leaves the
    previous set intact rather than half rewritten.
    """
    root = Path(root)
    outputs = []
    for relative in files:
        output = root / relative
        if output.is_symlink() or not output.resolve().is_relative_to(root.resolve()):
            raise ValueError(f'Refusing to replace a symlink: {output}')
        outputs.append(output)
    staged = []
    try:
        for output, (content, executable) in zip(outputs, files.values()):
            output.parent.mkdir(parents=True, exist_ok=True)
            temporary = output.with_name('.' + output.name + '.ghostcopy-new')
            staged.append(temporary)
            temporary.write_text(content, encoding='utf-8', newline='\n')
            temporary.chmod(0o755 if executable else 0o644)
        # Renames within one directory: atomic each, and not expected to fail.
        for temporary, output in zip(staged, outputs):
            os.replace(temporary, output)
    finally:
        for temporary in staged:
            temporary.unlink(missing_ok=True)
    return list(files)


def owned_paths(prefix, entries_):
    """Manifest entries as paths, refusing any that leave the prefix."""
    paths = []
    for relative in entries_:
        candidate = prefix / relative
        if not candidate.resolve().is_relative_to(prefix) or candidate.is_symlink():
            raise ValueError('Unsafe installation manifest path')
        paths.append(candidate)
    return paths


def remove_owned(prefix, paths):
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


def install(prefix, cli, previous=()):
    """Write the integration for the per-user layout under [prefix].

    [cli] is whether the release ships ghostcopy-agent - asked of the new
    bundle, since an install overlaid on an older one may still hold its
    agent. [previous] is the manifest's earlier integration entries; any
    this release no longer writes are removed. Returns the entries written.
    """
    prefix = Path(prefix).resolve()
    app_dir = prefix / APP_DIR
    written = write(prefix, entries(app_dir, prefix / 'bin', app_dir / ICON, cli=cli))
    stale = [relative for relative in previous if relative not in written]
    remove_owned(prefix, owned_paths(prefix, stale))
    return written


def refresh_desktop(prefix):
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


def main():
    """For packages: write the files into a staging root such as $pkgdir/usr."""
    parser = argparse.ArgumentParser(description=main.__doc__)
    parser.add_argument('--root', type=Path, required=True,
                        help='where to write, e.g. "$pkgdir/usr"')
    parser.add_argument('--app-dir', required=True, help='installed bundle, e.g. /opt/ghostcopy')
    parser.add_argument('--bin-dir', required=True, help='installed commands, e.g. /usr/bin')
    parser.add_argument('--icon', default=APP_ID, help='icon name or absolute path')
    args = parser.parse_args()
    args.root.mkdir(parents=True, exist_ok=True)
    write(args.root, entries(args.app_dir, args.bin_dir, args.icon))


if __name__ == '__main__':
    main()
