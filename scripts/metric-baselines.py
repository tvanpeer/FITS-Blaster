#!/usr/bin/env python3
"""
metric-baselines.py — check FITS Blaster's metrics against stored baselines.

Runs the command-line mode on the test datasets and compares every frame's
metrics (FWHM, eccentricity, SNR, stars, PSF signal weight, score) and the
frames kept by the standard filter with the CSVs in tests/baselines/.
See docs/internal/testing.md — including what you must do when a check fails.

Usage:
    scripts/metric-baselines.py [options]

What to test (default: build the current checkout as Release and use that):
    --app <path>            an installed or downloaded FITS Blaster .app
    --smoke-results <dir>   CSVs from a VM smoke test (sample set only)

Options:
    --quick                 sample set only
    --only <name>           one dataset only (repeatable), e.g. --only asi294mm-sho
    --data <dir>            test data folder (default: /Volumes/FITS Blaster/Test Data)
    --update                write the results as the new baselines (after review!);
                            with --only, only those datasets' baselines are written

Exit status: 0 when everything is within tolerance, 1 otherwise.
"""

import argparse
import csv
import json
import platform
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BASELINES = REPO / "tests" / "baselines"
RESULTS = REPO / "tests" / "baseline-results"
DEFAULT_DATA = Path("/Volumes/FITS Blaster/Test Data")
SAMPLE_ZIP = "Sample set (website)/FITS-Blaster-Sample-M31.zip"

# Dataset name → folder relative to the test data (None = the sample set zip).
DATASETS = {
    "sample-m31": None,
    "m31-night": "M31/LIGHT",
    "california": "California Nebula IMX571/2026-02-25_Antlia ALP-T/LIGHT",
    "gamma-cygni-0304": "Gamma Cygni Nebula IMX571/2026-03-04_Antlia ALP-T/LIGHT",
    "rosette-r": "NGC 2244-Rosette_Nebula original/R",
    "rosette-g": "NGC 2244-Rosette_Nebula original/G",
    "rosette-b": "NGC 2244-Rosette_Nebula original/B",
    "asi294mm-sho": "ASI294MM SHO",
}

# The standard filter: the same one the VM smoke test uses.
FILTER_ARGS = ["-f", "1.5", "-e", "0.5", "-p", "0.5"]

METRICS = ["fwhm", "eccentricity", "snr", "stars", "psf_signal_weight", "score"]


def allowed(metric, baseline):
    """Largest allowed difference for a metric, measured 2026-10-13 (see testing.md).

    FWHM, eccentricity and SNR: one step in the last digit the CSV writes, since a
    value on a rounding edge can flip. Stars and PSF·S vary slightly between identical
    runs (stars by up to 2, PSF·S by up to 0.1%), so they get 0.5% with a floor.
    Score: whole numbers, relative to the folder.
    """
    return {
        "fwhm": 0.01,
        "eccentricity": 0.001,
        "snr": 0.1,
        "stars": max(3.0, abs(baseline) * 0.005),
        "psf_signal_weight": abs(baseline) * 0.005,
        "score": 1.0,
    }[metric] + 1e-9


# ── Running the CLI ──────────────────────────────────────────────────────────

def build_release():
    """Builds the current checkout as Release and returns the app path."""
    derived = REPO / "build" / "metric-baselines"
    print("Building the current checkout (Release)…", flush=True)
    result = subprocess.run(
        ["xcodebuild", "build", "-project", str(REPO / "FITS Blaster.xcodeproj"),
         "-scheme", "FITS Blaster", "-configuration", "Release",
         "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(derived),
         # The scheme turns on code coverage, which would instrument this build (slower,
         # and it writes default.profraw). Published builds are not instrumented.
         "ENABLE_CODE_COVERAGE=NO"],
        capture_output=True, text=True)
    if result.returncode != 0:
        errors = [line for line in result.stdout.splitlines() if ": error:" in line]
        sys.exit("Build failed:\n" + "\n".join(errors[:20] or result.stdout.splitlines()[-20:]))
    return derived / "Build" / "Products" / "Release" / "FITS Blaster.app"


