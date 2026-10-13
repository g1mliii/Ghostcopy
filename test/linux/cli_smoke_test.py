#!/usr/bin/env python3
"""Exercise the compiled companion's stdio contract without accessing user data."""

import json
from pathlib import Path
import subprocess
import sys


def main():
    executable = str(Path(sys.argv[1]).resolve(strict=True))
    help_result = subprocess.run([executable, '--help'], capture_output=True,
                                 text=True, check=True, timeout=15)
    assert 'ghostcopy mcp' in help_result.stdout and not help_result.stderr
    requests = [
        {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
            'protocolVersion': '2025-06-18', 'capabilities': {},
            'clientInfo': {'name': 'linux-packaging-smoke', 'version': '1'},
        }},
        {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
        {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
    ]
    wire = ''.join(json.dumps(request) + '\n' for request in requests)
    # AI clients may each have their own MCP process. Keep both alive at once.
    children = []
    try:
        for _ in range(2):
            children.append(subprocess.Popen([executable, 'mcp'], stdin=subprocess.PIPE,
                                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                             text=True))
        for child in children:
            output, errors = child.communicate(wire, timeout=15)
            assert child.returncode == 0 and not errors, errors
            replies = [json.loads(line) for line in output.splitlines()]
            assert len(replies) == 2
            by_id = {reply['id']: reply['result'] for reply in replies}
            assert by_id[1]['protocolVersion'] == '2025-06-18'
            assert sorted(tool['name'] for tool in by_id[2]['tools']) == [
                'list_devices', 'send_file', 'send_text']
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
            child.communicate()
    usage = subprocess.run([executable, 'unknown-command', '--json'],
                           capture_output=True, timeout=15)
    assert usage.returncode == 1
    print('Compiled Linux CLI/MCP passed: help, concurrent clients, JSON-RPC, discovery, EOF, exit codes.')


if __name__ == '__main__':
    main()
