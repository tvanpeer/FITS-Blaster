#!/usr/bin/env bash
# run-render-tests.sh — run the rendering tests on real data (RenderingTests).
#
# Usage:
#   scripts/run-render-tests.sh [--full] [--data <test data folder>]
#
#   --full   also the large folders (M31 night, California, Gamma Cygni, Rosette R/G/B)
#   --data   test data folder (default: /Volumes/FITS Blaster/Test Data)
#
# Each folder's typical frame (PNG) and all frames' backgrounds (CSV) are written to
# tests/render-results/<time>/ (not committed). See docs/internal/testing.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA="/Volumes/FITS Blaster/Test Data"
FULL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --full) FULL=1; shift ;;
        --data) DATA="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

[[ -d "$DATA" ]] || { echo "Test data folder not found: $DATA" >&2; exit 1; }

# TEST_RUNNER_* is how xcodebuild forwards env vars into the test process.
env TEST_RUNNER_FB_TEST_DATA="$DATA" TEST_RUNNER_FB_TEST_DATA_FULL="$FULL" \
    xcodebuild test \
    -project "$REPO_ROOT/FITS Blaster.xcodeproj" \
    -scheme "FITS Blaster" \
    -destination "platform=macOS,arch=arm64" \
    -only-testing "FITS Blaster Tests/RenderingTests" \
    2>&1 | grep -E "^\[[ *]\] |^── |recorded an issue|Test run|passed after|failed after|TEST (SUCCEEDED|FAILED)|\.swift:[0-9]+:[0-9]+: error"

echo
echo "Results: $(ls -dt "$REPO_ROOT"/tests/render-results/*/ 2>/dev/null | head -1)"
