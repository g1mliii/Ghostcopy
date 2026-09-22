#!/usr/bin/env python3
"""Reject an appcast whose update dialog would be blank or point nowhere."""
import argparse
import pathlib
import sys
import xml.etree.ElementTree as ET

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('appcast', type=pathlib.Path)
    parser.add_argument(
        '--warn',
        action='store_true',
        help='Report missing notes without failing, for the prepare step.',
    )
    parser.add_argument(
        '--extract',
        action='store_true',
        help='Print the validated notes, for publishing them unchanged.',
    )
    args = parser.parse_args()
    item = ET.parse(args.appcast).find('./channel/item')
    if item is None:
        sys.exit('The appcast has no update item.')
    # A link is worse than nothing: publish-update.sh uploads the DMG and the
    # appcast, never a separate notes file, so the dialog would fail to load.
    if item.find(SPARKLE + 'releaseNotesLink') is not None:
        sys.exit('Release notes became a link; nothing in this pipeline uploads that URL.')
    description = (item.findtext('description') or '').strip()
    if description and args.extract:
        # The same text the appcast was signed with, so the GitHub release body
        # cannot say something different from the update dialog.
        print(description)
        return
    if not description:
        message = (
            'No release notes are embedded in the appcast, so the update '
            'dialog will be blank.'
        )
        if args.warn:
            print(f'WARNING: {message}')
            return
        sys.exit(f'{message} Rerun prepare-update.sh with the notes file.')


if __name__ == '__main__':
    main()
