#!/usr/bin/env python3
"""
download-stats.py — how often the DMGs on GitHub Releases were downloaded.

Every download link on astrophoto-app.com points to a DMG on GitHub Releases, and
Sparkle downloads its updates from there too, so these counts cover the website
version: new downloads and updates together. They also include test downloads
(VMs), bots and repeated downloads. App Store downloads are in App Store Connect →
App Analytics; visits and update checks (appcast.xml requests) are in the web
server's statistics in DirectAdmin.

GitHub keeps only a running total per file, so the script shows totals. Run it now
and then and keep the output if you want to follow the numbers over time.

Usage:
    scripts/download-stats.py            per release, newest first, plus totals
    scripts/download-stats.py --stable   stable releases only
    scripts/download-stats.py --since 2026-10-01
                                         releases published on or after that date

Needs the GitHub CLI (`gh`), signed in (`gh auth login`); the repository is public,
so no special access is needed.
"""

import argparse
import json
import shutil
import subprocess
import sys
from datetime import date

REPO = "tvanpeer/FITS-Blaster"


def fetch_releases():
    """All releases with their DMG download counts, newest first."""
    if shutil.which("gh") is None:
        sys.exit("The GitHub CLI (gh) is not installed: brew install gh, then gh auth login.")
    result = subprocess.run(["gh", "api", f"repos/{REPO}/releases", "--paginate", "--slurp"],
                            capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"gh api failed: {result.stderr.strip() or 'unknown error'}\n"
                 "Is gh signed in? Run gh auth status.")
    pages = json.loads(result.stdout)
    releases = []
    for release in (r for page in pages for r in page):
        if release.get("draft"):
            continue
        dmgs = [a for a in release.get("assets", []) if a["name"].lower().endswith(".dmg")]
        releases.append({
            "tag": release["tag_name"],
            "published": (release.get("published_at") or "")[:10],
            "beta": bool(release.get("prerelease")) or "beta" in release["tag_name"],
            "downloads": sum(a["download_count"] for a in dmgs),
        })
    releases.sort(key=lambda r: r["published"], reverse=True)
    return releases


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stable", action="store_true", help="stable releases only")
    parser.add_argument("--since", type=date.fromisoformat, metavar="YYYY-MM-DD",
                        help="only releases published on or after this date")
    args = parser.parse_args()

    releases = fetch_releases()
    if args.stable:
        releases = [r for r in releases if not r["beta"]]
    if args.since:
        releases = [r for r in releases if r["published"] and date.fromisoformat(r["published"]) >= args.since]
    if not releases:
        sys.exit("No releases match.")

    today = date.today()
    print(f"DMG downloads from GitHub Releases ({REPO}), {today.isoformat()}\n")
    print(f"{'Release':<22} {'Published':<11} {'Days':>5} {'Downloads':>10} {'Per day':>8}")
    for r in releases:
        days = (today - date.fromisoformat(r["published"])).days if r["published"] else 0
        per_day = f"{r['downloads'] / days:.1f}" if days > 0 else "–"
        kind = " (beta)" if r["beta"] else ""
        print(f"{r['tag'] + kind:<22} {r['published']:<11} {days:>5} {r['downloads']:>10} {per_day:>8}")

    stable = sum(r["downloads"] for r in releases if not r["beta"])
    beta = sum(r["downloads"] for r in releases if r["beta"])
    print(f"\nTotal {stable + beta}: stable {stable}, beta {beta}")
    print("Includes test downloads, bots, repeats and Sparkle updates; App Store downloads "
          "are in App Store Connect.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
