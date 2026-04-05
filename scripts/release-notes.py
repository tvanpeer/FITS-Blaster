#!/usr/bin/env python3
"""
release-notes.py [N]

Outputs the N most recent version sections from CHANGELOG.md to stdout,
formatted as Markdown, with a link to the full changelog at the end.

Default N = 3.

Run from the repository root:
    python3 scripts/release-notes.py 3
"""
import re
import sys

n = int(sys.argv[1]) if len(sys.argv) > 1 else 3

with open('CHANGELOG.md', encoding='utf-8') as f:
    text = f.read()

blocks = re.split(r'\n---\n', text)
entries = [b.strip() for b in blocks if b.strip().startswith('## ')]

selected = entries[:n]

print('\n\n---\n\n'.join(selected))
print()
print()
print('---')
print()
print('**[Full changelog](https://astrophoto-app.com/changelog.html)**')
