#!/usr/bin/env python3
"""
site-stats.py — what the web server's access logs say about astrophoto-app.com.

Reads the daily log archives downloaded from DirectAdmin (Nov-2026.tar.gz,
Oct-2026.tar.gz.1, …; each holds astrophoto-app.com.log.1) or plain access logs
(.log, .log.gz), skips lines that appear in more than one file, and prints:

- Update checks: the website version of FITS Blaster asks for appcast.xml (stable)
  or appcast-beta.xml (beta) once a day, with "FITS Blaster/<version>" as user
  agent. Different IP addresses per day are the best estimate of active copies.
  An address is not a user: home connections change address, so the number of
  addresses over a whole period is higher than the number of users.
- Visitors: page views by browsers that also loaded the page's images (most bots
  fetch only the page), per day, which pages, and where they came from.
- Downloads of the sample set (served by this site; the DMGs come from GitHub,
  see download-stats.py).

The logs contain visitors' IP addresses (personal data). This script prints counts
only, never addresses. Keep the logs out of the repository.

Usage:
    scripts/site-stats.py                       logs in "/Volumes/FITS Blaster/Site logs"
    scripts/site-stats.py <folder>              logs elsewhere
    scripts/site-stats.py --since 2026-10-20    only from that date (also --until)
    scripts/site-stats.py --exclude 203.0.113.7 leave an address out (repeatable)

Addresses to leave out every time (your own connection, so your test copies and VMs
don't count) go in ~/.config/fits-blaster/site-stats-exclude.txt, one per line;
lines starting with # are ignored. That file is outside the repository on purpose.
"""

import argparse
import collections
import gzip
import re
import sys
import tarfile
from datetime import date, datetime
from pathlib import Path

DEFAULT_FOLDER = Path("/Volumes/FITS Blaster/Site logs")
EXCLUDE_FILE = Path.home() / ".config" / "fits-blaster" / "site-stats-exclude.txt"

# Apache combined log format.
LINE = re.compile(r'^(\S+) \S+ \S+ \[([^\]]+)\] "(\S+) (\S+) [^"]*" (\d{3}) \S+ "([^"]*)" "([^"]*)"')
APP = re.compile(r"^FITS Blaster/(\S+)")
BOT = re.compile(r"bot|crawl|spider|slurp|curl|wget|python|go-http|httpclient|scan|preview|"
                 r"facebookexternalhit|AppInfo|headless|monitor|feed|java|okhttp|libwww|zgrab|nmap",
                 re.IGNORECASE)
# Loaded by every page view in a browser (the pages show them); most bots skip images.
PAGE_IMAGES = {"/favicon.png", "/app-icon.png", "/screenshot-main.png", "/apple-touch-icon.png"}
# A check more often than this per day is reported as unusual (Sparkle checks once a day).
FREQUENT_CHECKS_PER_DAY = 10


class Request:
    __slots__ = ("ip", "time", "day", "method", "path", "status", "referrer", "agent")

    def __init__(self, match):
        ip, stamp, self.method, target, status, self.referrer, self.agent = match.groups()
        self.ip = ip
        self.time = datetime.strptime(stamp, "%d/%b/%Y:%H:%M:%S %z")
        self.day = self.time.date()
        self.path = target.split("?")[0]
        if self.path.startswith("http"):            # absolute-form request line
            self.path = "/" + self.path.split("/", 3)[-1] if self.path.count("/") >= 3 else "/"
        if self.path == "/":
            self.path = "/index.html"
        self.status = int(status)


def log_lines(folder):
    """Every access-log line in the folder's archives and log files, without duplicates."""
    lines = set()
    for file in sorted(folder.iterdir()):
        name = file.name
        if name.startswith(".") or not file.is_file():
            continue
        if ".tar" in name:
            try:
                with tarfile.open(file, "r:*") as archive:
                    for member in archive.getmembers():
                        # Only regular files, and only the access log (not the error log).
                        if member.isfile() and ".log" in member.name and "error" not in member.name:
                            data = archive.extractfile(member)
                            if data:
                                lines.update(data.read().decode("utf-8", "replace").splitlines())
            except (tarfile.TarError, OSError) as error:
                print(f"warning: skipped {name}: {error}", file=sys.stderr)
        elif name.endswith(".log.gz"):
            with gzip.open(file, "rt", errors="replace") as handle:
                lines.update(handle.read().splitlines())
        elif ".log" in name and "error" not in name:
            lines.update(file.read_text(errors="replace").splitlines())
    return lines


def excluded_addresses(extra):
    addresses = set(extra)
    if EXCLUDE_FILE.is_file():
        for line in EXCLUDE_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                addresses.add(line)
    return addresses


def section(title):
    print(f"\n── {title} " + "─" * max(0, 60 - len(title)))


