#!/usr/bin/env python3
"""Append a short, content-free running GhostCopy resource sample locally."""
import datetime
import json
import pathlib
import plistlib
import re
import subprocess

MAX_LOG_BYTES = 2 * 1024 * 1024


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True,
                          timeout=30).stdout


def collect():
    rows = run('ps', '-axo', 'pid=,comm=').splitlines()
    processes = [(int(fields[0]), pathlib.Path(fields[1]))
                 for row in rows if len(fields := row.split(None, 1)) == 2
                 and fields[1].endswith('.app/Contents/MacOS/ghostcopy')]
    record = {'timestamp_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'activity': 'unknown', 'visibility': 'unknown'}
    if not processes:
        record['status'] = 'not_running'
    elif len(processes) != 1:
        record['status'] = 'ambiguous_process'
    else:
        pid, executable = processes[0]
        app = executable.parents[2]
        start = run('ps', '-p', str(pid), '-o', 'lstart=').strip()
        with (app / 'Contents/Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        output = run('top', '-l', '4', '-s', '2', '-pid', str(pid),
                     '-stats', 'pid,cpu,mem,threads')
        samples = []
        for line in output.splitlines():
            fields = line.split()
            if len(fields) != 4 or fields[0] != str(pid):
                continue
            size = re.fullmatch(r'([\d.]+)([BKMG])?[+-]?', fields[2])
            if not size:
                continue
            scale = {'B': 1, 'K': 1024, 'M': 1024**2, 'G': 1024**3}
            samples.append({'cpu_percent': float(fields[1]),
                            'physical_memory_bytes': round(float(size[1]) * scale[size[2] or 'B']),
                            'threads': int(fields[3].split('/')[0])})
        samples = samples[1:]  # First top reading is not an interval measurement.
        if not samples or run('ps', '-p', str(pid), '-o', 'lstart=').strip() != start:
            raise RuntimeError('Process changed or no interval measurements available')
        record.update(status='sampled', pid=pid, process_start=start,
                      build=info.get('CFBundleVersion'), app_path=str(app),
                      samples=samples)
    return record


def append_record(directory, record):
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / 'resources.jsonl'
    if path.exists() and path.stat().st_size >= MAX_LOG_BYTES:
        path.replace(directory / 'resources.previous.jsonl')
    with path.open('a') as stream:
        stream.write(json.dumps(record) + '\n')


def main():
    try:
        record = collect()
    except (OSError, subprocess.SubprocessError, ValueError, RuntimeError) as error:
        # Store only the error type, never captured command output or content.
        record = {'timestamp_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'status': 'measurement_failed', 'error_type': type(error).__name__}
    directory = pathlib.Path.home() / 'Library/Logs/GhostCopy/performance'
    append_record(directory, record)
    print(json.dumps(record))
    return 1 if record['status'] == 'measurement_failed' else 0


if __name__ == '__main__':
    raise SystemExit(main())
