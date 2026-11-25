#!/bin/bash
# Regression check: re-runs recognition on saved debug frames and diffs against the last known-good output.
#   scripts/regress.sh           check (exit 1 when anything changed)
#   scripts/regress.sh record    accept the current output as the new expected output
# Cases: ../调试文件/回归检查/cases.txt (local only: the frames are the player's own screenshots), one per line:
#   name | ENV=value … | --field a.png        (or --replay a.png b.png …, --place …, --plan …)
# Timings are stripped, so only recognition results, advice and notes are compared. Uses the release build.
set -euo pipefail
cd "$(dirname "$0")/.."
# Cases, expected results and the recordings they replay live outside the repo (~/dev/调试文件).
DIR="${REGRESS_DIR:-../调试文件/回归检查}"
CASES="$DIR/cases.txt"
MODE="${1:-check}"
[ -f "$CASES" ] || { echo "没有 $CASES（见 docs/开发.md「回归检查」）"; exit 2; }
mkdir -p "$DIR/expected" "$DIR/actual"
swift build -c release >/dev/null
BIN=".build/release/GarrisonHelper"

failed=0; total=0
while IFS='|' read -r name envs cmd; do
  name="$(echo "$name" | xargs)"; [ -z "$name" ] || [[ "$name" == \#* ]] && continue
  total=$((total + 1))
  out="$DIR/actual/$name.txt"
  # shellcheck disable=SC2086
  env $envs "$BIN" $cmd 2>&1 \
    | grep -vE '^\[ocr|^load |^pass |^tick |^sprite:|^image |^board [0-9]+ms' \
    | sed -E -e 's/^(=== [^ ]+)  [0-9.]+s$/\1/' -e 's/ in [0-9.]+s/ in …s/' > "$out" || true
  if [ "$MODE" = "record" ]; then
    cp "$out" "$DIR/expected/$name.txt"; echo "记录 $name（$(wc -l < "$out" | xargs) 行）"
  elif ! diff -q "$DIR/expected/$name.txt" "$out" >/dev/null 2>&1; then
    failed=$((failed + 1)); echo "✗ $name"; diff "$DIR/expected/$name.txt" "$out" | head -20 || true
  else
    echo "✓ $name"
  fi
done < "$CASES"
[ "$MODE" = "record" ] && exit 0
echo "$((total - failed))/$total 一致"
[ "$failed" -eq 0 ]
