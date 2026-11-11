#!/usr/bin/env python3
"""Add (or replace) one release in appcast.xml, newest first.

    python3 Scripts/appcast_add.py --version 1.0.0 --build 100 \
        --url https://github.com/Tripchipp/nitiadock/releases/download/v1.0.0/NitiaDock-1.0.0.zip \
        --signature-attrs 'sparkle:edSignature="..." length="12345"' \
        --minimum-system 12.0 --notes https://github.com/Tripchipp/nitiadock/blob/main/CHANGELOG.md

`--signature-attrs` is the exact output of Sparkle's `sign_update` for the ZIP. An item with the
same build number is replaced, so re-running a release does not leave duplicates.
"""
import argparse, datetime, pathlib, re, sys
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent
APPCAST = ROOT / 'appcast.xml'

EMPTY = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>NitiaDock</title>
    <link>https://github.com/Tripchipp/nitiadock</link>
    <description>Updates for NitiaDock</description>
    <language>en</language>
  </channel>
</rss>
'''


def main():
    parser = argparse.ArgumentParser()
    for name in ('version', 'build', 'url', 'signature-attrs', 'minimum-system', 'notes'):
        parser.add_argument(f'--{name}', required=True)
    args = parser.parse_args()

    attrs = args.signature_attrs.strip()
    if not re.fullmatch(r'sparkle:edSignature="[A-Za-z0-9+/=]+" length="\d+"', attrs):
        print(f'error: unexpected sign_update output: {attrs!r}', file=sys.stderr)
        return 1

    text = APPCAST.read_text(encoding='utf-8') if APPCAST.exists() else EMPTY
    # Drop an earlier item for the same build.
    text = re.sub(r'\n    <item>(?:(?!</item>).)*?<sparkle:version>' + re.escape(args.build)
                  + r'</sparkle:version>.*?</item>', '', text, flags=re.S)

    date = datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')
    item = f'''
    <item>
      <title>NitiaDock {escape(args.version)}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{escape(args.build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(args.minimum_system)}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{escape(args.notes)}</sparkle:fullReleaseNotesLink>
      <enclosure url="{escape(args.url)}" type="application/octet-stream" {attrs}/>
    </item>'''
    anchor = '    <language>en</language>'
    if anchor not in text:
        print('error: appcast.xml has no <language> line to insert after', file=sys.stderr)
        return 1
    text = text.replace(anchor, anchor + item, 1)
    APPCAST.write_text(text, encoding='utf-8')
    print(f'appcast.xml: {args.version} ({args.build})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
