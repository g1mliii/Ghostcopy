#!/usr/bin/env python3
"""Reject malformed Developer ID exports before notarization or packaging."""
import argparse
import datetime
import fnmatch
import pathlib
import plistlib
import subprocess
import sys
import tempfile


def check(condition, message):
    if not condition:
        raise ValueError(message)


def verify(app):
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    signature = subprocess.run(
        ['codesign', '-dvv', str(app)], capture_output=True, text=True, check=True,
    ).stderr
    check('Authority=Developer ID Application:' in signature, 'Not a Developer ID Application export')
    check('runtime' in signature, 'Hardened Runtime is missing')
    entitlements = plistlib.loads(subprocess.run(
        ['codesign', '-d', '--entitlements', ':-', str(app)],
        capture_output=True, check=True,
    ).stdout)
    check('$(' not in str(entitlements), 'Unexpanded Xcode variable in signed entitlements')
    check(not entitlements.get('com.apple.security.get-task-allow'), 'Debug entitlement in release')
    profile_path = app / 'Contents/embedded.provisionprofile'
    check(profile_path.is_file(), 'Missing profile authorizing Keychain access; app may fail to launch')
    profile = plistlib.loads(subprocess.run(
        ['security', 'cms', '-D', '-i', str(profile_path)], capture_output=True, check=True,
    ).stdout)
    check(profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Expired provisioning profile')
    check(profile.get('ProvisionsAllDevices') is True, 'Not a Developer ID distribution profile')
    allowed = profile['Entitlements']
    bundle = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
    team = entitlements.get('com.apple.developer.team-identifier')
    check(team and team == allowed.get('com.apple.developer.team-identifier'), 'Team does not match profile')
    app_id = entitlements.get('com.apple.application-identifier', '')
    check(app_id.endswith('.' + bundle), 'Application identifier does not match bundle')
    check(fnmatch.fnmatchcase(app_id, allowed.get('com.apple.application-identifier', '')), 'Profile does not authorize application identifier')
    groups = entitlements.get('keychain-access-groups', [])
    check(groups == ['R9TKT8U45R.com.ghostcopy.ghostcopy'], 'Keychain group changed; existing passphrase may become inaccessible')
    for group in groups:
        check(any(fnmatch.fnmatchcase(group, pattern) for pattern in allowed.get('keychain-access-groups', [])), 'Profile does not authorize Keychain group')
    with tempfile.TemporaryDirectory() as directory:
        prefix = str(pathlib.Path(directory) / 'certificate')
        subprocess.run(['codesign', '-d', '--extract-certificates=' + prefix, str(app)], check=True, capture_output=True)
        certificate = pathlib.Path(prefix + '0').read_bytes()
        check(certificate in profile['DeveloperCertificates'], 'Signing certificate not authorized by profile')
    print(f'Validated Developer ID signature, distribution profile, and unchanged Keychain group: {app}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    args = parser.parse_args()
    try:
        verify(args.app.resolve())
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'Export validation failed: {error}')
