#!/usr/bin/env python3
"""Add user-facing strings to Resources/Localizable.xcstrings (English only).

    python3 Scripts/fork_add_string.py "Show Drawer"

The key is the English text, as everywhere else in the catalog. Entries are appended at the end of
the catalog, edited as text (the file does not survive a JSON round trip). Existing keys are left
alone.

    python3 Scripts/fork_add_string.py "Old Label" --remove   # only strings this script added
"""
import json, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / 'Resources/Localizable.xcstrings'
TAIL = '\n  },\n  "version"'


def entry(key):
    def unit(value):
        return ('{\n          "stringUnit": {\n            "state": "translated",\n'
                f'            "value": {json.dumps(value, ensure_ascii=False)}\n          }}\n        }}')
    return (f'    {json.dumps(key, ensure_ascii=False)}: {{\n'
            '      "comment": "fork: NitiaDock",\n'
            '      "extractionState": "manual",\n'
            '      "localizations": {\n'
            f'        "en": {unit(key)}\n'
            '      }\n'
            '    }')


def main():
    args = sys.argv[1:]
    remove = '--remove' in args
    if remove:
        args.remove('--remove')
    if len(args) != 1:
        print(__doc__)
        return 2
    key = args[0]
    text = CATALOG.read_text(encoding='utf-8')
    if remove:
        # Only entries this script wrote (they carry the fork comment) can be removed.
        strings = json.loads(text)['strings']
        if strings.get(key, {}).get('comment') != 'fork: NitiaDock':
            print(f'not a fork string: {key!r}', file=sys.stderr)
            return 1
        block = ',\n' + entry(key)
        if text.count(block) != 1:
            print(f'could not locate the entry for {key!r}', file=sys.stderr)
            return 1
        text = text.replace(block, '')
        json.loads(text)
        CATALOG.write_text(text, encoding='utf-8')
        print(f'removed: {key!r}')
        return 0
    if key in json.loads(text)['strings']:
        print(f'already present: {key!r}')
        return 0
    if text.count(TAIL) != 1:
        print('error: could not find the end of the "strings" block', file=sys.stderr)
        return 1
    text = text.replace(TAIL, ',\n' + entry(key) + TAIL)
    json.loads(text)   # refuse to write a broken catalog
    CATALOG.write_text(text, encoding='utf-8')
    print(f'added: {key!r}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
