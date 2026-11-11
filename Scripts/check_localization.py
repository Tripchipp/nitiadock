#!/usr/bin/env python3
"""Check that the localized keys in the sources and Resources/Localizable.xcstrings match.

Usage: python3 Scripts/check_localization.py [--remaining]

A key missing from the catalog still shows (the key is the English text), but an unused catalog
entry is dead weight, and a Chinese literal in UI code is a leftover from upstream.
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / 'Resources/Localizable.xcstrings'
DIRS = ['App', 'Core', 'Platform', 'UI']

STR = r'"((?:[^"\\]|\\.)*)"'
# Full-text match (allows a newline after the initializer), line number looked up from match.start()
RE_LOCALIZED = re.compile(r'String\(\s*localized:\s*(?!""")' + STR)
RE_SWIFTUI = re.compile(r'\b(?:Text|Button|Toggle|Label|Picker|TextField)\(\s*' + STR)
# User-visible Chinese literals (to count the remaining work)
RE_CHINESE = re.compile(STR)

SKIP_FILES = {'App/Scenes/ContentView.swift'}   # Debug-only console


def unescape(s):
    return s.replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')


def strip_comments(text):
    """Blank out comment lines entirely, keeping the line count (so line numbers stay correct)."""
    out = []
    in_block = False
    for line in text.splitlines():
        s = line.strip()
        if in_block:
            out.append('')
            if '*/' in line:
                in_block = False
            continue
        if s.startswith('/*'):
            out.append('')
            if '*/' not in line:
                in_block = True
            continue
        if s.startswith('//'):
            out.append('')
            continue
        out.append(line)
    return '\n'.join(out)


def lineno_of(text, pos):
    return text.count('\n', 0, pos) + 1


def eval_multiline(block_lines, closing_indent):
    out = []
    for line in block_lines:
        line = line[closing_indent:] if len(line) >= closing_indent else line.lstrip()
        out.append(line)
    text = '\n'.join(out)
    # Line continuation: \ + newline -> joined directly
    text = re.sub(r'\\\n', '', text)
    return text


def extract_multiline(path):
    lines = pathlib.Path(path).read_text(encoding='utf-8').splitlines()
    keys = []
    i = 0
    while i < len(lines):
        if re.search(r'String\(localized:\s*"""\s*$', lines[i]):
            body = []
            j = i + 1
            while j < len(lines) and lines[j].strip() != '"""' and not lines[j].strip().startswith('""")'):
                body.append(lines[j])
                j += 1
            closing = len(lines[j]) - len(lines[j].lstrip()) if j < len(lines) else 0
            keys.append(eval_multiline(body, closing))
            i = j
        i += 1
    return keys


def scan():
    used, chinese = {}, []
    for d in DIRS:
        for f in sorted((ROOT / d).rglob('*.swift')):
            rel = str(f.relative_to(ROOT))
            if rel in SKIP_FILES:
                continue
            text = strip_comments(f.read_text(encoding='utf-8'))
            for rx in (RE_LOCALIZED, RE_SWIFTUI):
                for m in rx.finditer(text):
                    key = unescape(m.group(1))
                    if rx is RE_SWIFTUI and re.fullmatch(r'[a-z0-9]+(?:\.[a-z0-9]+)+', key):
                        continue   # SF Symbol name, e.g. folder.badge.plus
                    used.setdefault(key, []).append(f'{rel}:{lineno_of(text, m.start())}')
            for key in extract_multiline(f):
                used.setdefault(key, []).append(rel)
            for m in RE_CHINESE.finditer(text):
                if re.search(r'[一-龥]', m.group(1)):
                    chinese.append((f'{rel}:{lineno_of(text, m.start())}', m.group(1)))
    return used, chinese


def main():
    catalog = json.loads(CATALOG.read_text(encoding='utf-8'))['strings']
    used, chinese = scan()

    missing = {k: v for k, v in used.items() if k not in catalog}
    unused = [k for k in catalog if k not in used]
    chinese_key = [k for k in used if re.search(r'[一-龥]', k)]

    print(f'{len(used)} keys used in code | {len(catalog)} catalog entries | {len(chinese)} Chinese literals left in code\n')

    ok = True
    if missing:
        ok = False
        print(f'❌ {len(missing)} keys missing from the catalog:')
        for k, locs in sorted(missing.items()):
            print(f'   {k[:70]!r}  ← {locs[0]}')
    if chinese_key:
        ok = False
        print(f'\n❌ {len(chinese_key)} keys are Chinese (the source language is English):')
        for k in chinese_key:
            print(f'   {k[:70]!r}  ← {used[k][0]}')
    if unused:
        ok = False
        print(f'\n❌ {len(unused)} catalog entries are not referenced (dead entry or a scanner blind spot):')
        for k in unused:
            print(f'   {k[:70]!r}')

    if '--remaining' in sys.argv and chinese:
        print(f'\n--- {len(chinese)} Chinese literals ---')
        for loc, s in chinese:
            print(f'   {loc}  {s[:60]}')

    print()
    print('✅ all keys match' if ok else '⛔ problems above')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
