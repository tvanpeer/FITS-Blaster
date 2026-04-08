#!/usr/bin/env python3
"""
generate-appcast.py

Generates or updates site/appcast.xml with a new Sparkle release entry.
Called from the GitHub Actions release workflow after the DMG is notarised
and signed with the Sparkle EdDSA key.

Usage:
    python3 scripts/generate-appcast.py \
        --version 1.22 \
        --dmg-url "https://github.com/tvanpeer/FITS-Blaster/releases/download/v1.22/FITS-Blaster-1.22.dmg" \
        --signature "BASE64_EDDSA_SIGNATURE" \
        --dmg-size 52428800 \
        --release-notes-file release-notes.md
"""
import argparse
import html
import os
import re
from datetime import datetime, timezone
from email.utils import format_datetime


def markdown_to_html(md: str) -> str:
    """Minimal Markdown-to-HTML for release notes (headers, bullets, bold)."""
    lines = []
    in_list = False
    for line in md.split('\n'):
        stripped = line.strip()
        if not stripped:
            if in_list:
                lines.append('</ul>')
                in_list = False
            continue
        # Headers
        m = re.match(r'^(#{1,3})\s+(.*)', stripped)
        if m:
            if in_list:
                lines.append('</ul>')
                in_list = False
            level = len(m.group(1))
            lines.append(f'<h{level}>{html.escape(m.group(2))}</h{level}>')
            continue
        # Bullet points
        m = re.match(r'^[-*]\s+(.*)', stripped)
        if m:
            if not in_list:
                lines.append('<ul>')
                in_list = True
            content = html.escape(m.group(1))
            # Bold
            content = re.sub(r'\*\*(.*?)\*\*', r'<b>\1</b>', content)
            lines.append(f'  <li>{content}</li>')
            continue
        # Plain text
        lines.append(f'<p>{html.escape(stripped)}</p>')
    if in_list:
        lines.append('</ul>')
    return '\n'.join(lines)


def build_item(version: str, build: str, dmg_url: str, signature: str,
               dmg_size: int, release_html: str) -> str:
    """Build a single Sparkle <item> XML element."""
    pub_date = format_datetime(datetime.now(timezone.utc))
    return f"""        <item>
            <title>FITS Blaster {version}</title>
            <pubDate>{pub_date}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <description><![CDATA[
{release_html}
            ]]></description>
            <enclosure
                url="{dmg_url}"
                length="{dmg_size}"
                type="application/octet-stream"
                sparkle:edSignature="{signature}" />
        </item>"""


APPCAST_TEMPLATE = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>FITS Blaster Updates</title>
        <link>https://astrophoto-app.com</link>
        <description>Release notes for FITS Blaster</description>
        <language>en-us</language>
{items}
    </channel>
</rss>
"""


def main():
    parser = argparse.ArgumentParser(description='Generate or update Sparkle appcast.xml')
    parser.add_argument('--version', required=True, help='Marketing version, e.g. 1.22')
    parser.add_argument('--build', required=True, help='Build number (CURRENT_PROJECT_VERSION), e.g. 166')
    parser.add_argument('--dmg-url', required=True)
    parser.add_argument('--signature', required=True)
    parser.add_argument('--dmg-size', required=True, type=int)
    parser.add_argument('--release-notes-file', required=True)
    args = parser.parse_args()

    with open(args.release_notes_file, encoding='utf-8') as f:
        release_md = f.read()
    release_html = markdown_to_html(release_md)

    new_item = build_item(args.version, args.build, args.dmg_url, args.signature,
                          args.dmg_size, release_html)

    appcast_path = os.path.join(os.path.dirname(__file__), '..', 'site', 'appcast.xml')
    appcast_path = os.path.normpath(appcast_path)

    if os.path.exists(appcast_path):
        with open(appcast_path, encoding='utf-8') as f:
            existing = f.read()
        # Insert new item after the <language> line
        marker = '</language>'
        idx = existing.find(marker)
        if idx >= 0:
            insert_pos = idx + len(marker)
            updated = existing[:insert_pos] + '\n' + new_item + existing[insert_pos:]
        else:
            # Fallback: insert before </channel>
            updated = existing.replace('    </channel>',
                                       new_item + '\n    </channel>')
    else:
        updated = APPCAST_TEMPLATE.format(items=new_item)

    os.makedirs(os.path.dirname(appcast_path), exist_ok=True)
    with open(appcast_path, 'w', encoding='utf-8') as f:
        f.write(updated)

    print(f'Updated {appcast_path} with v{args.version}')


if __name__ == '__main__':
    main()
