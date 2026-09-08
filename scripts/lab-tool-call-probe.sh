#!/usr/bin/env bash
# =============================================================================
# Prisma AIRS on Kong AI Gateway - tool call probe
#
#   export KONG_PROXY_URL="https://<your gateway proxy url>"
#   export CLIENT_KEY="<your client credential>"
#   export MODEL_NAME="my-gpt-4o"
#   ./scripts/lab-tool-call-probe.sh
#
# Sends one chat completion carrying a marker in every position a tool call can
# occupy, so scripts/lab-echo-server.py can report which ones reached the text
# the guardrail actually scans:
#
#   AIRSPROBE_SYSTEM      system message
#   AIRSPROBE_USER        user message
#   AIRSPROBE_TOOLDEF     tools[].function.description, the tool definition
#   AIRSPROBE_TOOLARGS    assistant tool_calls[].function.arguments
#   AIRSPROBE_TOOLRESULT  role: tool result message
#
# Run the echo server first, point the policy request.url at it, then run this
# once per text_source value. Reading the result: docs/lab-tool-calls.md
#
# Needs a live gateway. This answers the open question raised in the README
# under Scope and limits: whether function calling is scanned at all.
# =============================================================================
#
# No `set -e`: a rejected completion is a result to report, not a reason to
# abort before printing what came back.
set -u

PROXY="${KONG_PROXY_URL:?KONG_PROXY_URL is not set}"
KEY="${CLIENT_KEY:?CLIENT_KEY is not set}"
MODEL="${MODEL_NAME:-gpt-4o}"

BODY_FILE="$(mktemp)"
AUTH_CFG="$(mktemp)"
chmod 600 "$AUTH_CFG"
trap 'rm -f "$BODY_FILE" "$AUTH_CFG"' EXIT

# Same discipline as scripts/test-airs.sh: the credential goes through a curl
# config file, not an -H argument visible in the process list. curl's config
# parser treats a double quote as the end of the value and strips backslashes,
# so both are escaped. A newline or carriage return survives that escaping and
# would either split the "header = ..." config line in two or inject a second
# header/value, so it is rejected outright rather than escaped.
case "$KEY" in
  *$'\n'* | *$'\r'*)
    echo "CLIENT_KEY must not contain a newline or carriage return" >&2
    exit 2
    ;;
esac
esc_key="${KEY//\\/\\\\}"
esc_key="${esc_key//\"/\\\"}"
printf 'header = "Authorization: Bearer %s"\n' "$esc_key" > "$AUTH_CFG"

# The model name is interpolated into a JSON string literal below.
esc_model="${MODEL//\\/\\\\}"
esc_model="${esc_model//\"/\\\"}"

echo "───────────────────────────────────────────────────────────────"
echo "▶ Tool call probe → ${PROXY} (model ${MODEL})"
echo "  Watch the echo server output, not this one."
echo

code="$(curl -s -o "$BODY_FILE" -w '%{http_code}' \
  -X POST "${PROXY}/v1/chat/completions" \
  -K "$AUTH_CFG" \
  -H "Content-Type: application/json" \
  --data @- <<JSON
{
  "model": "${esc_model}",
  "messages": [
    {
      "role": "system",
      "content": "You are a support assistant. AIRSPROBE_SYSTEM"
    },
    {
      "role": "user",
      "content": "Look up order 4711 for me. AIRSPROBE_USER"
    },
    {
      "role": "assistant",
      "tool_calls": [
        {
          "id": "call_probe_1",
          "type": "function",
          "function": {
            "name": "lookup_order",
            "arguments": "{\"order_id\": \"4711\", \"note\": \"AIRSPROBE_TOOLARGS\"}"
          }
        }
      ]
    },
    {
      "role": "tool",
      "tool_call_id": "call_probe_1",
      "content": "{\"status\": \"shipped\", \"note\": \"AIRSPROBE_TOOLRESULT\"}"
    },
    {
      "role": "user",
      "content": "Summarise that for the customer."
    }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "lookup_order",
        "description": "Look up an order by identifier. AIRSPROBE_TOOLDEF",
        "parameters": {
          "type": "object",
          "properties": {
            "order_id": {"type": "string"},
            "note": {"type": "string"}
          },
          "required": ["order_id"]
        }
      }
    }
  ]
}
JSON
)"

echo "  gateway answered HTTP ${code}"
echo "  → $(head -c 400 "$BODY_FILE")"
echo
echo "───────────────────────────────────────────────────────────────"
echo "Now read the echo server output:"
echo
echo "  markers IN the scanned text      → that position IS scanned"
echo "  markers elsewhere, NOT scanned   → that position is NOT scanned"
echo
echo "Repeat with text_source set to last_message, concatenate_user_content"
echo "and concatenate_all_content. Record each result in the working notes,"
echo "then state the outcome in the README under Scope and limits."

if [ "$code" != "200" ]; then
  echo
  echo "Note: HTTP ${code}. If the echo server was answering 'block', that is"
  echo "expected, and the code above is the answer to Q4."
fi