def update_checks(requests):
    checks = [r for r in requests
              if r.path in ("/appcast.xml", "/appcast-beta.xml") and APP.match(r.agent)]
    if not checks:
        print("No update checks found.")
        return
    stable = collections.defaultdict(set)
    beta = collections.defaultdict(set)
    by_version = collections.defaultdict(lambda: collections.defaultdict(set))
    per_address = collections.Counter()
    days_of_address = collections.defaultdict(set)
    latest = {}
    for r in checks:
        version = APP.match(r.agent).group(1)
        (beta if r.path == "/appcast-beta.xml" else stable)[r.day].add(r.ip)
        by_version[r.day][version].add(r.ip)
        per_address[r.ip] += 1
        days_of_address[r.ip].add(r.day)
        latest[r.ip] = version     # requests are sorted by time: the last one wins

    top_versions = [v for v, _ in collections.Counter(
        v for day in by_version.values() for v, ips in day.items() for _ in ips).most_common(5)]
    print("Different addresses per day (an estimate of active copies of the website version).")
    header = f"{'Day':<11} {'Stable':>6} {'Beta':>5}   " + "  ".join(f"{v:>13}" for v in top_versions)
    print(header)
    for day in sorted(set(stable) | set(beta)):
        counts = "  ".join(f"{len(by_version[day][v]):>13}" for v in top_versions)
        print(f"{day.isoformat():<11} {len(stable[day]):>6} {len(beta[day]):>5}   {counts}")

    addresses = len(per_address)
    one_day = sum(1 for days in days_of_address.values() if len(days) == 1)
    print(f"\n{addresses} different addresses in the period; {one_day} of them on one day only "
          "(changing home addresses, so fewer users than addresses).")
    print("Last version seen per address: " + ", ".join(
        f"{v} {n}" for v, n in collections.Counter(latest.values()).most_common(8)))
    frequent = [ip for ip, n in per_address.items() if n / len(days_of_address[ip]) > FREQUENT_CHECKS_PER_DAY]
    if frequent:
        print(f"{len(frequent)} address(es) checked more than {FREQUENT_CHECKS_PER_DAY} times a day "
              "(one copy checking very often, or many machines behind one address); the heaviest:")
    for number, ip in enumerate(sorted(frequent, key=lambda ip: -per_address[ip])[:5], 1):
        days = len(days_of_address[ip])
        print(f"  {number}. {per_address[ip]} checks on {days} day(s), {per_address[ip] / days:.0f} a day, "
              f"version {latest[ip]}")


def visitors(requests):
    pages = collections.defaultdict(set)
    with_images = set()
    referrers = collections.Counter()
    for r in requests:
        key = (r.ip, r.day)
        if r.method == "GET" and r.status in (200, 304) and r.path.endswith(".html"):
            pages[key].add(r.path)
            if r.referrer not in ("", "-") and "astrophoto-app.com" not in r.referrer:
                host = re.sub(r"^https?://(www\.)?", "", r.referrer).split("/")[0]
                referrers[host] += 1
        if r.path in PAGE_IMAGES and r.status in (200, 304):
            with_images.add(key)
    visits = {key: paths for key, paths in pages.items() if key in with_images}
    print(f"{len(visits)} visits (address and day) by browsers that loaded the images, "
          f"from {len({ip for ip, _ in visits})} different addresses; "
          f"{len(pages) - len(visits)} more page fetches without images (mostly bots).")
    per_day = collections.Counter(day for _, day in visits)
    print("Per day: " + "  ".join(f"{day.strftime('%d/%m')} {n}" for day, n in sorted(per_day.items())))
    if visits:
        sizes = sorted(len(paths) for paths in visits.values())
        print(f"Pages per visit: median {sizes[len(sizes) // 2]}, most {sizes[-1]}")
    seen = collections.Counter(path for paths in visits.values() for path in paths)
    print("Visits that included each page: " + ", ".join(f"{p.lstrip('/')} {n}" for p, n in seen.most_common()))
    # Sites that send one hit each are mostly backlink spam; show the ones that send more.
    regular = [(h, n) for h, n in referrers.most_common() if n >= 2]
    once = sum(1 for n in referrers.values() if n == 1)
    print("Came from (2 or more page views): " + (", ".join(f"{h} {n}" for h, n in regular) or "none")
          + f"; {once} other sites once each (mostly link spam)")


def other(requests):
    samples = [r for r in requests if r.path.startswith("/samples/") and r.status in (200, 206)]
    people = [r for r in samples if not BOT.search(r.agent)]
    print(f"Sample set downloads: {len(samples)} requests ({len(people)} from browsers), "
          f"{len({r.ip for r in samples})} different addresses")
    bots = sum(1 for r in requests if BOT.search(r.agent))
    not_found = sum(1 for r in requests if r.status == 404)
    print(f"Bots (by user agent): {bots / len(requests):.0%} of all requests; "
          f"'not found' answers: {not_found} (mostly scans for pages this site doesn't have)")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("folder", nargs="?", type=Path, default=DEFAULT_FOLDER)
    parser.add_argument("--since", type=date.fromisoformat, metavar="YYYY-MM-DD")
    parser.add_argument("--until", type=date.fromisoformat, metavar="YYYY-MM-DD")
    parser.add_argument("--exclude", action="append", default=[], metavar="ADDRESS",
                        help="an IP address to leave out (repeatable)")
    args = parser.parse_args()

    if not args.folder.is_dir():
        sys.exit(f"Log folder not found: {args.folder} (is the volume mounted?)")
    lines = log_lines(args.folder)
    skip = excluded_addresses(args.exclude)
    requests = []
    for line in lines:
        match = LINE.match(line)
        if not match:
            continue
        r = Request(match)
        if r.ip in skip or (args.since and r.day < args.since) or (args.until and r.day > args.until):
            continue
        requests.append(r)
    if not requests:
        sys.exit("No log lines in that period.")
    requests.sort(key=lambda r: r.time)

    first, last = requests[0].day, requests[-1].day
    print(f"astrophoto-app.com, {first.isoformat()} – {last.isoformat()}: {len(requests)} requests"
          + (f", {len(skip)} address(es) left out" if skip else ""))
    section("Update checks (website version of the app)")
    update_checks(requests)
    section("Visitors")
    visitors(requests)
    section("Other")
    other(requests)
    return 0


if __name__ == "__main__":
    sys.exit(main())
