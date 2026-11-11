#!/usr/bin/env python3
"""Remove a source file from NitiaDock.xcodeproj and delete it from disk.

    python3 Scripts/remove_source.py App/Composition/Thing.swift

Drops every pbxproj line that names the file (build file, file reference, group child). File names
are unique in this project, which the script checks before it touches anything.
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / 'NitiaDock.xcodeproj/project.pbxproj'


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    rel = pathlib.PurePosixPath(sys.argv[1])
    name = rel.name
    matches = list(ROOT.glob(f'**/{name}'))
    matches = [m for m in matches if 'build' not in m.relative_to(ROOT).parts]
    if len(matches) > 1:
        print(f'error: {name} is not unique: {matches}', file=sys.stderr)
        return 1
    pattern = re.compile(r'/\* ' + re.escape(name) + r'( in Sources)? \*/')
    lines = PBXPROJ.read_text(encoding='utf-8').split('\n')
    kept = [l for l in lines if not pattern.search(l)]
    removed = len(lines) - len(kept)
    PBXPROJ.write_text('\n'.join(kept), encoding='utf-8')
    if (ROOT / rel).exists():
        (ROOT / rel).unlink()
    print(f'{rel}: removed {removed} pbxproj lines')
    return 0


if __name__ == '__main__':
    sys.exit(main())
