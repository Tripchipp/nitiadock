#!/usr/bin/env python3
"""Print one version's section of CHANGELOG.md (for GitHub release notes).

    python3 Scripts/changelog_section.py 1.0.0
"""
import pathlib, re, sys

text = (pathlib.Path(__file__).resolve().parent.parent / 'CHANGELOG.md').read_text(encoding='utf-8')
version = sys.argv[1]
match = re.search(r'^## ' + re.escape(version) + r'\b.*?\n(.*?)(?=^## |\Z)', text, re.M | re.S)
if not match:
    sys.exit(f'error: CHANGELOG.md has no "## {version}" section')
print(match.group(1).strip())
