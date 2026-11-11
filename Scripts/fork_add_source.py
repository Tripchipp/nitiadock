#!/usr/bin/env python3
"""fork: register a new Swift file in NitiaDock.xcodeproj.

The project lists every source file explicitly, and the test target compiles the app sources it
exercises instead of linking the app, so a new file has to be added by hand in up to three
places. This script does it with deterministic ids (derived from the path), which keeps the
pbxproj diff small and the same on every machine.

    python3 Scripts/fork_add_source.py App/Composition/ForkDefaults.swift --app --tests
    python3 Scripts/fork_add_source.py Tests/Unit/ForkThingTests.swift --tests

--app    compile into the app target
--tests  compile into the unit-test target (needed for any app source a test touches)

The file lands in the Xcode group that already holds its directory siblings. Idempotent.
"""
import hashlib, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / 'NitiaDock.xcodeproj/project.pbxproj'
APP_SOURCES = 'A0000000000000000000003A'
TEST_SOURCES = 'A0000000000000000000005C'


def make_id(path, salt):
    return 'F0' + hashlib.md5(f'{salt}:{path}'.encode()).hexdigest()[:22].upper()


def main():
    args = sys.argv[1:]
    flags = {a for a in args if a.startswith('--')}
    paths = [a for a in args if not a.startswith('--')]
    if len(paths) != 1 or not flags or flags - {'--app', '--tests'}:
        print(__doc__)
        return 2
    rel = pathlib.PurePosixPath(paths[0])
    if not (ROOT / rel).is_file():
        print(f'error: {rel} does not exist', file=sys.stderr)
        return 1
    name = rel.name
    text = PBXPROJ.read_text(encoding='utf-8')
    ref_id = make_id(rel, 'ref')
    # A file that is already in the project (often with a hand-made id) keeps its reference, and a
    # target that already compiles it is left alone; only the missing memberships are added.
    existing = re.search(r'^\t\t([0-9A-F]{24}) /\* ' + re.escape(name) + r' \*/ = \{isa = PBXFileReference', text, re.M)
    if existing:
        ref_id = existing.group(1)

    def phase_has(phase):
        block = re.search(re.escape(phase) + r' /\* Sources \*/ = \{.*?\n\t\t\};', text, re.S)
        return bool(block) and f'/* {name} in Sources */' in block.group(0)

    if ref_id not in text:
        # Find the group through a sibling that is already registered.
        siblings = sorted(p.name for p in (ROOT / rel.parent).glob('*.swift') if p.name != name)
        group_line = None
        for sibling in siblings:
            match = re.search(r'^\t\t\t\t([0-9A-F]{24}) /\* ' + re.escape(sibling) + r' \*/,$', text, re.M)
            if match:
                group_line = match
                break
        if group_line is None:
            print(f'error: no registered sibling found next to {rel}', file=sys.stderr)
            return 1
        text = text[:group_line.start()] + f'\t\t\t\t{ref_id} /* {name} */,\n' + text[group_line.start():]
        # pbxproj is an old-style plist: anything beyond [A-Za-z0-9._/] (a `+`, say) must be quoted.
        quoted = name if re.fullmatch(r'[A-Za-z0-9._/]+', name) else f'"{name}"'
        ref = (f'\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
               f'path = {quoted}; sourceTree = "<group>"; }};\n')
        marker = '/* End PBXFileReference section */'
        text = text.replace(marker, ref + marker, 1)

    for flag, phase in (('--app', APP_SOURCES), ('--tests', TEST_SOURCES)):
        if flag not in flags:
            continue
        build_id = make_id(rel, flag)
        if build_id in text or phase_has(phase):
            continue
        build = (f'\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; '
                 f'fileRef = {ref_id} /* {name} */; }};\n')
        marker = '/* End PBXBuildFile section */'
        text = text.replace(marker, build + marker, 1)
        phase_match = re.search(re.escape(phase) + r' /\* Sources \*/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;\n'
                                r'\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n', text)
        if phase_match is None:
            print(f'error: sources phase {phase} not found', file=sys.stderr)
            return 1
        indent = re.match(r'\t+', text[phase_match.end():]).group(0)
        text = (text[:phase_match.end()] + f'{indent}{build_id} /* {name} in Sources */,\n'
                + text[phase_match.end():])

    PBXPROJ.write_text(text, encoding='utf-8')
    print(f'registered {rel} ({", ".join(sorted(flags))})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
