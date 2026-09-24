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


def _check_signing_key_matches(embedded_key, sparkle_bin):
    """The key updates will be signed with must be the one the app verifies.

    generate_appcast signs with a Keychain account, and every verification step
    in prepare-update.sh checks against that SAME account - so a regenerated or
    imported key there passes the whole pipeline while each installed copy
    rejects the update, because each checks the SUPublicEDKey in its own bundle.
    Nothing related the two.

    Here rather than in prepare-update.sh, where it was first written. That
    script runs last, after both notarization round trips, so a mismatch cost
    ten to twenty minutes before anything said so - and any future path that
    packages or re-signs without going through it lost the check entirely.
    build-release.sh calls this verifier in its first seconds, and every caller
    of the shared gate inherits it.

    Skipped when the tools are not on hand: this file is also used to inspect a
    bundle, and that should not need the release toolchain.
    """
    if sparkle_bin is None:
        return
    generate_keys = pathlib.Path(sparkle_bin) / 'generate_keys'
    if not generate_keys.is_file():
        return
    signing_key = subprocess.run(
        [str(generate_keys), '--account', 'com.ghostcopy.ghostcopy', '-p'],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    check(
        signing_key == embedded_key,
        'The Sparkle signing key does not match the app: signing with it would '
        f'ship an update every install rejects (app {embedded_key}, '
        f'keychain {signing_key})',
    )


def verify(app, require_updater=False, sparkle_bin=None):
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
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    bundle = info['CFBundleIdentifier']
    if require_updater:
        # Sparkle's dialogs, notifications and Finder all read this first. It
        # is easy to lose in a project regeneration, and a release that says
        # "ghostcopy" everywhere is not worth notarizing.
        check(info.get('CFBundleDisplayName') == 'GhostCopy', 'Display name is not GhostCopy')
        check(info.get('SUFeedURL') == 'https://github.com/g1mliii/Ghostcopy/releases/download/macos-updates/appcast.xml', 'Incorrect update feed URL')
        check(info.get('SUPublicEDKey') == '7u9K3OLvC/WnDejiCYfZCvqEooph4mz4nhpAIysobC0=', 'Incorrect Sparkle signing key')
        check(info.get('SUVerifyUpdateBeforeExtraction') is True, 'Update archive verification is disabled')
        check(info.get('SURequireSignedFeed') is True, 'Signed update feed is required')
        check((app / 'Contents/Frameworks/Sparkle.framework').is_dir(), 'Sparkle framework not embedded')
        _check_signing_key_matches(info['SUPublicEDKey'], sparkle_bin)
    team = entitlements.get('com.apple.developer.team-identifier')
    check(team and team == allowed.get('com.apple.developer.team-identifier'), 'Team does not match profile')
    app_id = entitlements.get('com.apple.application-identifier', '')
    check(app_id.endswith('.' + bundle), 'Application identifier does not match bundle')
    check(fnmatch.fnmatchcase(app_id, allowed.get('com.apple.application-identifier', '')), 'Profile does not authorize application identifier')
    groups = entitlements.get('keychain-access-groups', [])
    check(groups == ['R9TKT8U45R.com.ghostcopy.ghostcopy'], 'Keychain group changed; existing passphrase may become inaccessible')
    for group in groups:
        check(any(fnmatch.fnmatchcase(group, pattern) for pattern in allowed.get('keychain-access-groups', [])), 'Profile does not authorize Keychain group')
    # Restricted like the Keychain group: signed in but missing from the
    # profile, and macOS refuses to launch the app at all.
    if 'com.apple.developer.applesignin' in entitlements:
        check('com.apple.developer.applesignin' in allowed, 'Profile does not authorize Sign in with Apple; app will not launch')
    with tempfile.TemporaryDirectory() as directory:
        prefix = str(pathlib.Path(directory) / 'certificate')
        subprocess.run(['codesign', '-d', '--extract-certificates=' + prefix, str(app)], check=True, capture_output=True)
        certificate = pathlib.Path(prefix + '0').read_bytes()
        check(certificate in profile['DeveloperCertificates'], 'Signing certificate not authorized by profile')
    print(f'Validated Developer ID signature, distribution profile, and unchanged Keychain group: {app}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    parser.add_argument('--require-updater', action='store_true')
    # Where the Sparkle tools live, so the signing key can be compared with the
    # one in the bundle. Optional: without it that single check is skipped and
    # everything else still runs, which keeps this usable for plain inspection.
    parser.add_argument('--sparkle-bin', default=None)
    args = parser.parse_args()
    try:
        verify(args.app.resolve(), args.require_updater, args.sparkle_bin)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'Export validation failed: {error}')
