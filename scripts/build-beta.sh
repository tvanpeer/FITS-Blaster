#!/usr/bin/env bash
# build-beta.sh — local Release build with the BETA compilation condition, like the
# release workflow makes for beta tags. Beta builds contain the CLI --render option that
# the VM smoke test uses; stable and App Store builds don't.
#
# Usage:
#   scripts/build-beta.sh
#
# Signed with your development certificate (not notarised), so smoke-test it with
# --dev-build:
#   scripts/vm-smoke.sh <vm> "$(scripts/build-beta.sh)" --dev-build
#
# The app path is the only thing written to stdout. See docs/internal/testing.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED="$REPO_ROOT/build/beta"
LOG="$DERIVED/xcodebuild.log"
mkdir -p "$DERIVED"

echo "==> Building Release with BETA (log: $LOG)" >&2
# ENABLE_CODE_COVERAGE=NO: the scheme turns coverage on, which would instrument this
# build; published builds are not instrumented.
if ! xcodebuild build \
        -project "$REPO_ROOT/FITS Blaster.xcodeproj" \
        -scheme "FITS Blaster" \
        -configuration Release \
        -destination "platform=macOS,arch=arm64" \
        -derivedDataPath "$DERIVED" \
        ENABLE_CODE_COVERAGE=NO \
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BETA' \
        > "$LOG" 2>&1; then
    grep -E ": error:" "$LOG" | head -20 >&2 || tail -20 "$LOG" >&2
    echo "Build failed." >&2
    exit 1
fi

APP="$DERIVED/Build/Products/Release/FITS Blaster.app"
echo "==> Built $APP" >&2
echo "$APP"
