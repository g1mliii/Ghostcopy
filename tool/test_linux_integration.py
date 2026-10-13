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
            original = Path.write_text
            calls = []

            def full_disk(path, *args, **kwargs):
                calls.append(path)
                if len(calls) == 2:
                    raise OSError(28, 'No space left on device')
                return original(path, *args, **kwargs)

            with patch.object(Path, 'write_text', full_disk), self.assertRaises(OSError):
                linux_integration.write(root, {'bin/a': ('new a', True), 'bin/b': ('new b', True)})
            self.assertEqual((root / 'bin/a').read_text(), 'old a')
            self.assertEqual((root / 'bin/b').read_text(), 'old b')
            self.assertEqual(sorted(p.name for p in (root / 'bin').iterdir()), ['a', 'b'])

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
