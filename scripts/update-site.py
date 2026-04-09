#!/usr/bin/env python3
"""
update-site.py VERSION

Reads the first entry from CHANGELOG.md and:
  1. Prepends a formatted HTML block to site/changelog.html
  2. Updates the download URL and version label in site/index.html

Run from the repository root:
    python3 scripts/update-site.py 1.16
"""

import re
import sys


# ---------------------------------------------------------------------------
# Markdown helpers
# ---------------------------------------------------------------------------

def inline_md(text):
    """Escape HTML special chars, then convert **bold** and `code` to HTML."""
    text = text.replace('&', '&amp;')
    text = text.replace('<', '&lt;')
    text = text.replace('>', '&gt;')
    text = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', text)
    text = re.sub(r'`([^`]+)`', r'<code>\1</code>', text)
    return text


# ---------------------------------------------------------------------------
# CHANGELOG.md parser
# ---------------------------------------------------------------------------

def parse_first_entry(path):
    """Return (date, title, sections) for the first ## entry in CHANGELOG.md.

    sections is a list of (label, [item_text, ...]) tuples.
    Multi-line bullet points are joined into a single string.
    """
    with open(path, encoding='utf-8') as f:
        text = f.read()

    blocks = re.split(r'\n---\n', text)

    for block in blocks:
        block = block.strip()
        if not block.startswith('## '):
            continue

        lines = block.splitlines()
        m = re.match(r'^## (\d{4}-\d{2}-\d{2}) — (.+)$', lines[0])
        if not m:
            continue

        date, title = m.group(1), m.group(2)
        sections = []
        label = None
        items = []
        current = None

        for line in lines[1:]:
            if line.startswith('### '):
                if current is not None:
                    items.append(current)
                    current = None
                if label and items:
                    sections.append((label, items))
                label = line[4:].strip()
                items = []
            elif line.startswith('- '):
                if current is not None:
                    items.append(current)
                current = line[2:].strip()
            elif line.startswith('  ') and current is not None:
                current += ' ' + line.strip()
            elif not line.strip() and current is not None:
                items.append(current)
                current = None

        if current is not None:
            items.append(current)
        if label and items:
            sections.append((label, items))

        return date, title, sections

    return None


# ---------------------------------------------------------------------------
# HTML generation
# ---------------------------------------------------------------------------

LABEL_CLASSES = {
    'added':    'label-added',
    'fixed':    'label-fixed',
    'improved': 'label-improved',
    'changed':  'label-changed',
    'removed':  'label-removed',
    'updated':  'label-updated',
}


def build_entry_html(version, date, title, sections):
    section_blocks = ''
    for label, items in sections:
        css = LABEL_CLASSES.get(label.lower(), f'label-{label.lower()}')
        lis = '\n'.join(f'                <li>{inline_md(item)}</li>' for item in items)
        section_blocks += (
            f'        <div class="section">\n'
            f'            <span class="section-label {css}">{label}</span>\n'
            f'            <ul>\n'
            f'{lis}\n'
            f'            </ul>\n'
            f'        </div>\n'
        )

    return (
        f'    <!-- v{version} -->\n'
        f'    <div class="entry">\n'
        f'        <div class="entry-header">\n'
        f'            <div class="entry-title">{inline_md(title)} — v{version}</div>\n'
        f'            <div class="entry-date">{date}</div>\n'
        f'        </div>\n'
        f'{section_blocks}'
        f'    </div>\n'
    )


# ---------------------------------------------------------------------------
# File updaters
# ---------------------------------------------------------------------------

def update_changelog_html(path, version, entry_html):
    with open(path, encoding='utf-8') as f:
        content = f.read()

    if f'<!-- v{version} -->' in content:
        print(f'{path}: v{version} already present, skipping.')
        return

    marker = '<div class="content">\n'
    idx = content.find(marker)
    if idx == -1:
        raise RuntimeError(f'Insertion marker not found in {path}')

    insert_at = idx + len(marker)
    content = content[:insert_at] + '\n' + entry_html + '\n' + content[insert_at:]

    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)

    print(f'{path}: updated.')


def update_index_html(path, version):
    with open(path, encoding='utf-8') as f:
        content = f.read()

    # Download href
    content = re.sub(
        r'href="https://github\.com/tvanpeer/FITS-Blaster/releases/download/v[^/]+/FITS-Blaster-[^"]+\.dmg"',
        f'href="https://github.com/tvanpeer/FITS-Blaster/releases/download/v{version}/FITS-Blaster-{version}.dmg"',
        content,
    )

    # Button label
    content = re.sub(
        r'(?<=>)Download FITS Blaster [\d.]+(?=<)',
        f'Download FITS Blaster {version}',
        content,
    )

    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)

    print(f'{path}: updated.')


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def is_beta(version: str) -> bool:
    return 'beta' in version


def update_beta_html(path, version, entry_html):
    """Update beta.html with latest beta download and changelog entry."""
    with open(path, encoding='utf-8') as f:
        content = f.read()

    # Update download href
    content = re.sub(
        r'href="https://github\.com/tvanpeer/FITS-Blaster/releases/download/v[^/]+/FITS-Blaster-[^"]+\.dmg"',
        f'href="https://github.com/tvanpeer/FITS-Blaster/releases/download/v{version}/FITS-Blaster-{version}.dmg"',
        content,
    )

    # Update button label
    content = re.sub(
        r'(?<=>)Download Beta [\d.a-z-]+(?=<)',
        f'Download Beta {version}',
        content,
    )

    # Replace the beta changelog entry
    content = re.sub(
        r'<!-- beta-entry-start -->.*?<!-- beta-entry-end -->',
        f'<!-- beta-entry-start -->\n{entry_html}\n    <!-- beta-entry-end -->',
        content,
        flags=re.DOTALL,
    )

    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)

    print(f'{path}: updated for beta {version}.')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(f'Usage: {sys.argv[0]} VERSION   (e.g. 1.16 or 1.23-beta.1)')
        sys.exit(1)

    version = sys.argv[1]

    result = parse_first_entry('CHANGELOG.md')
    if result is None:
        print('No valid entry found in CHANGELOG.md')
        sys.exit(1)

    date, title, sections = result
    entry_html = build_entry_html(version, date, title, sections)

    if is_beta(version):
        # Beta: only update beta.html, leave index.html untouched
        update_beta_html('site/beta.html', version, entry_html)
    else:
        # Stable: update index.html and changelog.html
        update_changelog_html('site/changelog.html', version, entry_html)
        update_index_html('site/index.html', version)
