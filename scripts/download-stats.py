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
    scripts/download-stats.py --extra v1.24-beta.4=1
                                         also subtract one-off test downloads (repeatable)

Test downloads are subtracted where they can be counted: every smoke test of a published
DMG (scripts/vm-smoke.sh --tag) downloads it once and leaves a results folder named
…-<vm>-<tag> in tests/smoke-results/ (git-ignored, so only on the Mac that ran the tests).
Other test downloads, such as a `gh release download` by hand, can be added with --extra.

Needs the GitHub CLI (`gh`), signed in (`gh auth login`); the repository is public,
so no special access is needed.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
from collections import Counter
from datetime import date
from pathlib import Path

REPO = "tvanpeer/FITS-Blaster"
SMOKE_RESULTS = Path(__file__).resolve().parent.parent / "tests" / "smoke-results"


def test_downloads(extra):
    """Test downloads per tag: one per smoke-test results folder of a published DMG
    (…-<vm>-<tag>), plus the --extra counts."""
    counts = Counter()
    if SMOKE_RESULTS.is_dir():
        for folder in SMOKE_RESULTS.iterdir():
            match = re.search(r"-(v\d+\.\d+(?:\.\d+)?(?:-beta\.\d+)?)$", folder.name)
            if folder.is_dir() and match:
                counts[match.group(1)] += 1
    for item in extra:
        tag, _, number = item.partition("=")
        if not number.isdigit():
            sys.exit(f"--extra takes TAG=NUMBER, not '{item}'")
        counts[tag] += int(number)
    return counts


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
    parser.add_argument("--extra", action="append", default=[], metavar="TAG=N",
                        help="also subtract N test downloads of TAG (repeatable)")
    args = parser.parse_args()

    releases = fetch_releases()
    tests = test_downloads(args.extra)
    for r in releases:
        r["tests"] = min(tests.get(r["tag"], 0), r["downloads"])
        r["others"] = r["downloads"] - r["tests"]
    if args.stable:
        releases = [r for r in releases if not r["beta"]]
    if args.since:
        releases = [r for r in releases if r["published"] and date.fromisoformat(r["published"]) >= args.since]
    if not releases:
        sys.exit("No releases match.")

    today = date.today()
    print(f"DMG downloads from GitHub Releases ({REPO}), {today.isoformat()}\n")
    print(f"{'Release':<22} {'Published':<11} {'Days':>5} {'Downloads':>10} {'Tests':>6} {'Others':>7} {'Per day':>8}")
    for r in releases:
        days = (today - date.fromisoformat(r["published"])).days if r["published"] else 0
        per_day = f"{r['others'] / days:.1f}" if days > 0 else "–"
        kind = " (beta)" if r["beta"] else ""
        print(f"{r['tag'] + kind:<22} {r['published']:<11} {days:>5} {r['downloads']:>10} {r['tests']:>6} "
              f"{r['others']:>7} {per_day:>8}")

    stable = sum(r["others"] for r in releases if not r["beta"])
    beta = sum(r["others"] for r in releases if r["beta"])
    print(f"\nOthers in total {stable + beta}: stable {stable}, beta {beta} "
          f"(test downloads subtracted: {sum(r['tests'] for r in releases)})")
    print("Others still include bots, repeats, Sparkle updates and test downloads that weren't "
          "counted; Per day uses Others. App Store downloads are in App Store Connect.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
