from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
import linux_integration  # noqa: E402


class LinuxIntegrationTest(unittest.TestCase):
    def test_package_files_point_at_the_installed_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'pkg/usr'
            argv = ['linux_integration.py', '--root', str(root),
                    '--app-dir', '/opt/ghostcopy', '--bin-dir', '/usr/bin']
            with patch.object(sys, 'argv', argv):
                linux_integration.main()
            entry = (root / 'share/applications/com.ghostcopy.ghostcopy.desktop').read_text()
            self.assertIn('Exec="/usr/bin/ghostcopy-desktop" %u', entry)
            self.assertIn('Icon=com.ghostcopy.ghostcopy', entry)
            menu = (root / 'share/kio/servicemenus/com.ghostcopy.ghostcopy.send.desktop').read_text()
            self.assertIn('Exec="/usr/bin/ghostcopy-send" %F', menu)
            self.assertIn('/opt/ghostcopy/ghostcopy --send-file "$file"',
                          (root / 'bin/ghostcopy-send').read_text())
            self.assertIn('exec /opt/ghostcopy/ghostcopy-agent "$@"',
                          (root / 'bin/ghostcopy').read_text())
            if sys.platform == 'linux':
                self.assertTrue((root / 'bin/ghostcopy-desktop').stat().st_mode & 0o111)
                self.assertFalse(
                    (root / 'share/applications/com.ghostcopy.ghostcopy.desktop').stat().st_mode & 0o111)

    def test_a_failed_write_changes_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            linux_integration.write(root, {'bin/a': ('old a', True), 'bin/b': ('old b', True)})
            original = linux_integration.tempfile.mkstemp
            calls = []

            def full_disk(*args, **kwargs):
                calls.append(args)
                if len(calls) == 2:
                    raise OSError(28, 'No space left on device')
                return original(*args, **kwargs)

            with patch.object(linux_integration.tempfile, 'mkstemp', full_disk), \
                    self.assertRaises(OSError):
                linux_integration.write(root, {'bin/a': ('new a', True), 'bin/b': ('new b', True)})
            self.assertEqual((root / 'bin/a').read_text(), 'old a')
            self.assertEqual((root / 'bin/b').read_text(), 'old b')
            self.assertEqual(sorted(p.name for p in (root / 'bin').iterdir()), ['a', 'b'])

    def test_a_failed_rename_puts_earlier_files_back(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            linux_integration.write(root, {'bin/a': ('old a', True)})
            original = linux_integration.os.replace
            renames = []

            def failing(source, destination):
                if str(source).endswith('.ghostcopy-new'):
                    renames.append(source)
                    if len(renames) == 2:
                        raise OSError(5, 'Input/output error')
                return original(source, destination)

            with patch.object(linux_integration.os, 'replace', failing), \
                    self.assertRaises(OSError):
                linux_integration.write(root, {'bin/a': ('new a', True), 'bin/b': ('new b', True)})
            self.assertEqual((root / 'bin/a').read_text(), 'old a')
            self.assertEqual(sorted(p.name for p in (root / 'bin').iterdir()), ['a'])

    def test_a_retired_entry_that_cannot_be_removed_stays_owned(self):
        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory)
            (prefix / 'lib/ghostcopy').mkdir(parents=True)
            stuck = prefix / 'share/old/stuck.desktop'
            stuck.parent.mkdir(parents=True)
            stuck.write_text('old')
            original = Path.unlink

            def busy(path, *args, **kwargs):
                if path.name == 'stuck.desktop':
                    raise PermissionError(13, 'Permission denied')
                return original(path, *args, **kwargs)

            with patch.object(Path, 'unlink', busy):
                owned = linux_integration.install(
                    prefix, cli=False, previous=['share/old/stuck.desktop'])
            self.assertIn('share/old/stuck.desktop', owned)
            self.assertIn('bin/ghostcopy-send', owned)

    def test_install_removes_entries_a_release_no_longer_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory)
            (prefix / 'lib/ghostcopy').mkdir(parents=True)
            retired = prefix / 'share/old/retired.desktop'
            retired.parent.mkdir(parents=True)
            retired.write_text('old')
            written = linux_integration.install(
                prefix, cli=False, previous=['share/old/retired.desktop', 'bin/ghostcopy'])
            self.assertFalse(retired.exists())
            self.assertFalse((prefix / 'share/old').exists())
            self.assertNotIn('bin/ghostcopy', written)
            self.assertIn('bin/ghostcopy-send', written)


if __name__ == '__main__':
    unittest.main()
