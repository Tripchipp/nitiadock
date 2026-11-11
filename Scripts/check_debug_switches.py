#!/usr/bin/env python3
"""Check that every DOCK_* environment switch is registered in Core/Support/DebugSwitch.swift.

Usage: python3 Scripts/check_debug_switches.py

Three rules, exit code 1 if any is violated:
1. No "DOCK_…" string literal in App/ Core/ Platform/ sources (except the registry itself): switches are
   read through DebugSwitch only;
2. Every DOCK_… name in Tests/ Tools/ Scripts/ must be in the registry (so tests / scripts cannot reference
   a deleted switch);
3. Every case in the registry must be referenced as `DebugSwitch.<case>` in App/ Core/ Platform/: a switch
   nobody reads is a dead switch.
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REGISTRY = ROOT / 'Core/Support/DebugSwitch.swift'
SRC_DIRS = ['App', 'Core', 'Platform']
AUX_DIRS = ['Tests', 'Tools', 'Scripts']

LITERAL = re.compile(r'"(DOCK_[A-Z0-9_]+)"')
CASE = re.compile(r'^\s*case\s+([A-Za-z0-9_]+)\s*=\s*"(DOCK_[A-Z0-9_]+)"', re.M)
NAME = re.compile(r'\bDOCK_[A-Z0-9_]+\b')


def swift_files(dirs):
    for d in dirs:
        yield from (ROOT / d).rglob('*.swift')


def main() -> int:
    text = REGISTRY.read_text()
    registered = {raw: case for case, raw in CASE.findall(text)}
    if not registered:
        print(f'❌ no case parsed from the registry: {REGISTRY}')
        return 1
    problems = []

    # 1. No literals in source
    for f in swift_files(SRC_DIRS):
        if f == REGISTRY:
            continue
        for i, line in enumerate(f.read_text().splitlines(), 1):
            for raw in LITERAL.findall(line):
                problems.append(f'{f.relative_to(ROOT)}:{i}: uses "{raw}" directly, change to DebugSwitch.{registered.get(raw, "<register first>")}')

    # 2. Names referenced by tests / tools / scripts must be registered
    for d in AUX_DIRS:
        for f in (ROOT / d).rglob('*'):
            if not f.is_file() or f.suffix not in ('.swift', '.sh', '.py') or f.name == 'check_debug_switches.py':
                continue
            for i, line in enumerate(f.read_text(errors='ignore').splitlines(), 1):
                for raw in NAME.findall(line):
                    if raw not in registered:
                        problems.append(f'{f.relative_to(ROOT)}:{i}: {raw} is not registered (deleted switch?)')

    # 3. Registered but never read = dead switch
    src = '\n'.join(f.read_text() for f in swift_files(SRC_DIRS) if f != REGISTRY)
    for raw, case in registered.items():
        if f'DebugSwitch.{case}' not in src:
            problems.append(f'registry: {raw} (.{case}) has no call site, delete it')

    print(f'{len(registered)} switches registered')
    if problems:
        print('\n'.join('❌ ' + p for p in problems))
        return 1
    print('✅ all consistent')
    return 0


if __name__ == '__main__':
    sys.exit(main())