def run_cli(executable, folder, out_dir, name):
    """Runs the CLI unfiltered and filtered; returns (rows, kept names)."""
    all_csv = out_dir / f"{name}.csv"
    kept_csv = out_dir / f"{name}-kept.csv"
    for args, path in (([], all_csv), (FILTER_ARGS, kept_csv)):
        result = subprocess.run([str(executable), str(folder), *args, "-o", str(path)],
                                capture_output=True, text=True)
        if result.returncode != 0:
            sys.exit(f"CLI failed on {name} (exit {result.returncode}):\n{result.stderr}")
        if args and "no frames passed" in result.stderr:
            path.write_text("path\n")  # the CLI exports everything when nothing passes
    return read_results(all_csv, kept_csv)


def read_results(all_csv, kept_csv):
    with open(all_csv, newline="") as f:
        rows = {row["path"]: {m: row.get(m, "") for m in METRICS} for row in csv.DictReader(f)}
    with open(kept_csv, newline="") as f:
        kept = {row["path"] for row in csv.DictReader(f)}
    return rows, kept


def unzip_sample(data):
    target = Path(tempfile.mkdtemp(prefix="metric-baselines-"))
    subprocess.run(["/usr/bin/ditto", "-x", "-k", str(data / SAMPLE_ZIP), str(target)], check=True)
    return next(p.parent for p in sorted(target.rglob("*.fits")))


# ── Baselines ────────────────────────────────────────────────────────────────

def load_baseline(name):
    path = BASELINES / f"{name}.csv"
    if not path.exists():
        return None
    with open(path, newline="") as f:
        reader = list(csv.DictReader(f))
    rows = {row["path"]: {m: row[m] for m in METRICS} for row in reader}
    kept = {row["path"] for row in reader if row["kept"] == "yes"}
    return rows, kept


