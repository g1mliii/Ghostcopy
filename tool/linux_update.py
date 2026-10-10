#!/usr/bin/env python3
"""GhostCopy per-user Linux updater. JSON stdout; diagnostics go to stderr."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import uuid

FEED = 'https://github.com/g1mliii/Ghostcopy/releases/download/linux-updates/latest.json'
RELEASE_BASE = 'https://github.com/g1mliii/Ghostcopy/releases/download/'
MAX_ARCHIVE = 256 * 1024 * 1024
MAX_EXPANDED = 1024 * 1024 * 1024


def version_key(version):
    match = re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\+([1-9][0-9]*)', version)
    if not match:
        raise ValueError('Expected a stable version such as 1.0.8+21')
    return tuple(int(part) for part in match.groups())


def validate_release(value):
    if not isinstance(value, dict) or value.get('schema') != 1:
        raise ValueError('Unsupported Linux update feed')
    version_key(value['version'])
    # Only immutable assets in this repository, not arbitrary installer URLs.
    expected = RELEASE_BASE + 'linux-v' + value['version'] + '/ghostcopy-linux-x64.tar.gz'
    if value.get('url') != expected:
        raise ValueError('Unexpected update download URL')
    if not re.fullmatch(r'[0-9a-f]{64}', value.get('sha256', '')):
        raise ValueError('Update feed is missing a SHA-256 checksum')
    if type(value.get('size')) is not int or not 0 < value['size'] <= MAX_ARCHIVE:
        raise ValueError('Invalid update size')
    return value


def fetch_release():
    request = urllib.request.Request(FEED, headers={'User-Agent': 'GhostCopy-Linux-Updater/1'})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read(65537)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise ValueError('The Linux update feed has not been published yet.') from error
        raise
    if len(payload) > 65536:
        raise ValueError('Update feed exceeds its size limit')
    return validate_release(json.loads(payload))


def installed_version(target):
    return json.loads((target / 'linux-version.json').read_text())['version']


def check(target):
    release = fetch_release()
    current = installed_version(target)
    return {**release, 'available': version_key(release['version']) > version_key(current),
            'current': current}


def verify_archive(archive, release):
    if archive.stat().st_size != release['size']:
        raise ValueError('Update size did not match the release feed')
    with archive.open('rb') as source:
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
    if digest != release['sha256']:
        raise ValueError('Update checksum did not match the release feed')


def prepare(target, expected):
    release = check(target)
    if not release['available'] or release['version'] != expected:
        raise ValueError('The release changed. Check for updates again.')
    cache = Path(os.environ.get('XDG_CACHE_HOME', str(Path.home() / '.cache')))
    if not cache.is_absolute():
        cache = Path.home() / '.cache'
    cache = cache / 'ghostcopy/updates'
    cache.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix='download-', dir=cache))
    try:
        archive = directory / 'update.tar.gz'
        request = urllib.request.Request(release['url'], headers={'User-Agent': 'GhostCopy-Linux-Updater/1'})
        with urllib.request.urlopen(request, timeout=30) as response, archive.open('wb') as output:
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > release['size']:
                    raise ValueError('Download exceeded the advertised size')
                output.write(chunk)
        verify_archive(archive, release)
        (directory / 'release.json').write_text(json.dumps(release))
        return {'directory': str(directory), 'version': release['version']}
    except Exception:
        # This is a freshly allocated private directory, never a supplied path.
        shutil.rmtree(directory)
        raise


def extract_bundle(archive, destination, version):
    """Extract regular bundle files only: no links, devices or traversal."""
    total = 0
    entries = 0
    seen = set()
    with tarfile.open(archive, 'r:gz') as source:
        for member in source:
            entries += 1
            if entries > 30000:
                raise ValueError('Archive contains too many entries')
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or '\\' in member.name:
                raise ValueError('Unsafe archive path')
            if not member.isdir() and not member.isfile():
                raise ValueError('Archive contains a link or special file')
            if path.parts[:2] != ('ghostcopy-linux-x64', 'bundle'):
                continue
            relative = Path(*path.parts[2:])
            output = destination / relative
            if member.isdir():
                output.mkdir(parents=True, exist_ok=True)
                continue
            if str(relative) in seen:
                raise ValueError('Duplicate archive file')
            seen.add(str(relative))
            total += member.size
            if total > MAX_EXPANDED or len(seen) > 20000:
                raise ValueError('Expanded update is too large')
            output.parent.mkdir(parents=True, exist_ok=True)
            with source.extractfile(member) as incoming, output.open('xb') as outgoing:
                shutil.copyfileobj(incoming, outgoing)
            output.chmod(0o755 if member.mode & 0o111 else 0o644)
    for name in ('ghostcopy', 'ghostcopy-agent', 'linux_update.py', 'linux-version.json'):
        if not (destination / name).is_file():
            raise ValueError(f'Incomplete update: missing {name}')
    if not (destination / 'data/flutter_assets').is_dir():
        raise ValueError('Incomplete Flutter assets')
    if installed_version(destination) != version:
        raise ValueError('Bundle version does not match the release feed')


def running(target):
    executable = target / 'ghostcopy'
    for process in Path('/proc').iterdir():
        if not process.name.isdigit():
            continue
        try:
            if (process / 'exe').resolve(strict=True) == executable:
                return True
        except (OSError, RuntimeError):
            pass
    return False


def apply_update(target, directory, wait_pid=None, restart=False):
    """Swap a complete bundle on one filesystem; keep a rollback copy."""
    import fcntl
    if target.is_symlink() or target.resolve() != target:
        raise ValueError('Cannot update a symlink installation')
    if not (target / 'install-manifest.json').is_file():
        raise ValueError('Install this build with install_linux.py before updating')
    release = validate_release(json.loads((directory / 'release.json').read_text()))
    if version_key(release['version']) <= version_key(installed_version(target)):
        raise ValueError('Refusing an older or already installed release')
    archive = directory / 'update.tar.gz'
    verify_archive(archive, release)
    lock_path = target.parent / '.ghostcopy-update.lock'
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if version_key(release['version']) <= version_key(installed_version(target)):
            raise ValueError('This update is no longer newer than the installation')
        with tempfile.TemporaryDirectory(prefix='.ghostcopy-stage-', dir=target.parent) as staging:
            staging = Path(staging)
            fresh = staging / 'bundle'
            fresh.mkdir()
            extract_bundle(archive, fresh, release['version'])
            if wait_pid:
                (directory / 'ready').write_text('ready')
            deadline = time.monotonic() + 120
            while ((wait_pid and Path(f'/proc/{wait_pid}').exists()) or running(target)):
                if time.monotonic() > deadline:
                    raise ValueError('GhostCopy is still running. Quit it and try again.')
                time.sleep(0.25)
            # Preserve unowned user files without retaining obsolete libraries.
            owned = json.loads((target / 'install-manifest.json').read_text())
            for relative in owned:
                if not isinstance(relative, str) or '..' in PurePosixPath(relative).parts or Path(relative).is_absolute():
                    raise ValueError('Invalid installed file manifest')
            old_files = {name.removeprefix('lib/ghostcopy/') for name in owned
                         if name.startswith('lib/ghostcopy/')}
            for path in target.rglob('*'):
                if path.is_symlink():
                    raise ValueError('Cannot update an installation containing symlinks')
                relative = path.relative_to(target)
                if path.is_file() and relative.as_posix() not in old_files and relative.as_posix() != 'install-manifest.json':
                    output = fresh / relative
                    if not output.exists():
                        output.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(path, output)
            # Count only new package files, never newly preserved user files.
            with tarfile.open(archive, 'r:gz') as contents:
                new_files = ['lib/ghostcopy/' + '/'.join(PurePosixPath(m.name).parts[2:])
                             for m in contents if m.isfile() and
                             PurePosixPath(m.name).parts[:2] == ('ghostcopy-linux-x64', 'bundle')]
            external = [name for name in owned if not name.startswith('lib/ghostcopy/')]
            (fresh / 'install-manifest.json').write_text(json.dumps(external + new_files))
            backup = target.with_name('.ghostcopy-backup-' + uuid.uuid4().hex)
            target.rename(backup)
            try:
                fresh.rename(target)
            except OSError:
                backup.rename(target)
                raise
    if restart:
        subprocess.Popen([str(target / 'ghostcopy')], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {'installed': release['version'], 'backup': str(backup)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--prepare', metavar='VERSION')
    parser.add_argument('--apply', type=Path, metavar='DOWNLOAD_DIRECTORY')
    parser.add_argument('--wait-pid', type=int)
    parser.add_argument('--restart', action='store_true')
    args = parser.parse_args()
    if sys.platform != 'linux' or os.geteuid() == 0:
        parser.error('Run the Linux updater as your normal user, without sudo')
    target = Path(__file__).resolve().parent
    if not (target / 'install-manifest.json').is_file():
        parser.error('Install the bundle with install_linux.py first')
    if args.apply:
        # The GUI launches this detached; persist failures for recovery.
        cache = Path.home() / '.cache/ghostcopy'
        cache.mkdir(parents=True, exist_ok=True)
        try:
            result = apply_update(target, args.apply, args.wait_pid, args.restart)
            (cache / 'last-update.json').write_text(json.dumps(result))
        except Exception as error:
            (cache / 'last-update.json').write_text(json.dumps({'error': str(error)}))
            if args.restart and not running(target):
                subprocess.Popen([str(target / 'ghostcopy')], start_new_session=True,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            raise
    elif args.prepare:
        result = prepare(target, args.prepare)
    else:
        result = check(target)
    print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
