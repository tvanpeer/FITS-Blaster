#!/usr/bin/env python3
"""
update-site.py VERSION

Reads the first entry from CHANGELOG.md and:
  Stable version (e.g. 1.23.1):
    1. Prepends a formatted HTML block to site/changelog.html
    2. Updates the download URL and version label in site/index.html
    3. Empties the beta list on site/beta.html and greys out its download button
  Beta version (e.g. 1.23.1-beta.3):
    Adds the entry on top of the beta list on site/beta.html (all betas since the
    last stable release, newest first) and points the download button at it.

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

def parse_entries(path):
    """Yield (date, title, sections) for each ## entry in CHANGELOG.md, top first.

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

        yield date, title, sections


def parse_first_entry(path):
    """Return (date, title, sections) for the first ## entry, or None."""
    return next(parse_entries(path), None)


# ---------------------------------------------------------------------------
# HTML generation
# ---------------------------------------------------------------------------

RELEASES_URL = 'https://github.com/tvanpeer/FITS-Blaster/releases'

LABEL_CLASSES = {
    'added':    'label-added',
    'fixed':    'label-fixed',
    'improved': 'label-improved',
    'changed':  'label-changed',
    'removed':  'label-removed',
    'updated':  'label-updated',
}


def build_entry_html(version, date, title, sections, release_link=False):
    """HTML for one changelog entry. release_link adds a link to the version's GitHub
    release page (used on the beta page, where older betas stay downloadable)."""
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

    link = (f' &nbsp;&middot;&nbsp; <a class="entry-link" href="{RELEASES_URL}/tag/v{version}">'
            f'GitHub release &#8599;</a>') if release_link else ''
    return (
        f'    <!-- v{version} -->\n'
        f'    <div class="entry">\n'
        f'        <div class="entry-header">\n'
        f'            <div class="entry-title">{inline_md(title)} — v{version}</div>\n'
        f'            <div class="entry-date">{date}{link}</div>\n'
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

    # JSON-LD structured data (read by search engines)
    content = re.sub(
        r'"downloadUrl": "https://github\.com/tvanpeer/FITS-Blaster/releases/download/v[^/]+/FITS-Blaster-[^"]+\.dmg"',
        f'"downloadUrl": "https://github.com/tvanpeer/FITS-Blaster/releases/download/v{version}/FITS-Blaster-{version}.dmg"',
        content,
    )
    content = re.sub(
        r'"softwareVersion": "[^"]+"',
        f'"softwareVersion": "{version}"',
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


def beta_button_html(version=None):
    """The beta page's download button; greyed out without a link when there's no beta."""
    if version is None:
        return ('    <span class="download-btn disabled" aria-disabled="true">No beta available</span>\n'
                '    <p class="download-sub">macOS 15.6 or later</p>')
    return (f'    <a class="download-btn" href="{RELEASES_URL}/download/v{version}/FITS-Blaster-{version}.dmg">'
            f'Download Beta {version}</a>\n'
            f'    <p class="download-sub">macOS 15.6 or later &nbsp;&middot;&nbsp; Free</p>')


def replace_between(content, start, end, inner, path):
    """Replace what lies between the <!-- start --> and <!-- end --> markers."""
    pattern = rf'(<!-- {start} -->\n).*?(\n\s*<!-- {end} -->)'
    if not re.search(pattern, content, flags=re.DOTALL):
        raise RuntimeError(f'Markers {start}/{end} not found in {path}')
    return re.sub(pattern, lambda m: m.group(1) + inner + m.group(2), content,
                  count=1, flags=re.DOTALL)


def update_beta_html(path, version, entry_html):
    """Add a beta on top of the beta list and point the download button at it."""
    with open(path, encoding='utf-8') as f:
        content = f.read()

    content = replace_between(content, 'beta-button-start', 'beta-button-end',
                              beta_button_html(version), path)

    if f'<!-- v{version} -->' in content:
        print(f'{path}: v{version} already listed; button updated.')
    else:
        # The "no beta" message goes; earlier betas of this round stay below the new one.
        content = re.sub(r'\n\s*<p class="no-beta">.*?</p>', '', content, flags=re.DOTALL)
        content = content.replace('<!-- beta-entry-start -->\n',
                                  f'<!-- beta-entry-start -->\n{entry_html}\n', 1)
        print(f'{path}: added beta {version}.')

    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)


def clear_beta_html(path, stable_version):
    """After a stable release: no betas listed, download button greyed out."""
    with open(path, encoding='utf-8') as f:
        content = f.read()

    content = replace_between(content, 'beta-button-start', 'beta-button-end',
                              beta_button_html(None), path)
    content = replace_between(
        content, 'beta-entry-start', 'beta-entry-end',
        f'    <p class="no-beta">No beta at the moment. The current version is '
        f'<a href="index.html">FITS Blaster {stable_version}</a>.</p>', path)

    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)

    print(f'{path}: beta list cleared for stable {stable_version}.')


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

    if is_beta(version):
        # Beta: only update beta.html, leave index.html untouched
        entry_html = build_entry_html(version, date, title, sections, release_link=True)
        update_beta_html('site/beta.html', version, entry_html)
    else:
        # Stable: update index.html and changelog.html; the beta round is over
        entry_html = build_entry_html(version, date, title, sections)
        update_changelog_html('site/changelog.html', version, entry_html)
        update_index_html('site/index.html', version)
        clear_beta_html('site/beta.html', version)
