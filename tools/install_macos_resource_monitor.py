#!/usr/bin/env python3
"""Install/remove the hourly local monitor. No network or AI service is used."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

LABEL = 'com.ghostcopy.resource-monitor'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--uninstall', action='store_true')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('This monitor requires macOS')
    home = Path.home()
    agent = home / 'Library/LaunchAgents' / (LABEL + '.plist')
    support = home / 'Library/Application Support/GhostCopy/monitor'
    logs = home / 'Library/Logs/GhostCopy/performance'
    domain = f'gui/{os.getuid()}'
    subprocess.run(['/bin/launchctl', 'bootout', f'{domain}/{LABEL}'],
                   capture_output=True, check=False)
    if args.uninstall:
        agent.unlink(missing_ok=True)
        (support / 'profile_macos_resources.py').unlink(missing_ok=True)
        print('Hourly monitor removed; existing measurements retained.')
        return
    support.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)
    agent.parent.mkdir(parents=True, exist_ok=True)
    script = support / 'profile_macos_resources.py'
    shutil.copyfile(Path(__file__).with_name(script.name), script)
    configuration = {
        'Label': LABEL,
        'ProgramArguments': [str(Path(sys.executable).resolve()), str(script)],
        'StartInterval': 3600,
        'RunAtLoad': True,
        'ProcessType': 'Background',
        'Nice': 10,
        'LowPriorityIO': True,
        'EnvironmentVariables': {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'},
    }
    with agent.open('wb') as stream:
        plistlib.dump(configuration, stream)
    subprocess.run(['/bin/launchctl', 'bootstrap', domain, str(agent)], check=True)
    print(f'Installed hourly monitor: {agent}\nMeasurements: {logs}/resources.jsonl')


if __name__ == '__main__':
    main()
