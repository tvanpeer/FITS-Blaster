"""
testdata.py — the test data sets used by metric-baselines.py and run-render-tests.sh,
and their checksum manifests. Imported by those scripts and by baseline-data.py.

The tests read a separate copy of the sets, "Test Data (baselines)": APFS clones
(cp -c) of the folders in "Test Data", so they take almost no extra space, and
rejecting or moving frames in "Test Data" doesn't change what the tests see.
Each set has a manifest, tests/baselines/<set>.sha256, listing the files the tests
read with their SHA-256; the scripts check it before they compare anything.
See docs/internal/testing.md.
"""

import hashlib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MANIFESTS = REPO / "tests" / "baselines"
SOURCE_DATA = Path("/Volumes/FITS Blaster/Test Data")
BASELINE_DATA = Path("/Volumes/FITS Blaster/Test Data (baselines)")
SAMPLE_ZIP = "Sample set (website)/FITS-Blaster-Sample-M31.zip"

# Set name → folder relative to the data root (None = the sample set zip).
DATASETS = {
    "sample-m31": None,
    "m31-night": "M31/LIGHT",
    "california": "California Nebula IMX571/2026-02-25_Antlia ALP-T/LIGHT",
    "gamma-cygni-0304": "Gamma Cygni Nebula IMX571/2026-03-04_Antlia ALP-T/LIGHT",
    "rosette-r": "NGC 2244-Rosette_Nebula original/R",
    "rosette-g": "NGC 2244-Rosette_Nebula original/G",
    "rosette-b": "NGC 2244-Rosette_Nebula original/B",
    "asi294mm-sho": "ASI294MM SHO",
    # OSC, one night, two exposure times: star count and SNR fall at 180 s where they
    # should rise (FWHM-comparison.md set 3); the baselines record today's values.
    "m42-10": "M42 RGB IMX571/2025-03-04_None/LIGHT/10",
    "m42-180": "M42 RGB IMX571/2025-03-04_None/LIGHT/180",
}

# The sets RenderingTests reads: the sample set, plus the rest with --full.
RENDER_QUICK = ["sample-m31"]
RENDER_FULL = ["sample-m31", "m31-night", "california", "gamma-cygni-0304",
               "rosette-r", "rosette-g", "rosette-b"]

FITS_EXTENSIONS = {".fits", ".fit", ".fts"}


def tested_files(name, root):
    """Paths (relative to root) of the files the tests read for a set: the sample zip,
    or the visible FITS files directly in the set's folder (no subfolders, no REJECTED)."""
    folder = DATASETS[name]
    if folder is None:
        return [SAMPLE_ZIP]
    base = root / folder
    if not base.is_dir():
        return []
    return sorted(f"{folder}/{p.name}" for p in base.iterdir()
                  if p.is_file() and not p.name.startswith(".")
                  and p.suffix.lower() in FITS_EXTENSIONS)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def manifest_path(name):
    return MANIFESTS / f"{name}.sha256"


def write_manifest(name, root):
    """Writes the manifest of a set from the files under root; returns the file count."""
    files = tested_files(name, root)
    lines = [f"{sha256(root / rel)}  {rel}\n" for rel in files]
    manifest_path(name).write_text("".join(lines))
    return len(files)


def read_manifest(name):
    path = manifest_path(name)
    if not path.exists():
        return None
    entries = {}
    for line in path.read_text().splitlines():
        digest, rel = line.split("  ", 1)
        entries[rel] = digest
    return entries


def verify(name, root):
    """Problems with a set under root, as readable lines; empty when it matches its manifest."""
    expected = read_manifest(name)
    if expected is None:
        return [f"no manifest {manifest_path(name).relative_to(REPO)} (run scripts/baseline-data.py create)"]
    if DATASETS[name] is not None and not (root / DATASETS[name]).is_dir():
        return [f"folder not found: {root / DATASETS[name]}"]
    present = set(tested_files(name, root))
    problems = []
    missing = sorted(set(expected) - present)
    extra = sorted(present - set(expected))
    changed = sorted(rel for rel in set(expected) & present if sha256(root / rel) != expected[rel])
    for label, files in (("missing", missing), ("not in the manifest", extra), ("changed", changed)):
        if files:
            names = ", ".join(Path(rel).name for rel in files[:6]) + (" …" if len(files) > 6 else "")
            problems.append(f"{len(files)} file(s) {label}: {names}")
    return problems
