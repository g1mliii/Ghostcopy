"""Offline regression tests for the content-free macOS resource sampler."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import mock_open, patch

import profile_macos_resources as monitor


class ResourceMonitorTest(unittest.TestCase):
    def test_closed_app_is_skipped(self):
        with patch.object(monitor, 'run', return_value='12 /usr/bin/other'):
            self.assertEqual(monitor.collect()['status'], 'not_running')

    def test_multiple_instances_are_not_combined(self):
        with patch.object(monitor, 'run', return_value=(
            '12 /Applications/GhostCopy.app/Contents/MacOS/ghostcopy\n'
            '13 /Applications/GhostCopy.app/Contents/MacOS/ghostcopy')):
            self.assertEqual(monitor.collect()['status'], 'ambiguous_process')

    def test_interval_cpu_memory_units_and_process_identity(self):
        replies = [
            '12 /Applications/GhostCopy.app/Contents/MacOS/ghostcopy',
            'Tue Sep 22 17:39:19 2026',
            'PID CPU MEM THREADS\n12 99.0 85M 12\n'
            '12 0.0 86M+ 12/1\n12 0.4 1.5G- 13\n12 0.0 900K 11',
            'Tue Sep 22 17:39:19 2026',
        ]
        with patch.object(monitor, 'run', side_effect=replies), \
                patch.object(Path, 'open', mock_open()), \
                patch.object(monitor.plistlib, 'load', return_value={'CFBundleVersion': '5'}):
            record = monitor.collect()
        self.assertEqual([s['cpu_percent'] for s in record['samples']], [0, 0.4, 0])
        self.assertEqual(record['samples'][0]['physical_memory_bytes'], 86 * 1024**2)
        self.assertEqual(record['samples'][1]['physical_memory_bytes'], 1.5 * 1024**3)
        self.assertEqual(record['visibility'], 'unknown')
        self.assertEqual(record['activity'], 'unknown')

    def test_changed_process_is_rejected(self):
        with patch.object(monitor, 'run', side_effect=[
            '12 /Applications/GhostCopy.app/Contents/MacOS/ghostcopy', 'old',
            '12 0.0 85M 12\n12 0.0 86M 12', 'new',
        ]), patch.object(Path, 'open', mock_open()), \
                patch.object(monitor.plistlib, 'load', return_value={}):
            with self.assertRaises(RuntimeError):
                monitor.collect()

    def test_isolated_test_build_is_monitored_without_launching_it(self):
        with patch.object(monitor, 'run', side_effect=[
            '12 /tmp/test build/ghostcopy.app/Contents/MacOS/ghostcopy', 'start',
            '12 9.0 85M 12\n12 0.0 86M 12', 'start',
        ]), patch.object(Path, 'open', mock_open()), \
                patch.object(monitor.plistlib, 'load', return_value={'CFBundleVersion': '5'}):
            record = monitor.collect()
        self.assertEqual(record['status'], 'sampled')
        self.assertEqual(record['app_path'], '/tmp/test build/ghostcopy.app')

    def test_unrelated_executable_named_ghostcopy_is_ignored(self):
        with patch.object(monitor, 'run', return_value='12 /tmp/ghostcopy'):
            self.assertEqual(monitor.collect()['status'], 'not_running')

    def test_log_rotates_and_keeps_one_backup(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            path = directory / 'resources.jsonl'
            path.write_text('old\n')
            with patch.object(monitor, 'MAX_LOG_BYTES', 1):
                monitor.append_record(directory, {'status': 'not_running'})
            self.assertEqual(json.loads(path.read_text())['status'], 'not_running')
            self.assertEqual((directory / 'resources.previous.jsonl').read_text(), 'old\n')


if __name__ == '__main__':
    unittest.main()
