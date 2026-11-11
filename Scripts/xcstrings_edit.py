#!/usr/bin/env python3
"""Edit an .xcstrings catalog as text, without re-serialising it.

    python3 Scripts/xcstrings_edit.py strip-locale zh-Hans Resources/Localizable.xcstrings ...
    python3 Scripts/xcstrings_edit.py prune-unused     # drop what check_localization.py calls unused

Xcode's catalog layout does not survive a JSON round trip, so this cuts `"<key>" : { ... }` blocks
(string-aware brace matching) together with the comma that joined them to a neighbour. The result
is checked with json.loads before it is written.
"""
import json, re, sys


def block_end(text, start):
    depth, i, in_str = 0, start, False
    while i < len(text):
        c = text[i]
        if in_str:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError('unbalanced')


def cut_block(text, key, first_only=False):
    pattern = re.compile(r'(?m)^[ \t]*' + re.escape(json.dumps(key, ensure_ascii=False)) + r'\s*:\s*\{')
    while (m := pattern.search(text)):
        start, end = m.start(), block_end(text, m.end() - 1)
        after = re.match(r'\s*,', text[end:])
        if after:                       # "zh": {...},  next  -> drop the trailing comma
            end += after.end()
            line_start = text.rfind('\n', 0, start) + 1
            if text[line_start:start].strip() == '':
                start = line_start
            text = text[:start] + text[end:]
        else:                           # prev,  "zh": {...}  -> drop the comma before it
            before = re.search(r',\s*$', text[:start])
            text = text[:before.start()] + text[end:]
        if first_only:
            break
    return text


def strip(text, locale):
    text = cut_block(text, locale)
    text = re.sub(r'\n[ \t]*\n', '\n', text)
    text = re.sub(r'\n[ \t]*"comment"\s*:\s*"[^"\n]*[　-鿿][^"\n]*",?(?=\n)', '', text)
    return text


def main():
    command, rest = sys.argv[1], sys.argv[2:]
    if command == 'strip-locale':
        locale, paths = rest[0], rest[1:]
        for path in paths:
            text = open(path, encoding='utf-8').read()
            new = strip(text, locale)
            json.loads(new)
            open(path, 'w', encoding='utf-8').write(new)
    elif command == 'prune-unused':
        import pathlib, importlib.util
        root = pathlib.Path(__file__).resolve().parent.parent
        spec = importlib.util.spec_from_file_location('check', root / 'Scripts/check_localization.py')
        check = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(check)
        path = root / 'Resources/Localizable.xcstrings'
        text = path.read_text(encoding='utf-8')
        used, _ = check.scan()
        unused = [k for k in json.loads(text)['strings'] if k not in used]
        for key in unused:
            text = cut_block(text, key, first_only=True)
        json.loads(text)
        path.write_text(text, encoding='utf-8')
        print(f'removed {len(unused)} unused entries')
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
