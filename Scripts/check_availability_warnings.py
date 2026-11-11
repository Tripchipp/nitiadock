#!/usr/bin/env python3
"""Fail if the build log contains "conformance is only available in a newer macOS" style warnings.

Usage: python3 Scripts/check_availability_warnings.py <build log> [more logs...]

Why this gate exists (added 2026-09-08 after three broken releases in a row):
The new SDK marks the `Hashable` and `Codable` conformances of `CGRect` / `CGPoint` / `CGSize` / `CGVector` as
macOS 15+, while this project's minimum deployment target is macOS 12. `Set<CGRect>` and the like **only warn
at compile time** (an error only in Swift 6 language mode): the build succeeds and unit tests stay green on
new systems, but on macOS 14 and earlier the witness table is missing at runtime and the app segfaults at
launch. That is how 0.11.0 / 0.11.1 / 0.11.2 all failed to open on older systems.

The log must come from a **full** compile (clean build or fresh checkout): files not recompiled by an
incremental build do not print the warning again.
"""
import pathlib
import re
import sys

# Compiler wording: conformance of 'CGRect' to 'Hashable' is only available in macOS 15.0 or newer
PATTERN = re.compile(r'is only available in macOS')
# Only our own source paths count: the same warnings in the SDK / dependencies should not block a release.
OURS = re.compile(r'/(App|Core|Platform|Tests|UI)/[^ ]*\.swift')


def main() -> int:
    logs = [pathlib.Path(a) for a in sys.argv[1:]]
    if not logs:
        print(__doc__)
        return 2

    hits = []
    for log in logs:
        if not log.exists():
            print(f'❌ build log not found: {log}')
            return 1
        for line in log.read_text(errors='replace').splitlines():
            if PATTERN.search(line) and OURS.search(line):
                hits.append(line.strip())

    if hits:
        print('❌ The build log has "conformance / API is only available in a newer macOS" warnings.')
        print('   They do not block the build but crash at runtime on the minimum supported system, fix them:')
        for line in dict.fromkeys(hits):
            print(f'   {line}')
        return 1

    print(f'✅ no cross-version conformance warnings found (scanned {len(logs)} build logs)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
