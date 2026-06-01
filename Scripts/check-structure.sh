#!/usr/bin/env bash
#
# check-structure.sh, enforce the project's SwiftUI structure rules:
#   1. No Swift file longer than MAX_LINES (default 500).
#   2. No Swift file declaring more than one SwiftUI `View` struct.
#
# Scans Sources/ and the GMPlayerKit Swift sources; skips vendored FFmpeg
# headers and generated/build dirs. Exits non-zero on any violation.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAX_LINES="${MAX_LINES:-500}"
violations=0

# Files to check: app sources + the Swift parts of the package (not CFFmpeg).
mapfile -t files < <(
  find "$ROOT/Sources" \
       "$ROOT/Packages/GMPlayerKit/Sources/GMPlayerKit" \
       "$ROOT/Packages/GMPlayerKit/Sources/gmremux-cli" \
       -name '*.swift' 2>/dev/null | sort
)

for f in "${files[@]}"; do
  rel="${f#$ROOT/}"

  # Rule 1: line count.
  lines=$(wc -l < "$f" | tr -d ' ')
  if [ "$lines" -gt "$MAX_LINES" ]; then
    echo "STRUCTURE: $rel is $lines lines (max $MAX_LINES)"
    violations=$((violations + 1))
  fi

  # Rule 2: at most one `View` struct per file. Matches:
  #   struct Name: View {        and        struct Name: SomeProto, View {
  view_count=$(grep -cE '^\s*(public |private |internal |fileprivate )?struct +[A-Za-z0-9_]+ *:.*\bView\b' "$f" || true)
  if [ "$view_count" -gt 1 ]; then
    echo "STRUCTURE: $rel declares $view_count View structs (max 1 per file)"
    grep -nE '^\s*(public |private |internal |fileprivate )?struct +[A-Za-z0-9_]+ *:.*\bView\b' "$f" | sed 's/^/    /'
    violations=$((violations + 1))
  fi
done

if [ "$violations" -gt 0 ]; then
  echo "✗ check-structure: $violations violation(s)"
  exit 1
fi
echo "✓ check-structure: $(printf '%s\n' "${files[@]}" | wc -l | tr -d ' ') files OK (<= $MAX_LINES lines, <= 1 View each)"
