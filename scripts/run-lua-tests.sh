#!/usr/bin/env bash
# =============================================================================
# Run the guardrail function tests against the Lua actually shipped in the YAML.
#
#   ./scripts/run-lua-tests.sh
#
# Extracts every airs_verdict and airs_contents block from
# config/kongctl/airs-guardrail.yaml, checks that config/deck/airs-guardrail.yaml
# carries the same Lua copy for copy, checks that the copies inside a file do
# not drift from each other, then runs scripts/test-verdict-functions.lua with
# these globals injected:
#
#   scan_verdict    airs_verdict  from airs-scan        (copy 1)
#   prompt_verdict  airs_verdict  from airs-prompt-scan (copy 2)
#   airs_contents   airs_contents from airs-scan        (copy 1)
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

# Count the "<key>: |" block scalars in a YAML file.
count_blocks() {
  local file="$1" key="$2"
  grep -cE "^[ ]*${key}: \|[ ]*$" "$file"
}

# Extract the Nth "<key>: |" block from a YAML file and dedent it.
# Block-scalar extraction only: everything more indented than the key belongs
# to the block, and the first line that is not blank and not more indented ends
# it. That is the whole of the YAML block-scalar rule this needs.
extract_block() {
  local file="$1" key="$2" occurrence="$3"
  awk -v want="$occurrence" -v key="$key" '
    $0 ~ ("^[ ]*" key ": \\|[ ]*$") {
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

for key in airs_verdict airs_contents; do
  kongctl_count="$(count_blocks "$KONGCTL_YAML" "$key")"
  deck_count="$(count_blocks "$DECK_YAML" "$key")"

  if [ "$kongctl_count" -lt 2 ]; then
    echo "FAIL: expected at least two $key blocks in $KONGCTL_YAML, found $kongctl_count" >&2
    exit 1
  fi
  if [ "$kongctl_count" -ne "$deck_count" ]; then
    echo "FAIL: $key appears $kongctl_count times in kongctl and $deck_count times in deck" >&2
    exit 1
  fi

  for ((i = 1; i <= kongctl_count; i++)); do
    extract_block "$KONGCTL_YAML" "$key" "$i" > "$WORK/kongctl.$key.$i.lua"
    extract_block "$DECK_YAML"    "$key" "$i" > "$WORK/deck.$key.$i.lua"

    if [ ! -s "$WORK/kongctl.$key.$i.lua" ]; then
      echo "FAIL: could not extract $key #$i from $KONGCTL_YAML" >&2
      exit 1
    fi

    # Rule from CLAUDE.md: guardrail logic changes land in both files together.
    if ! diff -q "$WORK/kongctl.$key.$i.lua" "$WORK/deck.$key.$i.lua" >/dev/null; then
      echo "FAIL: $key #$i differs between kongctl and deck configs" >&2
      diff -u "$WORK/deck.$key.$i.lua" "$WORK/kongctl.$key.$i.lua" >&2
      exit 1
    fi

    # The two policies differ by guarding_mode alone; their Lua is one copy.
    if ! diff -q "$WORK/kongctl.$key.1.lua" "$WORK/kongctl.$key.$i.lua" >/dev/null; then
      echo "FAIL: $key #$i differs from $key #1 inside $KONGCTL_YAML" >&2
      diff -u "$WORK/kongctl.$key.1.lua" "$WORK/kongctl.$key.$i.lua" >&2
      exit 1
    fi
  done

  echo "ok - kongctl and deck configs carry identical $key functions ($kongctl_count copies)"
done

{
  echo "scan_verdict = (function()"
  cat "$WORK/kongctl.airs_verdict.1.lua"
  echo "end)()"
  echo "prompt_verdict = (function()"
  cat "$WORK/kongctl.airs_verdict.2.lua"
  echo "end)()"
  echo "airs_contents = (function()"
  cat "$WORK/kongctl.airs_contents.1.lua"
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
