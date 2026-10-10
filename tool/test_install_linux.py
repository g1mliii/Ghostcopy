import importlib.util
import json
import os
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install_linux.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class LinuxInstallerTest(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'linux', 'Executes installed Linux launchers')
    def test_dolphin_helper_preserves_each_selected_filename(self):
        with tempfile.TemporaryDirectory(prefix='ghostcopy-linux-argv-') as directory:
            root = Path(directory)
            bundle = root / 'bundle'
            (bundle / 'data/flutter_assets').mkdir(parents=True)
            executable = bundle / 'ghostcopy'
            executable.write_text(
                '#!/usr/bin/env python3\nimport json, os, sys\n'
                'with open(os.environ["GHOSTCOPY_TEST_ARGS"], "a") as output:\n'
                '    output.write(json.dumps(sys.argv[1:]) + "\\n")\n')
            executable.chmod(0o755)
            prefix = root / 'prefix with spaces'
            with patch.object(installer, 'refresh_desktop'):
                installer.install(bundle, prefix)
            output = root / 'arguments.jsonl'
            filenames = ['/tmp/one file.txt', '/tmp/$HOME;`touch nope` %f\n"two".png']
            subprocess.run([str(prefix / 'bin/ghostcopy-send'), *filenames], check=True,
                           env={**os.environ, 'GHOSTCOPY_TEST_ARGS': str(output)})
            self.assertEqual([json.loads(line) for line in output.read_text().splitlines()],
                             [['--send-file', filename] for filename in filenames])

    def test_install_and_uninstall_preserve_unowned_files(self):
        with tempfile.TemporaryDirectory(prefix='ghostcopy-linux-test-') as directory:
            root = Path(directory)
            bundle = root / 'bundle'
            assets = bundle / 'data/flutter_assets/assets/icons'
            assets.mkdir(parents=True)
            (bundle / 'ghostcopy').write_bytes(b'fake executable')
            (assets / 'app_icon.png').write_bytes(b'fake icon')
            prefix = root / 'prefix with spaces'
            with patch.object(installer, 'refresh_desktop'):
                installer.install(bundle, prefix)
            menu = prefix / 'share/kio/servicemenus/com.ghostcopy.ghostcopy.send.desktop'
            self.assertIn('%F', menu.read_text())
            helper = prefix / 'bin/ghostcopy-send'
            self.assertIn('"--send-file", filename', helper.read_text())
            desktop = prefix / 'share/applications/com.ghostcopy.ghostcopy.desktop'
            self.assertIn('MimeType=x-scheme-handler/ghostcopy;', desktop.read_text())
            keep = prefix / 'lib/ghostcopy/keep-me.txt'
            keep.write_text('unowned')
            # Refuse a path traversal in the ownership manifest before deleting.
            manifest = prefix / 'lib/ghostcopy/install-manifest.json'
            valid = manifest.read_text()
            manifest.write_text(json.dumps(['../outside']))
            with self.assertRaises(ValueError):
                installer.uninstall(prefix)
            self.assertTrue(helper.exists())
            manifest.write_text(valid)
            with patch.object(installer.sys, 'platform', 'win32'):
                installer.uninstall(prefix)
            self.assertEqual(keep.read_text(), 'unowned')
            self.assertFalse(helper.exists())
            self.assertFalse(desktop.exists())

    def test_desktop_argument_escaping(self):
        self.assertEqual(installer.desktop_exec('/home/a b/100%/app'), '"/home/a b/100%%/app"')
        self.assertEqual(installer.desktop_exec('/home/a$b/app'), '"/home/a\\\\$b/app"')


if __name__ == '__main__':
    unittest.main()
