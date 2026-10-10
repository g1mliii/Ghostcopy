import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('updater', Path(__file__).with_name('linux_update.py'))
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)


def manifest(archive, version='1.0.9+22'):
    return {'schema': 1, 'version': version,
            'url': updater.RELEASE_BASE + 'linux-v' + version + '/ghostcopy-linux-x64.tar.gz',
            'size': archive.stat().st_size,
            'sha256': hashlib.sha256(archive.read_bytes()).hexdigest()}


def make_archive(archive, extras=(), version='1.0.9+22'):
    files = {'ghostcopy': b'new gui', 'ghostcopy-agent': b'new cli',
             'linux_update.py': b'new updater',
             'linux-version.json': json.dumps({'version': version}).encode(),
             'data/flutter_assets/example': b'asset'}
    with tarfile.open(archive, 'w:gz') as target:
        for name, value in files.items():
            member = tarfile.TarInfo('ghostcopy-linux-x64/bundle/' + name)
            member.size = len(value)
            member.mode = 0o755 if name in ('ghostcopy', 'ghostcopy-agent') else 0o644
            target.addfile(member, io.BytesIO(value))
        for member in extras:
            target.addfile(member, io.BytesIO(b''))


class LinuxUpdateTest(unittest.TestCase):
    def test_feed_rejects_external_urls_and_invalid_versions(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'update.tar.gz'
            make_archive(archive)
            value = manifest(archive)
            self.assertEqual(updater.validate_release(value), value)
            for changes in ({'url': 'https://evil.example/update.tar.gz'},
                            {'sha256': 'bad'}, {'size': -1}, {'size': True},
                            {'version': '1.0.9-beta+22'}, {'schema': 2}):
                with self.subTest(changes=changes), self.assertRaises(ValueError):
                    updater.validate_release({**value, **changes})
        self.assertGreater(updater.version_key('1.0.10+23'), updater.version_key('1.0.9+99'))

    def test_check_rejects_downgrades_and_equal_builds(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            (target / 'linux-version.json').write_text('{"version":"1.0.9+22"}')
            for version, available in [('1.0.9+21', False), ('1.0.9+22', False), ('1.0.9+23', True)]:
                with patch.object(updater, 'fetch_release', return_value={'version': version}):
                    self.assertEqual(updater.check(target)['available'], available)

    def test_checksum_and_size_are_both_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / 'update.tar.gz'
            make_archive(archive)
            release = manifest(archive)
            updater.verify_archive(archive, release)
            for changes in ({'size': release['size'] + 1}, {'sha256': '0' * 64}):
                with self.assertRaises(ValueError):
                    updater.verify_archive(archive, {**release, **changes})

    def test_extract_refuses_traversal_symlinks_duplicates_and_wrong_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for index, name in enumerate(('../outside', '/absolute', 'ghostcopy-linux-x64/bundle/../../outside',
                                          'ghostcopy-linux-x64/bundle/ghostcopy', 'link')):
                member = tarfile.TarInfo(name)
                if name == 'link':
                    member.type = tarfile.SYMTYPE
                    member.linkname = '/etc/passwd'
                archive = root / f'{index}.tar.gz'
                make_archive(archive, [member])
                with self.subTest(name=name), self.assertRaises(ValueError):
                    updater.extract_bundle(archive, root / f'out{index}', '1.0.9+22')
            archive = root / 'wrong-version.tar.gz'
            make_archive(archive)
            with self.assertRaises(ValueError):
                updater.extract_bundle(archive, root / 'wrong', '1.0.10+23')

    def test_extract_enforces_expanded_size(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'update.tar.gz'
            make_archive(archive)
            with patch.object(updater, 'MAX_EXPANDED', 2), self.assertRaises(ValueError):
                updater.extract_bundle(archive, root / 'bundle', '1.0.9+22')

    @unittest.skipUnless(sys.platform == 'linux', 'Uses Linux file locking')
    def test_apply_swaps_gui_and_cli_preserves_user_files_and_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target, download = self.install_fixture(root)
            with patch.object(updater, 'running', return_value=False):
                result = updater.apply_update(target, download)
            self.assertEqual((target / 'ghostcopy').read_bytes(), b'new gui')
            self.assertEqual((target / 'ghostcopy-agent').read_bytes(), b'new cli')
            self.assertTrue((target / 'ghostcopy').stat().st_mode & 0o111)
            self.assertEqual((target / 'personal.txt').read_text(), 'keep')
            self.assertFalse((target / 'obsolete.so').exists())
            self.assertEqual((Path(result['backup']) / 'ghostcopy').read_bytes(), b'old gui')
            owned = json.loads((target / 'install-manifest.json').read_text())
            self.assertIn('bin/ghostcopy', owned)
            self.assertNotIn('lib/ghostcopy/personal.txt', owned)

    @unittest.skipUnless(sys.platform == 'linux', 'Uses Linux file locking')
    def test_failed_swap_restores_previous_install(self):
        with tempfile.TemporaryDirectory() as directory:
            target, download = self.install_fixture(Path(directory))
            original = Path.rename

            def fail_fresh(path, destination):
                if path.name == 'bundle':
                    raise OSError('simulated rename failure')
                return original(path, destination)

            with patch.object(updater, 'running', return_value=False), patch.object(Path, 'rename', fail_fresh):
                with self.assertRaises(OSError):
                    updater.apply_update(target, download)
            self.assertEqual((target / 'ghostcopy').read_bytes(), b'old gui')
            self.assertEqual(updater.installed_version(target), '1.0.8+21')

    @unittest.skipUnless(sys.platform == 'linux', 'Uses Linux file locking')
    def test_running_app_timeout_leaves_installation_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            target, download = self.install_fixture(Path(directory))
            with patch.object(updater, 'running', return_value=True), patch.object(updater.time, 'monotonic', side_effect=[0, 121]):
                with self.assertRaisesRegex(ValueError, 'still running'):
                    updater.apply_update(target, download)
            self.assertEqual((target / 'ghostcopy').read_bytes(), b'old gui')

    def install_fixture(self, root):
        target = root / 'prefix/lib/ghostcopy'
        target.mkdir(parents=True)
        (target / 'ghostcopy').write_bytes(b'old gui')
        (target / 'obsolete.so').write_bytes(b'old library')
        (target / 'personal.txt').write_text('keep')
        (target / 'linux-version.json').write_text('{"version":"1.0.8+21"}')
        (target / 'install-manifest.json').write_text(json.dumps([
            'lib/ghostcopy/ghostcopy', 'lib/ghostcopy/obsolete.so',
            'lib/ghostcopy/linux-version.json', 'bin/ghostcopy']))
        download = root / 'download'
        download.mkdir()
        archive = download / 'update.tar.gz'
        make_archive(archive)
        (download / 'release.json').write_text(json.dumps(manifest(archive)))
        return target, download


if __name__ == '__main__':
    unittest.main()
