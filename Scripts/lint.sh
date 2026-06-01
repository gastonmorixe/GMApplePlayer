#!/usr/bin/env bash
# lint.sh, Run SwiftLint + SwiftFormat checks over project Swift sources.
# Usage:  Scripts/lint.sh [--fix]
# SwiftLint paths come from .swiftlint.yml (included:).
# SwiftFormat requires paths before flag args (see --lint note below).
# Exit non-zero if any violations are found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$ROOT"

# Paths for SwiftFormat (swiftlint reads included: from config, no CLI paths needed)
FORMAT_PATHS=(
  "Sources"
  "Packages/GMPlayerKit/Sources/GMPlayerKit"
  "Packages/GMPlayerKit/Sources/gmremux-cli"
)

FIX=false
if [[ "${1:-}" == "--fix" ]]; then
  FIX=true
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
require_tool() {
  local tool="$1"
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: '$tool' not found. Install with: brew install $tool" >&2
    exit 1
  fi
}

require_tool swiftlint
require_tool swiftformat

echo "=== Lint targets ==="
for p in "${FORMAT_PATHS[@]}"; do
  echo "  $p"
done
echo ""

SWIFTLINT_EXIT=0
SWIFTFORMAT_EXIT=0

# ── SwiftLint ─────────────────────────────────────────────────────────────────
# No paths on CLI, driven entirely by .swiftlint.yml included:
echo "=== SwiftLint ==="
if $FIX; then
  swiftlint --fix --quiet 2>&1 || SWIFTLINT_EXIT=$?
else
  swiftlint lint --quiet 2>&1 || SWIFTLINT_EXIT=$?
fi

if [[ $SWIFTLINT_EXIT -eq 0 ]]; then
  echo "SwiftLint: ✓ no violations"
else
  echo "SwiftLint: ✗ violations found (exit $SWIFTLINT_EXIT)"
fi
echo ""

# ── SwiftFormat ───────────────────────────────────────────────────────────────
# IMPORTANT: swiftformat requires <paths> BEFORE --lint (not after)
echo "=== SwiftFormat ==="
if $FIX; then
  swiftformat "${FORMAT_PATHS[@]}" 2>&1 || SWIFTFORMAT_EXIT=$?
  echo "SwiftFormat: applied formatting"
else
  swiftformat "${FORMAT_PATHS[@]}" --lint 2>&1 || SWIFTFORMAT_EXIT=$?
  if [[ $SWIFTFORMAT_EXIT -eq 0 ]]; then
    echo "SwiftFormat: ✓ no formatting issues"
  else
    echo "SwiftFormat: ✗ formatting issues found (exit $SWIFTFORMAT_EXIT)"
  fi
fi
echo ""

# ── Structure (file size + one-view-per-file) ──────────────────────────────────
echo "=== Structure ==="
STRUCTURE_EXIT=0
"$SCRIPT_DIR/check-structure.sh" || STRUCTURE_EXIT=$?
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "=== Summary ==="
OVERALL=0
if [[ $SWIFTLINT_EXIT -ne 0 ]]; then
  echo "  SwiftLint:   FAIL"
  OVERALL=1
else
  echo "  SwiftLint:   PASS"
fi
if [[ $SWIFTFORMAT_EXIT -ne 0 ]]; then
  echo "  SwiftFormat: FAIL"
  OVERALL=1
else
  echo "  SwiftFormat: PASS"
fi
if [[ $STRUCTURE_EXIT -ne 0 ]]; then
  echo "  Structure:   FAIL"
  OVERALL=1
else
  echo "  Structure:   PASS"
fi

exit $OVERALL
