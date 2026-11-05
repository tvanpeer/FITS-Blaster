#!/usr/bin/env bash
# lint.sh — run SwiftLint over the app, the tests, the Quick Look targets and the Swift
# scripts with the repository's .swiftlint.yml. Findings recorded in .swiftlint-baseline.json
# (those that existed when SwiftLint was introduced, 2026-11-05) are not reported.
# Exit code 0 when nothing new is found.
#
# Usage:
#   scripts/lint.sh                    # report new findings
#   scripts/lint.sh --write-baseline   # record the current findings as the baseline
#
# Install SwiftLint with: brew install swiftlint. See docs/internal/testing.md.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE="$REPO/.swiftlint-baseline.json"
cd "$REPO"

command -v swiftlint >/dev/null || { echo "swiftlint not found (brew install swiftlint)" >&2; exit 1; }

if [[ "${1:-}" == "--write-baseline" ]]; then
    swiftlint lint --quiet --write-baseline "$BASELINE" >/dev/null || true
    echo "Baseline written to $BASELINE"
    exit 0
fi

# --strict: warnings fail too, so "clean" means no findings at all.
swiftlint lint --quiet --strict --baseline "$BASELINE"
