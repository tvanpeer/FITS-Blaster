#!/usr/bin/env python3
"""
compare.py — compare FITS Blaster metrics against PixInsight SubframeSelector

Usage:
    python3 scripts/compare.py <dir>
        Auto-finds frames.csv and SubframeSelector.csv inside <dir>.

    python3 scripts/compare.py <frames.csv> <SubframeSelector.csv>
        Explicit paths.
"""

import csv, sys
from pathlib import Path


def spearman(xs, ys):
    n = len(xs)
    if n < 3:
        return float("nan")
    rx = {v: i + 1 for i, v in enumerate(sorted(set(xs)))}
    ry = {v: i + 1 for i, v in enumerate(sorted(set(ys)))}
    d2 = sum((rx[x] - ry[y]) ** 2 for x, y in zip(xs, ys))
    return 1 - 6 * d2 / (n * (n**2 - 1))


def read_fb(path):
    rows = {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            name = Path(row["path"]).name
            rows[name] = {
                "fwhm": float(row["fwhm"]),
                "ecc": float(row["eccentricity"]),
                "snr": float(row["snr"]),
            }
    return rows


def read_pi(path):
    rows = {}
    with open(path, newline="") as f:
        lines = f.readlines()
    header_idx = next(i for i, l in enumerate(lines) if l.startswith("Index,"))
    for row in csv.DictReader(lines[header_idx:]):
        name = Path(row["File"].strip()).name
        rows[name] = {
            "fwhm": float(row["FWHM"]),
            "ecc": float(row["Eccentricity"]),
            "snr": float(row["PSF SNR"]),
        }
    return rows


def resolve_paths(args):
    if len(args) == 1:
        d = Path(args[0])
        fb_path = d / "frames.csv"
        pi_path = d / "SubframeSelector.csv"
        if not fb_path.exists():
            sys.exit(f"frames.csv not found in {d}")
        if not pi_path.exists():
            sys.exit(f"SubframeSelector.csv not found in {d}")
        return fb_path, pi_path
    elif len(args) == 2:
        return Path(args[0]), Path(args[1])
    else:
        sys.exit(__doc__)


def corr_line(label, fb_vals, pi_vals):
    r = spearman(fb_vals, pi_vals)
    lo, hi, mean = min(fb_vals), max(fb_vals), sum(fb_vals) / len(fb_vals)
    pi_lo, pi_hi, pi_mean = min(pi_vals), max(pi_vals), sum(pi_vals) / len(pi_vals)
    return (
        f"  {label:<14} r={r:+.3f}   "
        f"FB {lo:.3f}–{hi:.3f} mean {mean:.3f}   "
        f"PI {pi_lo:.3f}–{pi_hi:.3f} mean {pi_mean:.3f}"
    )


def main():
    fb_path, pi_path = resolve_paths(sys.argv[1:])

    fb = read_fb(fb_path)
    pi = read_pi(pi_path)

    common = sorted(set(fb) & set(pi))
    only_fb = len(fb) - len(common)
    only_pi = len(pi) - len(common)

    print(f"\nDataset : {fb_path.parent.name}")
    print(f"Frames  : {len(common)} matched", end="")
    if only_fb or only_pi:
        print(f"  ({only_fb} FB-only, {only_pi} PI-only)", end="")
    print()
    print()

    fb_fwhm = [fb[k]["fwhm"] for k in common]
    fb_ecc  = [fb[k]["ecc"]  for k in common]
    fb_snr  = [fb[k]["snr"]  for k in common]
    pi_fwhm = [pi[k]["fwhm"] for k in common]
    pi_ecc  = [pi[k]["ecc"]  for k in common]
    pi_snr  = [pi[k]["snr"]  for k in common]

    print(corr_line("FWHM",         fb_fwhm, pi_fwhm))
    print(corr_line("Eccentricity", fb_ecc,  pi_ecc))
    print(corr_line("SNR",          fb_snr,  pi_snr))
    print()


if __name__ == "__main__":
    main()
