#!/usr/bin/env bash
# =============================================================================
# Run the verdict function tests against the Lua actually shipped in the YAML.
#
#   ./scripts/run-lua-tests.sh
#
# Extracts the airs_verdict function from both policies in
# config/kongctl/airs-guardrail.yaml, checks that config/deck/airs-guardrail.yaml
# carries the same Lua, and runs scripts/test-verdict-functions.lua against it.
#
# Needs luajit, or lua, or Docker. Kong runs LuaJIT, so luajit is preferred.
# No network access and no gateway required.
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

KONGCTL_YAML="config/kongctl/airs-guardrail.yaml"
DECK_YAML="config/deck/airs-guardrail.yaml"
TESTS="scripts/test-verdict-functions.lua"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Extract the Nth "airs_verdict: |" block from a YAML file and dedent it.
# Block-scalar extraction only: everything more indented than the key belongs
# to the block, and the first line that is not blank and not more indented ends
# it. That is the whole of the YAML block-scalar rule this needs.
extract_verdict() {
  local file="$1" occurrence="$2"
  awk -v want="$occurrence" '
    /airs_verdict: \|/ {
      seen++
      if (seen == want) {
        match($0, /^[ ]*/)
        key_indent = RLENGTH
        collecting = 1
        body_indent = -1
        next
      }
    }
    collecting {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      match($0, /^[ ]*/)
      if (RLENGTH <= key_indent) { collecting = 0; next }
      if (body_indent < 0) body_indent = RLENGTH
      print substr($0, body_indent + 1)
    }
  ' "$file" |
    # Drop trailing blank lines. YAML block scalars clip them, so keeping them
    # would report a difference between two identical functions.
    awk 'BEGIN { blanks = 0 }
         /^[[:space:]]*$/ { blanks++; next }
         { while (blanks-- > 0) print ""; blanks = 0; print }'
}

for direction in 1 2; do
  extract_verdict "$KONGCTL_YAML" "$direction" > "$WORK/kongctl.$direction.lua"
  extract_verdict "$DECK_YAML"    "$direction" > "$WORK/deck.$direction.lua"

  if [ ! -s "$WORK/kongctl.$direction.lua" ]; then
    echo "FAIL: could not extract airs_verdict #$direction from $KONGCTL_YAML" >&2
    exit 1
  fi

  # Rule from CLAUDE.md: guardrail logic changes land in both files together.
  if ! diff -q "$WORK/kongctl.$direction.lua" "$WORK/deck.$direction.lua" >/dev/null; then
    echo "FAIL: airs_verdict #$direction differs between kongctl and deck configs" >&2
    diff -u "$WORK/deck.$direction.lua" "$WORK/kongctl.$direction.lua" >&2
    exit 1
  fi
done

echo "ok - kongctl and deck configs carry identical verdict functions"

{
  echo "prompt_verdict = (function()"
  cat "$WORK/kongctl.1.lua"
  echo "end)()"
  echo "response_verdict = (function()"
  cat "$WORK/kongctl.2.lua"
  echo "end)()"
  cat "$TESTS"
} > "$WORK/suite.lua"

if command -v luajit >/dev/null 2>&1; then
  exec luajit "$WORK/suite.lua"
elif command -v lua >/dev/null 2>&1; then
  exec lua "$WORK/suite.lua"
elif command -v docker >/dev/null 2>&1; then
  exec docker run --rm -v "$WORK:/w:ro" akorn/luajit:2.1-alpine luajit /w/suite.lua
else
  echo "FAIL: need luajit, lua or docker to run the suite" >&2
  exit 1
fi
