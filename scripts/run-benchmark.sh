#!/usr/bin/env bash
# run-benchmark.sh — measure FITS Blaster throughput and save results
#
# Usage:
#   scripts/run-benchmark.sh <version> [--rgb <path>] [--mono <path>]
#
# Examples:
#   scripts/run-benchmark.sh v1.23-beta.9 \
#     --rgb "/Users/tommy/Library/Mobile Documents/com~apple~CloudDocs/Astrophotography/California Nebula IMX571/2026-02-25_Antlia ALP-T/LIGHT" \
#     --mono "/Users/tommy/Library/Mobile Documents/com~apple~CloudDocs/Astrophotography/SomeMono/LIGHT"
#
#   # Omit --mono if you have no mono dataset handy:
#   scripts/run-benchmark.sh v1.23-beta.9 \
#     --rgb "/path/to/RGB/LIGHT"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$REPO_ROOT/tests/benchmarks"
mkdir -p "$RESULTS_DIR"

# ── Argument parsing ──────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <version> [--rgb <path>] [--mono <path>]" >&2
    exit 1
fi

VERSION="$1"; shift
RGB_PATH=""
MONO_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rgb)  RGB_PATH="$2";  shift 2 ;;
        --mono) MONO_PATH="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$RGB_PATH" && -z "$MONO_PATH" ]]; then
    echo "Provide at least --rgb or --mono." >&2
    exit 1
fi

# ── Build & run ───────────────────────────────────────────────────────────────

echo "Building and running benchmark tests for $VERSION…"
echo

TMPLOG="$(mktemp)"
trap 'rm -f "$TMPLOG"' EXIT

env_args=()
[[ -n "$RGB_PATH"  ]] && env_args+=("BENCH_RGB_PATH=$RGB_PATH")
[[ -n "$MONO_PATH" ]] && env_args+=("BENCH_MONO_PATH=$MONO_PATH")

xcodebuild test \
    -scheme "FITS Blaster" \
    -configuration Debug \
    -destination "platform=macOS" \
    -only-testing "FITS Blaster Tests/BenchmarkTests" \
    "${env_args[@]/#/-testenv }" \
    2>&1 | tee "$TMPLOG"

# ── Parse BENCH: lines ────────────────────────────────────────────────────────
# Format: BENCH:<tag>:<frames>:<load_s>:<compute_s>

parse_bench() {
    local tag="$1"
    grep "^BENCH:${tag}:" "$TMPLOG" | tail -1
}

rgb_line="$(parse_bench rgb || true)"
mono_line="$(parse_bench mono || true)"

json_field() {
    # json_field <line>  →  {"frames":N,"total_mpx":X,"load_s":Y,"compute_s":Z,"total_s":W} or null
    local line="$1"
    if [[ -z "$line" ]]; then
        echo "null"
        return
    fi
    IFS=: read -r _ _ frames total_mpx load_s compute_s <<< "$line"
    total_s=$(python3 -c "print(round($load_s + $compute_s, 3))")
    echo "{\"frames\":$frames,\"total_mpx\":$total_mpx,\"load_s\":$load_s,\"compute_s\":$compute_s,\"total_s\":$total_s}"
}

DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MACHINE="$(sysctl -n hw.model 2>/dev/null || echo unknown)"

RGB_JSON="$(json_field "$rgb_line")"
MONO_JSON="$(json_field "$mono_line")"

OUTFILE="$RESULTS_DIR/${VERSION}.json"
cat > "$OUTFILE" <<EOF
{
  "version": "$VERSION",
  "date": "$DATE",
  "machine": "$MACHINE",
  "rgb": $RGB_JSON,
  "mono": $MONO_JSON
}
EOF

echo
echo "Results saved to $OUTFILE"
echo

# ── Print comparison table ────────────────────────────────────────────────────

python3 - "$RESULTS_DIR" "$VERSION" <<'PYEOF'
import json, sys, os
from pathlib import Path

results_dir = Path(sys.argv[1])
current_version = sys.argv[2]

runs = []
for f in sorted(results_dir.glob("*.json")):
    try:
        runs.append(json.loads(f.read_text()))
    except Exception:
        pass

if not runs:
    sys.exit(0)

def mps(d, key):
    """Megapixels/second — normalised throughput independent of frame resolution."""
    if not d or d.get("total_mpx", 0) == 0:
        return "      —"
    s = d.get(key, 0)
    if s <= 0:
        return "      —"
    return f"{d['total_mpx'] / s:6.0f}"

def fps(d, key):
    if not d or d.get("frames", 0) == 0:
        return "    —"
    s = d.get(key, 0)
    if s <= 0:
        return "    —"
    return f"{d['frames'] / s:4.1f}"

header = (f"{'Version':<20}  "
          f"{'RGB load MP/s':>13}  {'RGB cmp MP/s':>12}  {'RGB fps':>7}  "
          f"{'Mono load MP/s':>14}  {'Mono cmp MP/s':>13}  {'Mono fps':>8}")
sep = "-" * len(header)
print(f"\nFITS Blaster throughput\n{sep}")
print(header)
print(sep)
for r in runs:
    marker = " ◀" if r["version"] == current_version else ""
    print(f"{r['version']:<20}  "
          f"{mps(r.get('rgb'),  'load_s'):>13}  "
          f"{mps(r.get('rgb'),  'compute_s'):>12}  "
          f"{fps(r.get('rgb'),  'compute_s'):>7}  "
          f"{mps(r.get('mono'), 'load_s'):>14}  "
          f"{mps(r.get('mono'), 'compute_s'):>13}  "
          f"{fps(r.get('mono'), 'compute_s'):>8}"
          f"{marker}")
print(sep)
print("(Debug build, sequential, wall-clock — MP/s normalises for camera resolution)\n")
PYEOF