def write_baseline(name, rows, kept):
    BASELINES.mkdir(parents=True, exist_ok=True)
    with open(BASELINES / f"{name}.csv", "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["path", *METRICS, "kept"])
        for frame in sorted(rows):
            writer.writerow([frame, *(rows[frame][m] for m in METRICS), "yes" if frame in kept else ""])


def compare(name, baseline, rows, kept):
    """Returns a list of problems (strings); empty means within tolerance."""
    base_rows, base_kept = baseline
    problems = []
    missing = sorted(set(base_rows) - set(rows))
    extra = sorted(set(rows) - set(base_rows))
    if missing:
        problems.append(f"frames missing: {', '.join(missing)}")
    if extra:
        problems.append(f"frames not in the baseline: {', '.join(extra)}")

    for frame in sorted(set(base_rows) & set(rows)):
        for metric in METRICS:
            old, new = base_rows[frame][metric], rows[frame][metric]
            if old == "" or new == "":
                if old != new:
                    problems.append(f"{frame}: {metric} was '{old}', now '{new}'")
                continue
            old_v, new_v = float(old), float(new)
            if abs(new_v - old_v) > allowed(metric, old_v):
                problems.append(f"{frame}: {metric} {old} → {new} "
                                f"(diff {new_v - old_v:+.4g}, allowed ±{allowed(metric, old_v):.3g})")

    if kept != base_kept:
        for frame in sorted(base_kept - kept):
            problems.append(f"filter: {frame} was kept, now filtered out ({describe(rows, frame)})")
        for frame in sorted(kept - base_kept):
            problems.append(f"filter: {frame} was filtered out, now kept ({describe(rows, frame)})")
    return problems


def describe(rows, frame):
    """The filtered metrics of a frame next to the folder medians, to judge how close it was."""
    def median(metric):
        values = sorted(float(r[metric]) for r in rows.values() if r[metric] != "")
        return values[len(values) // 2] if values else float("nan")
    r = rows.get(frame, {})
    return (f"FWHM {r.get('fwhm')} vs limit 1.5 × median {median('fwhm'):.2f}, "
            f"ecc {r.get('eccentricity')} vs 0.5, "
            f"PSF·S {r.get('psf_signal_weight')} vs 0.5 × median {median('psf_signal_weight'):.1f}")


def summarise_changes(name, baseline, rows, kept):
    """For --update: how the new results differ from the old baseline."""
    if baseline is None:
        return f"  {name}: new baseline, {len(rows)} frames, {len(kept)} kept by the filter"
    base_rows, base_kept = baseline
    lines = [f"  {name}: {len(rows)} frames, {len(kept)} kept (was {len(base_rows)}, {len(base_kept)})"]
    for metric in METRICS:
        diffs = [float(rows[f][metric]) - float(base_rows[f][metric])
                 for f in set(rows) & set(base_rows)
                 if rows[f][metric] != "" and base_rows[f][metric] != ""]
        changed = [d for d in diffs if d != 0]
        if changed:
            lines.append(f"    {metric:18} changed on {len(changed)} frames, "
                         f"largest {max(changed, key=abs):+.4g}, average {sum(changed) / len(changed):+.4g}")
    return "\n".join(lines)


def app_version(app):
    plist = app / "Contents" / "Info.plist"
    def read(key):
        result = subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Print {key}", str(plist)],
                                capture_output=True, text=True)
        return result.stdout.strip()
    return f"{read('CFBundleShortVersionString')} ({read('CFBundleVersion')})"


def git_commit():
    result = subprocess.run(["git", "-C", str(REPO), "rev-parse", "--short", "HEAD"],
                            capture_output=True, text=True)
    dirty = subprocess.run(["git", "-C", str(REPO), "status", "--porcelain", "--untracked-files=no"],
                           capture_output=True, text=True).stdout.strip()
    return result.stdout.strip() + (" (with uncommitted changes)" if dirty else "")


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--smoke-results", type=Path)
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--only", action="append", choices=list(DATASETS), metavar="NAME")
    parser.add_argument("--data", type=Path, default=DEFAULT_DATA)
    parser.add_argument("--update", action="store_true")
    args = parser.parse_args()

    if args.update and args.smoke_results:
        sys.exit("--update needs a full run on this Mac, not smoke-test results.")

    results = {}
    source = ""
    if args.smoke_results:
        out = args.smoke_results / "out"
        results["sample-m31"] = read_results(out / "all.csv", out / "filtered.csv")
        source = f"smoke-test results in {args.smoke_results}"
    else:
        if not args.data.is_dir():
            sys.exit(f"Test data folder not found: {args.data} (use --data)")
        app = args.app or build_release()
        executable = app / "Contents" / "MacOS" / "FITS Blaster"
        if not executable.exists():
            sys.exit(f"No FITS Blaster executable in {app}")
        source = f"{app.name} {app_version(app)}"
        out_dir = RESULTS / datetime.now().strftime("%Y%m%d-%H%M%S")
        out_dir.mkdir(parents=True)
        names = args.only or (["sample-m31"] if args.quick else list(DATASETS))
        for name in names:
            folder = unzip_sample(args.data) if DATASETS[name] is None else args.data / DATASETS[name]
            print(f"Running {name}…", flush=True)
            results[name] = run_cli(executable, folder, out_dir, name)
        print(f"CLI output: {out_dir}")

    print(f"\nTesting {source}\n")

    if args.update:
        print("Changes against the current baselines:")
        for name, (rows, kept) in results.items():
            print(summarise_changes(name, load_baseline(name), rows, kept))
            write_baseline(name, rows, kept)
        meta_path = BASELINES / "baselines.json"
        meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
        meta.update({name: {"updated": datetime.now().isoformat(timespec="seconds"),
                            "app": source, "commit": git_commit(),
                            "macOS": platform.mac_ver()[0]} for name in results})
        meta_path.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")
        print(f"\nBaselines written to {BASELINES}. Review `git diff tests/baselines` and commit "
              "them with the reason for the change.")
        return 0

    failed = False
    for name, (rows, kept) in results.items():
        baseline = load_baseline(name)
        if baseline is None:
            print(f"FAIL  {name}: no baseline (create one with --update)")
            failed = True
            continue
        problems = compare(name, baseline, rows, kept)
        if problems:
            failed = True
            print(f"FAIL  {name}: {len(problems)} difference(s)")
            for problem in problems:
                print(f"      {problem}")
        else:
            print(f"PASS  {name}: {len(rows)} frames within tolerance, filter keeps the same {len(kept)}")
    print("\nSome checks FAILED — see docs/internal/testing.md before changing anything."
          if failed else "\nAll metrics match the baselines.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
