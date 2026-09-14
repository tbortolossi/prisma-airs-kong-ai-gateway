# Lab: is a streamed response actually scanned?

The README and the deployment guide state that a streamed response is scanned
in segments by the `OUTPUT` phase, not skipped, and that the segment size is
governed by `config.response_buffer_size`. This procedure reproduces that on a
live gateway, in one session, using only the tools shipped in this repository.

It uses two of them:

| File | Role |
|---|---|
| `scripts/lab-echo-server.py` | Stands in for the Prisma AIRS endpoint. Reports each call it receives: the phase, the scanned text, and its length. `--verdict allow` and `--verdict block` exercise the two branches this procedure needs |
| `curl -sN` against your gateway, piped through `jq` | Drives a streamed completion and sums `choices[0].delta.content` across the chunks the client actually receives, so scanned text can be compared with delivered text |

---

## Before you start

> **This is a lab procedure.** While the policy points at the echo server,
> Prisma AIRS is not scanning anything. Run it on a non-production gateway, and
> restore the configuration when you are done, step 7 below.

> **Set `request.auth.value` to a dummy value first.** The policy sends it as
> `x-pan-token` to whatever `request.url` names. The echo server redacts it from
> its output, but the right control is not to send a real token to a lab
> listener at all. Changing `request.url` alone is not enough: the vault
> reference would still resolve, and the real token would leave the gateway.

The data plane must be able to reach the echo server. Run it on a host on the
same private network as the data plane. Do not expose it through a public
tunnel: the payload contains the model's output.

Only the **`airs-scan`** policy is relevant here (`guarding_mode: BOTH`); it is
the one with an `OUTPUT` phase. Leave everything else in the shipped
configuration as is: `stop_on_error`, `guarding_mode`, the functions, and the
model under test. Change only `request.url`, `request.auth.value`, and, where a
step calls for it, `response_buffer_size`.

You need what `scripts/test-airs.sh` needs: `KONG_PROXY_URL`, `CLIENT_KEY`, and
optionally `MODEL_NAME`. Pick an upstream model whose answer to a generic
prompt runs to at least a few hundred characters, so the segmenting behaviour
is visible; a one-line answer will not exercise more than a single segment.

---

## Step 1 - Start the echo server

```bash
./scripts/lab-echo-server.py --port 8099 --verdict allow --log payloads.jsonl
```

Standard library only, nothing to install. `--log` appends each payload as a
JSON line, which lets you count and measure calls with `jq` afterwards instead
of reading the console by eye.

## Step 2 - Point `airs-scan` at it, at the schema default buffer

In `config/kongctl/airs-guardrail.yaml` (or the equivalent block in
`config/deck/airs-guardrail.yaml`), on the `airs-scan` policy only:

```yaml
      request:
        url: http://<echo-host>:8099/v1/scan/sync/request
        auth:
          location: header
          name: x-pan-token
          value: "dummy-lab-token"          # was {vault://env/airs-token}
```

Remove `response_buffer_size` from the block, or set it explicitly to `100`,
so the schema default applies. Apply the change and attach `airs-scan` to a
non-streaming-denied model for the duration of this procedure (drop
`response_streaming: deny` on that one model if the shipped configuration sets
it).

## Step 3 - Stream a request, and read both sides

Send a streamed completion and capture what the client received:

```bash
export KONG_PROXY_URL="https://<proxy>"
export CLIENT_KEY="<client credential>"
export MODEL_NAME="<your model>"

curl -sN "$KONG_PROXY_URL/v1/chat/completions" \
  -H "Authorization: Bearer $CLIENT_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"$MODEL_NAME\", \"stream\": true, \"messages\": [{\"role\": \"user\", \"content\": \"Write three sentences about the weather.\"}]}" \
  | tee stream.raw \
  | grep '^data: ' | sed 's/^data: //' | grep -v '^\[DONE\]$' \
  | jq -r '.choices[0].delta.content // empty' \
  | tr -d '\n' | wc -c
```

That last number is what the client actually received, in characters.

Then read what Prisma AIRS (the echo server) received:

```bash
jq -s '[.[] | select(.body.contents[0].response != null)] | length' payloads.jsonl
jq -s '[.[] | .body.contents[0].response | length] | add' payloads.jsonl
```

The first line counts `OUTPUT`-phase calls; the second sums the characters
scanned across all of them. Compare the two totals: delivered characters versus
scanned characters. At the schema default, the two are close but the scanned
total lags slightly, since the tail of the stream, shorter than the buffer,
never crosses the threshold before the connection closes.

