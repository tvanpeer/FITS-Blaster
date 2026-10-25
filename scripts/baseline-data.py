#!/usr/bin/env python3
"""
baseline-data.py — the copy of the test data that the metric baselines and the
rendering tests read, and its checksum manifests.

Usage:
    scripts/baseline-data.py create [--only <set>]...
        Clones each set's folder (or the sample zip) from "Test Data" into
        "Test Data (baselines)" with cp -c (APFS clone: almost no extra space) and
        writes its manifest, tests/baselines/<set>.sha256. A set that is already in
        the baseline folder is left alone; only a missing manifest is written.
    scripts/baseline-data.py verify [--data <dir>] [--only <set>]... [--render | --render-full]
        Checks the sets against their manifests; exit 1 when one doesn't match.
        `--data "/Volumes/FITS Blaster/Test Data"` checks the originals instead.
    scripts/baseline-data.py restore [--only <set>]...
        Puts files of the manifest that are missing in "Test Data" back, as clones
        of the baseline copy. Only adds missing files: an existing file, even a
        changed one, is never overwritten (it is reported).

To change a set on purpose: delete its folder in "Test Data (baselines)" and its
manifest, run `create --only <set>`, then refresh its baseline with
`scripts/metric-baselines.py --only <set> --update`. See docs/internal/testing.md.
"""

import argparse
import subprocess
import sys

import testdata


def create(names):
    for name in names:
        folder = testdata.DATASETS[name]
        rel = folder if folder is not None else testdata.SAMPLE_ZIP
        source = testdata.SOURCE_DATA / rel
        target = testdata.BASELINE_DATA / rel
        if target.exists():
            print(f"{name}: already in {testdata.BASELINE_DATA.name}, left alone")
        else:
            if not source.exists():
                sys.exit(f"{name}: not found: {source}")
            target.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["/bin/cp", "-c", "-R", "-p", str(source), str(target)], check=True)
            print(f"{name}: cloned {rel}")
        if testdata.manifest_path(name).exists():
            print(f"{name}: manifest exists, left alone")
        else:
            count = testdata.write_manifest(name, testdata.BASELINE_DATA)
            print(f"{name}: manifest written ({count} file(s))")


def restore(names):
    restored = 0
    for name in names:
        expected = testdata.read_manifest(name)
        if expected is None:
            print(f"{name}: no manifest, skipped")
            continue
        for rel, digest in sorted(expected.items()):
            source = testdata.BASELINE_DATA / rel
            target = testdata.SOURCE_DATA / rel
            if target.exists():
                if testdata.sha256(target) != digest:
                    print(f"{name}: {target.name} differs from the manifest, left alone")
                continue
            if not source.exists():
                print(f"{name}: {source.name} missing in the baseline copy too")
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["/bin/cp", "-c", "-p", str(source), str(target)], check=True)
            print(f"{name}: restored {rel}")
            restored += 1
    print(f"{restored} file(s) restored to {testdata.SOURCE_DATA}")


def verify(names, root):
    failed = False
    for name in names:
        problems = testdata.verify(name, root)
        if problems:
            failed = True
            print(f"CHANGED  {name}: " + "; ".join(problems))
        else:
            print(f"OK       {name}: {len(testdata.read_manifest(name))} file(s) match the manifest")
    return failed


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["create", "verify", "restore"])
    parser.add_argument("--only", action="append", choices=list(testdata.DATASETS))
    parser.add_argument("--data", type=testdata.Path, default=testdata.BASELINE_DATA)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--render", action="store_true", help="the sets of the quick rendering tests")
    group.add_argument("--render-full", action="store_true", help="the sets of the full rendering tests")
    args = parser.parse_args()

    names = (args.only or (testdata.RENDER_QUICK if args.render else
                           testdata.RENDER_FULL if args.render_full else list(testdata.DATASETS)))
    if args.command == "create":
        create(names)
        return 0
    if args.command == "restore":
        restore(names)
        return 0
    if not args.data.is_dir():
        sys.exit(f"Test data folder not found: {args.data} (run scripts/baseline-data.py create)")
    if verify(names, args.data):
        print("\nThe test data changed. Restore it, or change a set on purpose "
              "(see scripts/baseline-data.py --help).")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