## Step 4 - Repeat with a large buffer

Re-apply `airs-scan` with `response_buffer_size: 65536`, clear
`payloads.jsonl`, and repeat Step 3's request and both counts. Expect the
`OUTPUT` call count to drop to zero on a short answer: nothing in the stream
ever reaches 65536 bytes, so the guardrail is never invoked and the scanned
total is `0` while the delivered total is unchanged. This is the case to avoid
in a production configuration; see the deployment guide.

Set `response_buffer_size` back to the schema default (or remove it) before
continuing.

## Step 5 - See what a block verdict does to a stream

Stop the echo server and restart it answering block:

```bash
./scripts/lab-echo-server.py --port 8099 --verdict block --log payloads.jsonl
```

Repeat the streamed request from Step 3, saving the raw output:

```bash
curl -sN -w '\nHTTP %{http_code}\n' "$KONG_PROXY_URL/v1/chat/completions" \
  -H "Authorization: Bearer $CLIENT_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"$MODEL_NAME\", \"stream\": true, \"messages\": [{\"role\": \"user\", \"content\": \"Write three sentences about the weather.\"}]}"
```

Read the output directly: the first segment's worth of chunks arrives, the
stream then stops without a chunk carrying a `finish_reason`, and the trailing `HTTP %{http_code}`
still reads `200`. The block happened after the flagged segment was already on
the wire; the guardrail prevents what would have followed, not what already
went out. This is the behaviour to design around, not a defect to wait out.

## Step 6 - Confirm `response_streaming: deny` refuses the request outright

Set `config.response_streaming: deny` on the model under test and re-apply
(Step 4 of the deployment guide shows where this field goes). Repeat the same
streamed request:

```bash
curl -s -w '\nHTTP %{http_code}\n' "$KONG_PROXY_URL/v1/chat/completions" \
  -H "Authorization: Bearer $CLIENT_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"$MODEL_NAME\", \"stream\": true, \"messages\": [{\"role\": \"user\", \"content\": \"Write three sentences about the weather.\"}]}"
```

Expect `HTTP 400` with `{"error":{"message":"response streaming is not enabled
for this LLM"}}`, before any guardrail call. Confirm `payloads.jsonl` gained no
new entry for this request.

## Step 7 - Restore, then record

Put `request.url`, `request.auth.value`, `response_buffer_size` and
`response_streaming` back to the shipped values, and re-apply. Confirm with
`scripts/test-airs.sh` that real scanning has resumed.

Then record the counts from steps 3, 4 and 5 in your working notes, tagged with
the gateway version reported by the data plane.

---

## Result of the run of 2026-09-14

Executed as written, on a Konnect AI Gateway 2.x control plane (EU) with one
local data plane, `kong/kong-ai-gateway:2.0.3` (Kong Gateway 3.14.0.3), against
the local model used for lab traffic.

| Configuration | Stream length | `OUTPUT` calls | Scanned characters | Delivered characters |
|---|---|---|---|---|
| `response_buffer_size: 100` (schema default) | 309 chars | 3 (101 / 104 / 103 chars) | 308 | 309 |
| `response_buffer_size: 1` | same stream | 69 | close to the full stream | unchanged |
| `response_buffer_size: 65536` | 275 chars | 0 | 0 | 275 |
| non-streamed request | any length | 1, carrying the whole body | full response | full response |

At the schema default, streaming is scanned almost completely, in several
sequential calls, each without the context of the ones before it. At 65536,
the same class of stream produced zero calls; content below the buffer
threshold when the stream ends is never scanned, and a large buffer value
turns that gap into total, invisible coverage loss on a short answer.

**Block verdict on a stream.** The client received 108 characters (a 102-character
scanned segment plus one more chunk already in flight) before the stream
stopped. No further chunks were sent, no chunk carried a `finish_reason` (a
completed stream ends with `finish_reason: stop`; no `[DONE]` line was seen on
either, so its absence is not the signal), and the HTTP
status was already `200`. The flagged segment reached the client; only what
would have followed it was prevented.

**`response_streaming: deny`.** A `stream: true` request to a model carrying
this setting received `HTTP 400` with
`{"error":{"message":"response streaming is not enabled for this LLM"}}`, and
no call reached the echo server. Non-streamed requests to the same model were
unaffected.
