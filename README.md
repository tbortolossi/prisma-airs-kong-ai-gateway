# Prisma AIRS on Kong AI Gateway

**Kong AI Gateway 2.x removes the custom Lua plugin path — and with it, the way
Prisma AIRS was integrated with Kong until now.** This repository restores the
enforcement without Lua, using configuration only.

Enforce **Prisma AIRS AI Runtime (API Intercept)** as an inline guardrail on
**Kong AI Gateway**, with a Konnect SaaS control plane and self-managed data
planes, including Azure Container Apps and Kubernetes. No custom plugin, no data
plane image rebuild.

*Community assets, published by an individual contributor. Not an official Palo
Alto Networks or Kong product, and covered by no support commitment from either
vendor — see [Disclaimer](#disclaimer). Provided under the MIT licence.*

> [!IMPORTANT]
> **Correction, 2026-09-14: streaming is scanned, in segments — not skipped.**
> An earlier version of this callout said `stream: true` silently bypassed
> response scanning. That was wrong. The `OUTPUT` phase does run on a stream:
> it scans the content in segments of about `response_buffer_size` bytes, each
> segment its own call to Prisma AIRS. The 2026-09-08 measurement that reported
> zero calls was reading the effect of this repository's own
> `response_buffer_size: 65536`: no stream in that run ever accumulated 65536
> bytes before ending, so the threshold was never crossed — not because Kong
> skipped the phase.
>
> That still leaves a real gap. A block on a flagged segment arrives after that
> segment has already reached the client — the stream is cut with no terminal
> chunk, on top of an HTTP 200 already sent — so streaming coverage prevents
> what follows a detection, not the detection itself, and content still below
> the threshold when the stream ends is never scanned. A non-streamed response
> is always scanned in one call carrying the whole body.
>
> The shipped configuration now pairs `airs-scan` with `response_streaming: deny`
> on the AI Model (kongctl) or the `ai-proxy-advanced` policy (deck), so a model
> under full coverage cannot stream at all, and keeps `airs-prompt-scan`,
> prompt only, for models that must stream. Details in
> [Streaming responses are scanned in segments](#streaming-responses-are-scanned-in-segments)
> and [Design decisions](#design-decisions).

---

## Why this exists

Kong AI Gateway 2.x replaced the plugin-centric model with AI entities and
[AI Policies](https://developer.konghq.com/ai-gateway/policies/). Two
consequences follow, and together they are the reason this repository exists.

**Custom Lua plugins have no place on an AI Gateway 2.x control plane.** The
Prisma AIRS plugin published by Palo Alto Networks
([prisma-airs-integrations, `custom-plugin-v3`](https://github.com/PaloAltoNetworks/prisma-airs-integrations/tree/main/Kong/custom-plugin-v3))
remains fully valid where a custom plugin can still be loaded — self-hosted Kong
Gateway, and Konnect hybrid with a
[custom data plane image](https://developer.konghq.com/custom-plugins/konnect-hybrid-mode/).
It cannot be deployed on an AI Gateway 2.x control plane, where configuration is
expressed as AI entities and policies rather than as plugins shipped inside the
data plane image. Teams moving to v2 lose the integration they had.

This is a control-plane restriction, not a runtime one. The AI Gateway 2.x data
plane is itself a Kong Gateway 3.14.0.3 runtime carrying an AI Gateway version
label — its telemetry reports `node_version=3.14.0.3` alongside
`kong_aigw_version=2.0.3`, and `kong version` inside the container prints "Kong
AI Gateway 2.0.3". What actually refuses the custom Lua plugin path on 2.x is
the Konnect API: applying an `ai_gateway_policies` entry of
`type: prisma-airs-intercept` is rejected outright, HTTP 400, "policy type
'prisma-airs-intercept' is not supported" (measured 2026-09-14). The catalogue
is closed at the control plane, independently of what the data plane
underneath could otherwise run.

**The v2 policy catalogue has no Prisma AIRS type.** It ships vendor-specific
guardrail policies for `ai-aws-guardrails`, `ai-azure-content-safety`,
`ai-gcp-model-armor` and `ai-lakera-guard`, joined by NVIDIA NeMo Guardrails
since AI Gateway 2.0.1 (see the
[changelog](https://developer.konghq.com/ai-gateway/changelog/)) — the 2.0.3
data plane image used in this repository's lab work ships
`ai-nvidia-nemo-guardrail` in its plugin directory, ahead of that policy
appearing on the catalogue page. Prisma AIRS is not among them, on either
page. There is nothing to select in the catalogue.

What v2 does provide is `ai-custom-guardrail`, Kong's supported extension point
for calling an external guardrail service over HTTP. This repository uses it to
carry the same Prisma AIRS enforcement — prompt scan, response scan, fail closed
— as declarative configuration, applied through `kongctl` on an AI Gateway 2.x
control plane or through `deck` on a classic Gateway control plane.

## What it does

```
   Client app
       │  POST /v1/chat/completions
       ▼
┌────────────────────────────────────────────────────┐
│  Kong AI Gateway data plane                        │
│                                                     │
│  AI Policy: airs-scan (guarding_mode: BOTH)        │
│      INPUT phase  (prompt)   ──────────────────────┼──► Prisma AIRS  /v1/scan/sync/request
│      allow ▼ block → rejected                      │        (action: allow | block)
│  AI Model → upstream LLM provider                  │
│      OUTPUT phase (response) ──────────────────────┼──► Prisma AIRS  /v1/scan/sync/request
│      allow ▼ block → rejected                      │
│                                                     │
│  Streaming models attach airs-prompt-scan          │
│  (guarding_mode: INPUT) instead: prompt only        │
└─────────────────────────────────────────────────────┘
       │
       ▼  200, or a rejection with "Blocked by Prisma AIRS"
   Client app
```

One policy, two phases: `airs-scan` runs `guarding_mode: BOTH`, scanning the
prompt in its `INPUT` phase and the model output in its `OUTPUT` phase.
Attach one of the two per AI Model: streaming models take `airs-prompt-scan`
(`guarding_mode: INPUT`), which covers the prompt only, instead of `airs-scan`. See [Design decisions](#design-decisions).

Enforcement happens in the data plane, in your own infrastructure. Only the text
to be scanned leaves your environment, and it goes directly to your Prisma AIRS
tenant.

Detections available depend on your Prisma AIRS security profile: prompt
injection, sensitive data (DLP), malicious URLs, toxic content, malicious code,
source code, topic violations, and — on responses — database security and
ungrounded content.

## Scope and limits

What this configuration scans is the prompt text and the response text on the LLM
path. Two adjacent surfaces are not covered, and are stated here rather than left
to be discovered in production.

### MCP traffic is out of scope

Kong does not allow a guardrail on MCP. The
[AI MCP Proxy plugin](https://developer.konghq.com/plugins/ai-mcp-proxy/) lists
"applying guardrails to MCP AI plugin requests and responses" as not supported,
and instructs that the plugin must not be configured together with other AI
plugins on the same Service or Route. The AI Policies attachable to an
[AI MCP Server](https://developer.konghq.com/ai-gateway/entities/ai-mcp-server/)
entity are rate limiting, request and response transformation, logging and
OAuth-based ACL gating — access control and volumetry, not content inspection.
`ai-custom-guardrail` therefore cannot see an MCP tool call, and neither can this
integration.

The limit is on the Kong side alone. Prisma AIRS already scans MCP: API Intercept
accepts a `contents[].tool_event` object — `metadata.ecosystem`, `method`,
`server_name`, `tool_invoked`, plus `input` and `output` — on the same
`/v1/scan/sync/request` endpoint used here, and reports its findings under
`tool_detected`, covering tool definition poisoning and credential leakage. See
[Detect MCP Threats](https://docs.paloaltonetworks.com/ai-runtime-security/administration/api-intercept-create-configure-security-profile/detect-mcp-threats).
Until Kong exposes an extension point on MCP traffic, covering MCP means calling
Prisma AIRS from outside the gateway — for example the
[Prisma AIRS MCP Server](https://docs.paloaltonetworks.com/ai-runtime-security/activation-and-onboarding/prisma-airs-mcp-server-for-centralized-ai-agent-security/understanding-the-prisma-airs-mcp-server),
where the agent invokes the scan itself. Kong's per-tool ACLs remain useful next
to that, but they restrict which tool may be called, not what travels inside it.

### Tool calls on the LLM path

Settled on a live gateway on 2026-09-08 (Kong AI Gateway 2.0.3, data plane
3.14.0.3-enterprise), with the procedure in
[docs/lab-tool-calls.md](docs/lab-tool-calls.md). `$(content)` carries message
**content**, and nothing else:

| Position | `last_message` | `concatenate_user_content` | `concatenate_all_content` |
|---|---|---|---|
| system message | no | no | **scanned** |
| user message | last message only | **scanned** | **scanned** |
| `tools[].function.description` | no | no | **no** |
| assistant `tool_calls[].function.arguments` | no | no | **no** |
| `role: "tool"` result content | no | no | **scanned** |

Two consequences, and they point in opposite directions.

**Tool definitions and generated tool arguments never enter `$(content)`**,
under any `text_source`. They are not message content. That was a hard gap until
2026-09-14, when it turned out a guardrail function can read the request body
itself: `params.tool_scan` recovers them and appends them to the scanned text —
`calls` for the arguments a model generates, `catalogue` for the `tools[]`
declaration as well. Measured with the guardrail in `INPUT` mode, on a
conversation whose injection sat solely inside a tool call's arguments: allowed
5/5 with the setting off, blocked 5/5 with it on. It ships off, because
`catalogue` in particular will be flagged by a profile with the source-code
detector — a JSON parameter schema reads as code.

Sending them as `contents[].tool_event` instead, which is the richer shape and
which a live tenant does flag, is not possible here: a tool event is judged only
when it is the last element of `contents[]`, so it would displace the prompt
from the same scan. One guardrail call is one scan is one judged element.

**Tool results are scanned** under `concatenate_all_content` — a `role: "tool"`
message is a message with content like any other. So data coming back from a
tool, which is where an untrusted external system injects into the context, does
reach Prisma AIRS.

The concatenation itself is worth knowing, and it caused a false positive of its
own: `text_source` joins messages with `\n\n` in **reverse chronological order**
and with no indication of who said what. An ordinary two-turn exchange was
blocked as prompt injection on a live tenant because the assistant's own answer,
arriving unattributed inside the prompt, reads as an assertion planted there.
The shipped configuration therefore rebuilds the scanned text from the request
body with each turn prefixed `user:` or `assistant:` — never `system:`, which is
the shape of a system-prompt spoof and blocks the whole conversation on its own.
See [Design decisions](#design-decisions).

### Streaming responses are scanned in segments

Corrected 2026-09-14; this section previously said the `OUTPUT` phase was
never invoked on a `stream: true` response, and that was wrong. The phase does
run: it scans the streamed content in segments of about
`response_buffer_size` bytes, each segment as one call to Prisma AIRS. Content
still below the threshold when the stream ends is never scanned, so a short
stream, or one that never fills a segment, can go unscanned even though the
phase ran.

Measured with the schema default (100 bytes — this repository no longer
overrides it, see [Design decisions](#design-decisions)): a 309-character
stream produced three `OUTPUT` calls, of 101, 104 and 103 characters — 308 of
309 characters scanned. At `response_buffer_size: 1`, the same kind of stream
produced 69 calls, the first segment still close to 100 bytes and the rest one
chunk each. At
`response_buffer_size: 65536` — the value this repository shipped until
2026-09-14 — the same stream produced **zero** `OUTPUT` calls: it never
accumulated 65536 bytes before ending. That configuration choice, not a Kong
limitation, is what the 2026-09-08 measurement below actually captured.

A non-streamed response is always scanned in one call carrying the whole body,
whatever `response_buffer_size` is.

The unscanned tail is concrete, not theoretical. In one run the model was asked
to end its answer with the word "ready", with the guardrail set to block any
segment containing it. The 419-character stream was scanned as four segments
totalling 408 characters; the last 11 characters, the ones containing "ready",
were never sent to the guardrail, and the stream completed HTTP 200 with
`finish_reason: stop`. The word that would have blocked the response never
reached a scan.

A block verdict on a streamed segment arrives too late for that segment: by
the time Prisma AIRS answers, the flagged segment has already reached the
client (measured: 108 characters received by the client, more than the
102-character segment that triggered the block). What happens next depends on the model provider driver.
On the `ollama` driver, the stream is cut: no further chunks and no `finish_reason` chunk, on top of an HTTP 200 already sent. On the `openai` driver, the stream ends cleanly: a last chunk carries `finish_reason: "blocked_by_guard"` with the generic block message as its `delta.content`, followed by `data: [DONE]`; under `rejection_mode: verbose` that chunk also carries a `guardrail_result` object (`code: GUARDRAIL_BLOCKED`, reason "response blocked by guardrails"), no category or detection.
Measured 2026-09-14 on both drivers against the same local model.

Measured 2026-09-14 with a guardrail answering `block` for every segment,
`OUTPUT` phase, default buffer, on a local model producing about 450
characters per second: with a 3 s verdict latency the whole 1005-character
stream reached the client and ended with `finish_reason: stop`, nine block
verdicts arriving after the end; with 0.5 s (the order of a Prisma AIRS round
trip) about 320 characters reached the client before the cut; with 0.05 s,
about 120. The per-segment scans are asynchronous: they did not slow the
stream (2.3 s with nine scans of 0.5 s each, against 2.2 s with no guardrail),
which is also why they cannot hold it back. What a stream leaks before a block
is roughly the model's output rate multiplied by the scan latency, plus one
segment.

So streaming coverage prevents what follows a detection, not the
detection itself, and each segment is scanned without the context of the ones
before it. See [Design decisions](#design-decisions) for the two ways to
handle it.

The `OUTPUT` phase also carries no prompt context alongside the response it
scans, which is a design limit rather than a schema gap.

## Requirements

| | |
|---|---|
| Kong Gateway data planes | 3.14 or later, with an AI licence |
| Existing chain | `ai-proxy` or `ai-proxy-advanced` already in place |
| Prisma AIRS | An API Intercept application and a named security profile |
| Network | Outbound HTTPS from the data planes to `service.api.aisecurity.paloaltonetworks.com:443` |

Below Kong Gateway 3.14, `ai-custom-guardrail` is unavailable. An alternative
based on the `request-callout` plugin exists upstream, limited to prompt scanning
and the OpenAI chat completion format.

## TL;DR — install and configure

Five minutes, on an AI Gateway 2.x control plane. The classic Gateway control
plane variant is the same configuration wrapped for `deck`; see the deployment
guide.

**1. Put the Prisma AIRS key on the data planes**, as the environment variable
`AIRS_TOKEN`. The configuration never holds the key: it carries the reference
`{vault://env/airs-token}`, which Kong resolves against that variable, inside
your own infrastructure.

```bash
# Azure Container Apps
az containerapp secret set --name <dp-app> --resource-group <rg> \
  --secrets airs-token=<PRISMA_AIRS_API_KEY>
az containerapp update --name <dp-app> --resource-group <rg> \
  --set-env-vars AIRS_TOKEN=secretref:airs-token

# Kubernetes
kubectl create secret generic prisma-airs -n <ns> \
  --from-literal=airs-token=<PRISMA_AIRS_API_KEY>
# then mount it as AIRS_TOKEN in the data plane deployment
```

**2. Set two values in [`config/kongctl/airs-guardrail.yaml`](config/kongctl/airs-guardrail.yaml)**,
in `params`, on both policies. Nothing else has to change to get a working
deployment:

| `params` key | Set it to | Default |
|---|---|---|
| `profile` | your Prisma AIRS security profile name, exactly | `kong-airs-prod` (a placeholder — it will fail closed until you change it) |
| `app_name` | a label identifying this gateway in your scan logs | `kong-ai-gateway` |

If your tenant is not on the global endpoint, change `request.url` too — it is
the single point of change for the region.

**3. Apply, attach, validate.**

```bash
export KONNECT_PAT="<konnect pat>"
export AI_GATEWAY_ID="<ai gateway id>"

kongctl apply -f config/kongctl/airs-guardrail.yaml --pat "$KONNECT_PAT"
# then attach ONE policy to your AI Model — airs-scan for prompt and response,
# airs-prompt-scan for a model that must stream — and never both:
#   policies:
#     - !ref airs-scan

export KONG_PROXY_URL="https://<proxy>"
export CLIENT_KEY="<client credential>"
./scripts/test-airs.sh          # 5 cases: 1 allowed, 3 blocked, 1 streaming probe
```

### Optional `params`, all off unless set

| Key | What it turns on |
|---|---|
| `session_header` | the request header naming the **conversation**, forwarded to Prisma AIRS as `session_id` so a whole conversation is one AI Session. Without it, each exchange is its own session |
| `user_header` | the request header naming the **end user**, used as `metadata.app_user` when no Kong consumer is authenticated. Caller-controlled: it labels a scan, it never authenticates one |
| `transaction_header` | lets the caller name the **round** itself; by default the round is Kong's own request id, which the client also receives as `X-Kong-Request-Id` |
| `tool_scan` | `calls` also scans the arguments a model generates for a tool call, which no `text_source` exposes; `catalogue` adds the `tools[]` declaration on top — expect a profile with the source-code detector to flag that one |
| `context_messages` | caps how many of the most recent conversation parts are assembled, to bound cost and stay under the 2 MB scan limit |

With a front-end that already knows its user and its conversation, naming two
headers is the whole integration. For Open WebUI, for instance:

```yaml
params:
  session_header: "x-openwebui-chat-id"
  user_header: "x-openwebui-user-email"
```

### Optional add-on policies

| File | What it does |
|---|---|
| [`config/kongctl/airs-diagnostics-log.yaml`](config/kongctl/airs-diagnostics-log.yaml) | writes the guardrail's own record — block reason, category, detections, per-phase scan latency, request id — to the data plane's standard output, so reporting a problem is one `docker logs` / `kubectl logs`. Carries an `enabled` switch and scrubs client credentials out of the record |
| [`config/kongctl/airs-error-sanitizer.yaml`](config/kongctl/airs-error-sanitizer.yaml) | replaces the `HTTP 500` body Kong returns when Prisma AIRS cannot be consulted with a fixed generic one |

Each has a `config/deck/` counterpart for the classic control plane.

### What the client sees

| Status | Meaning |
|---|---|
| `200` | allowed |
| `400` | blocked by policy — body `{"error":{"message":"Blocked by Prisma AIRS [scan_id=...]"}}`. The category and the detection names never leave the gateway; the `scan_id` is how you find the full verdict in Strata Cloud Manager, or through `GET /v1/scan/results?scan_ids=` |
| `500` | Prisma AIRS could not be consulted, and fail-closed refused the request rather than let it through unscanned |

Full procedure, including the classic Gateway control plane variant, progressive
rollout and troubleshooting: **[docs/deployment-guide.md](docs/deployment-guide.md)**.

## Repository layout

```
docs/deployment-guide.md             step-by-step deployment procedure
docs/sources.md                      canonical upstream references
docs/lab-tool-calls.md               lab procedure: is function calling scanned?
docs/lab-streaming.md                lab procedure: is a streamed response scanned, and how?
docs/lab-classic-control-plane.md    lab procedure: the deck variant on a classic control plane
config/kongctl/airs-guardrail.yaml   AI Gateway 2.x
config/deck/airs-guardrail.yaml      classic Gateway control plane
config/kongctl/airs-error-sanitizer.yaml   optional: generic body when Prisma AIRS cannot be consulted
config/deck/airs-error-sanitizer.yaml      same, classic control plane
config/kongctl/airs-diagnostics-log.yaml   optional: one diagnostics log on the node, with an on/off switch
config/deck/airs-diagnostics-log.yaml      same, classic control plane
scripts/test-airs.sh                 five-case validation suite, needs a live gateway
scripts/run-lua-tests.sh             offline unit tests for the verdict functions
scripts/test-verdict-functions.lua   the assertions those tests run
scripts/check-plugin-schema.py       config parity and live-schema validation, used in CI
scripts/lab-echo-server.py           stands in for Prisma AIRS, logs what Kong emits
scripts/lab-tool-call-probe.sh       one completion, a marker per tool call position
```

## Design decisions

**Two policies by coverage, not by direction.** `airs-scan` runs
`guarding_mode: BOTH` — the prompt is scanned in its `INPUT` phase, the model
output in its `OUTPUT` phase — and `airs-prompt-scan` runs `guarding_mode: INPUT`
for models that serve streaming responses. Exactly one is attached per AI Model
(kongctl) or per scope (deck). A single request body function picks
`contents[].prompt` versus `contents[].response` from `$(source)`, which the
plugin overview documents as `INPUT` / `OUTPUT`.

The earlier layout attached one `INPUT` policy and one `OUTPUT` policy to the
same model. Attaching two is accepted by the AI Gateway 2.x API — measured, the
model came back with both in its `policies` array — but it does not give
prompt-and-response coverage, and which of the two runs is not something the
declaration order controls: with both attached, the `INPUT` policy was the one
that executed. On the deck side the same thing is rejected outright, because
Kong keys a plugin instance on `{name, route, service, consumer}`, and that key
([`cache_key`](https://github.com/Kong/kong/blob/master/kong/db/schema/entities/plugins.lua))
is a unique column in the underlying Postgres table
([`000_base.lua`](https://github.com/Kong/kong/blob/master/kong/db/migrations/core/000_base.lua)),
so a second `ai-custom-guardrail` instance on the same scope is rejected at apply
time. Kong also runs a single instance of a given plugin per request, with a
route-level instance overriding the service-level one for that route — see the
[plugin entity page](https://developer.konghq.com/gateway/entities/plugin/). The
deck variant uses that precedence directly: `airs-scan` at service level,
`airs-prompt-scan` at route level on the dedicated streaming route.

**Nested JSON comes from functions.** `request.body` is a flat map of strings —
nested YAML fails schema validation. The Prisma AIRS payload is assembled by small
Lua functions that return a table, following Kong's own Azure Content Safety
example.

**Fail closed by default, through two mechanisms that cover two different
failures.** `stop_on_error` governs a call to Prisma AIRS that fails outright:
unreachable, timed out, a non-2xx status, or an undecodable body. `true`
(shipped) blocks the request. `false` is fail-open on that failure alone:
measured against an unreachable endpoint, HTTP 200 with the model's answer,
while both phases log the failure at error level and the traffic goes through
unscanned. The `airs_verdict` function is never evaluated in that case, because
there is no guardrail response to evaluate. `airs_verdict` governs the other
failure: a call that succeeds but returns an unusable verdict, including
`category: "error"` and `category: "timeout"`, which AIRS returns alongside
`action: "allow"`. Only `action: "allow"` passes traffic; any other action, a
missing or malformed verdict, or a degraded scan category blocks. A pilot that
wants fail-open only on a guardrail outage changes `stop_on_error` alone; one
that also wants to pass AIRS-degraded verdicts changes the Lua branches too.
Full fail-closed, the shipped default, needs both.

Measured client-visible behaviour when the call to the guardrail service fails,
with `stop_on_error: true` (shipped):

| Failure | Client status | Note |
|---|---|---|
| Unreachable endpoint | 500 | internal error text, immediate |
| Timeout (`timeout: 5000`) | 500 | internal error text, at 5.0 s (the timeout is honoured to the millisecond) |
| Guardrail answers HTTP 500 | 500 | the guardrail's own error body is relayed verbatim to the client |
| Guardrail answers 200 with a non-JSON body | 500 | internal decode-error text, immediate |

`rejection_mode` has no effect on any of these rows: it only shapes a *block*
response, not a call failure. The client contract is therefore: HTTP 400 means
blocked by policy; HTTP 500 means the guardrail could not be consulted and
`stop_on_error: true` refused the request. This is an information-disclosure
limit worth noting: the 500 body names the guardrail step and its failure, and
on a bad-status failure it includes the guardrail service's own error body, not
just a generic message. An optional `post-function` policy,
[`config/kongctl/airs-error-sanitizer.yaml`](config/kongctl/airs-error-sanitizer.yaml),
attached next to `airs-scan`, replaces that body with
`{"error":{"message":"Guardrail unavailable"}}` while leaving blocks, allowed
responses and streams untouched (measured 2026-09-14); the original text stays
in the data plane error log. It matches Kong's own wording, so a Kong release
that rewords the error turns it into a no-op, never into a block.

**Generic block message.** The client only ever sees "Blocked by Prisma AIRS",
optionally followed by " [scan_id=...]" — never the category or the detection
names, and the same generic message is returned on a fail-closed block as on a
real detection. Naming the detection to the caller is an evasion oracle: it lets
an attacker use the block response itself to map which inputs trip which
detector. The detection detail is not lost: it is in the Prisma AIRS scan logs
in Strata Cloud Manager, correlated by `scan_id`, which is the channel to rely
on. The configuration also routes it to `metrics.block_reason` (the same
generic message, with `scan_id`, for correlation) and `metrics.block_detail`
(category and detection names) — the schema accepts both fields, but
`block_detail` must evaluate to a Lua table, not a string. Until 2026-09-14
`airs_verdict` returned `detail` as a string, and the data plane logged a
warning on every single request, allowed or blocked, in both phases —
`metric input_block_detail has unexpected type string, expected table` —
which is very probably why nothing guardrail-related was seen on the metrics
endpoint at all. `airs_verdict` now returns `detail` as a table,
`{ reason, category, detections }` (`reason` the same string it always
returned, `detections` the sorted detection names, `category` the AIRS
category, or `"unavailable"` on a missing verdict); the warning is gone,
measured over the same request set, and `block_message` is unchanged. The
templated values are exported, but only through Kong's log serializer, not
through Konnect's own request analytics. A `file-log` policy attached to the AI
Model next to `airs-scan` carries an `ai.proxy.custom-guardrail` object with
our exact values, and an `ai.proxy.guardrail_triggered` object alongside it, for
example:

```json
"custom-guardrail": {"mode": "BOTH",
  "input_block_reason": "Blocked by Prisma AIRS [scan_id=<scan_id>]",
  "input_block_detail": {"category": "malicious", "reason": "malicious: injection", "detections": ["injection"]},
  "input_block_source": "ai-custom-guardrail", "input_processing_latency": 0, "output_processing_latency": 0},
"guardrail_triggered": {"blocked_content": "", "block_source": "ai-custom-guardrail", "block_direction": "AI_GUARDRAIL_BLOCK_INPUT"}
```

documented at Kong's
[AI Gateway audit log reference](https://developer.konghq.com/ai-gateway/ai-audit-log-reference/).
The Konnect Requests analytics API (`v2/api-requests`), by contrast, carries
only the `ai-proxy` entry on every record checked, no guardrail field at all,
which is what earlier looks at that API found. The Konnect UI dashboards were
not inspected. Strata Cloud Manager's scan log remains the record to rely on
for detection detail. Palo Alto's own reference integration
([`request-callout` config](https://github.com/PaloAltoNetworks/prisma-airs-integrations))
follows the same pattern, returning a generic "Blocked by AI security scan".

**Block response format.** The shipped contract stays `rejection_mode: none`
(the schema default): HTTP 400 with the generic body,
`{"error":{"message":"<block_message>"}}`. Two more values exist on a 2.0.3
data plane: `verbose` returns HTTP 403 with a structured body,
`{"error":{"plugin":"ai-custom-guardrail","reason":"<block_message>","code":"GUARDRAIL_BLOCKED","type":"guardrail_rejected"}}`
— still only the generic message, no category or detection — and `stealth`
returns HTTP 403 `{"error":{"message":"request forbidden"}}`, dropping the
`scan_id` too. Both are announced in the
[AI Gateway 2.0.1 changelog](https://developer.konghq.com/ai-gateway/changelog/)
(2026-07-29) but are not yet in the schema published on the reference page, so
both configuration files carry them commented out rather than shipped —
turning them on would fail `scripts/check-plugin-schema.py --schema` until
Kong publishes the field. `verbose` is the option to reach for if a caller
needs a machine-readable code instead of parsing the message. A third field
from the same changelog entry, `log_blocked_content`, is commented out
alongside them; enabling it added nothing visible to the data plane's own
error log in this round, and it stays off in any case, since prompts are
personal data.

**Pilot mode.** `continue_on_detection: true` — also commented out, same
reason — turns a block verdict into HTTP 200 with the model's actual answer:
the guardrail is still called, in both phases, but nothing is refused. It is a
monitoring switch for a pilot phase, alongside the Prisma AIRS profile's own
alert-only option, and it changes only what happens after a verdict is
reached. It is not a substitute for the fail-open change described above for
`stop_on_error`: that setting governs what happens when the call to Prisma
AIRS itself fails, which `continue_on_detection` does not touch.

**Secrets in the slot built for them.** The API key is a
`{vault://env/airs-token}` reference resolved by the data plane at runtime, and
it is carried by `request.auth` (`location: header`, `name: x-pan-token`) rather
than by `config.params` plus a `$(conf.params.api_key)` interpolation. Both
fields are referenceable, so the vault reference resolves either way — verified
against a live tenant — but `request.auth.value` is also stored encrypted, and
the credential no longer appears in the `conf` table that guardrail functions
receive. The key never transits the SaaS control plane and never appears in
version control.

**Streaming, and what to do about it.** Response scanning does run on a
stream, see
[Streaming responses are scanned in segments](#streaming-responses-are-scanned-in-segments),
but as per-segment, asynchronous, detect-after-delivery scans: a block cannot
stop the flagged segment, and what leaks before the cut grows with the model's
output rate and the scan latency. Two postures, one line apart on the AI Model:

- **Simple mode, the default.** One policy, `airs-scan`, on every model,
  `response_streaming` left at its default `allow`. Non-streamed responses are
  scanned whole before delivery. Streamed responses get prompt scanning before
  the model and best-effort response scanning: every segment is scanned and
  logged in Strata Cloud Manager, the stream is cut once a verdict says block,
  and the client is not slowed down. Nothing to decide per model, nothing for
  a caller to break.
- **Strict mode.** `airs-scan` together with `config.response_streaming: deny`
  on models where no unscanned character may reach the client: a `stream: true`
  request is refused before it reaches the model or the guardrail
  ([AI Gateway streaming](https://developer.konghq.com/ai-gateway/streaming/)),
  measured HTTP 400
  `{"error":{"message":"response streaming is not enabled for this LLM"}}`.
  Models that must stream under strict mode take `airs-prompt-scan` instead,
  prompt-only coverage stated plainly.

`response_buffer_size` is no longer set in either policy: the schema default
(100) applies, and the field only has an effect on a streamed response in the
first place — a non-streamed response is always scanned in one call regardless
of its value.

**Measured cost.** One lab, one geography: data plane in France, the **global**
Prisma AIRS endpoint rather than a regional one, and a local Ollama answering in
about 30 ms. Eight requests per configuration, all verified HTTP 200:

| Configuration | Median end to end | Added |
|---|---|---|
| No policy | 73 ms | — |
| `airs-prompt-scan`, `INPUT`, one AIRS scan | 577 ms | +0.50 s |
| `airs-scan`, `BOTH`, two AIRS scans | 876 ms | +0.80 s |
| `airs-scan` against a guardrail on the local network | 32 ms | +3 ms |

The cost is the call to Prisma AIRS — about half a second per scan here — and
the two scans of `BOTH` are sequential. The plugin itself costs about 3 ms.

Read these numbers as one data point, not as a specification. They were taken
from France against the global endpoint, and the shape of the delay is not a
simple distance effect: the TCP connection to that endpoint completes in about
25 ms, so most of the half second is the scan and its backhaul rather than the
first network hop. Measure your own path before committing to a latency budget,
and measure a regional endpoint against the global one rather than assuming
which is faster.

## Verification status

Every configuration key used here, and every allowed value, comes from the
published Kong plugin schema and the Prisma AIRS OpenAPI client — see
[docs/sources.md](docs/sources.md). The verdict functions are unit tested
offline, and the whole configuration was exercised against a live gateway:

```bash
./scripts/run-lua-tests.sh     # offline verdict suite
./scripts/test-airs.sh         # 5 asserted cases plus a streaming probe, needs a live gateway
```

**Lab run of 2026-09-08.** Konnect AI Gateway 2.x control plane, one
self-managed data plane (`kong/kong-ai-gateway:2.0.3`, Kong Gateway
3.14.0.3-enterprise), a local Ollama as the model, a live Prisma AIRS tenant
with a profile in block mode. `scripts/test-airs.sh`: 5 cases out of 5 matched.

What that run settled, all previously `SYNTHESIZED`:

- **Functions are referenced bare, `$(fn)`, and the built-ins are injected by
  parameter name.** A function declaring `(source, content)` receives the phase
  and the text, one declaring `(conf)` receives the config, one declaring
  `(resp)` receives the guardrail response. An unrecognised parameter name is
  rejected outright: *argument 'a' is not allowed in guardrail functions*. The
  explicit-argument call form `$(airs_contents(source, content))`, which this
  repository shipped until this run and which the plugin overview appears to
  license, is **invalid**: the data plane answers HTTP 500, *failed to render by
  function: invalid expression syntax*, and no request reaches the model.
- **`$(resp)` is a Lua table in both phases**, `OUTPUT` included. The overview's
  "string when inspecting the response" does not hold for the guardrail service
  response, so the defensive `cjson.safe` decode in the `OUTPUT` verdict is dead
  code.
- **A block returns HTTP 400**, with the body
  `{"error":{"message":"<block_message>"}}`. That is the client contract.
- **`$(content)` under `concatenate_all_content`** is the message contents joined
  by `\n\n` in reverse chronological order, system prompt included, tool results
  included, tool definitions and tool call arguments excluded — see
  [Scope and limits](#scope-and-limits).
- **`guarding_mode: BOTH` covers both phases in one policy**, with `$(source)`
  distinguishing them, and the two scans are sequential.
- **Streaming skips the `OUTPUT` phase entirely, with no error** — this is
  what the run measured on 2026-09-08, and the conclusion was wrong. Corrected
  2026-09-14: the phase does run on a stream, in segments; the 2026-09-08
  setup had `response_buffer_size: 65536`, which no stream in that run ever
  filled. See [Scope and limits](#scope-and-limits).

Confirmed against the schema and the published examples: `guarding_mode`,
`text_source`, `params`/`request.*`/`response.*`/`functions`, `timeout`,
`ssl_verify`, `stop_on_error`, `response_buffer_size`, `allow_masking`,
`metrics`, `custom_metrics`, `request.auth`, dotted access to a function result
(`$(fn.field)`), and the `$(source)` values `INPUT` / `OUTPUT`. The plugin
instance uniqueness and route-over-service precedence behind the two-policy
design are documented on Kong's plugin entity page and in the `kong` GitHub
repository — see [docs/sources.md](docs/sources.md).

A second round on the same gateway settled the rest:

- **`request.auth` works, and is now what this repository ships.** With
  `location: header`, `name: x-pan-token` and a `{vault://env/airs-token}`
  value, the credential reaches the guardrail service and the five-case suite
  passes. It replaces `params.api_key` + `$(conf.params.api_key)`.
- **A guardrail function that raises fails the request closed**, with HTTP 500
  and the Lua error text in the body. That is independent of `stop_on_error`,
  which covers the HTTP call rather than the templating. Note the error text is
  client-visible, so a `error()` message must not carry anything sensitive.
- **Only `source`, `content` and `conf` are injectable.** Every other parameter
  name — `consumer`, `model`, `route`, `service`, `request`, `headers`, `ctx`,
  `kong`, `metadata`, `plugin` — is rejected with *argument '<name>' is not
  allowed in guardrail functions*, and `resp` is accepted but empty on the
  request side. There is therefore **no way to reach the Kong consumer identity
  or the model name from a guardrail function**, so enriching the Prisma AIRS
  `metadata` object with request context is not possible with configuration
  alone.
- **Two guardrail policies can be attached to one AI Model in 2.x** — the API
  accepts it — but only one executes, and not the one declaration order would
  suggest. Attach exactly one. On the deck side the second instance is rejected
  at apply time instead.
- **`require` and `cjson.safe.decode` work inside a guardrail function**, which
  is why the string-decoding branch of the verdict is kept rather than deleted
  as dead code: it is real cover if a Kong release ever passes `$(resp)` as a
  string, and without it that release would fail every request closed.

A third round, 2026-09-14, corrected the streaming finding above and settled
four more items:

- **Streaming is scanned, not skipped.** The `OUTPUT` phase runs on a
  `stream: true` response in segments of about `response_buffer_size` bytes: a
  309-character stream produced three calls (101 / 104 / 103 characters) at
  the schema default of 100, 69 calls at `response_buffer_size: 1`, and zero
  calls at `response_buffer_size: 65536` — the value this repository shipped
  until this round, which is why the 2026-09-08 run saw nothing. A block on a
  flagged segment ends the stream after that segment has already reached the
  client, on top of an HTTP 200 already sent; how it ends depends on the
  driver (sixth round, below). See
  [Scope and limits](#scope-and-limits).
- **`metrics.block_detail` must be a Lua table.** As a string it produced a
  data-plane warning on every request, in both phases, regardless of the
  verdict — plausibly why nothing guardrail-related was ever seen on the
  metrics endpoint. `airs_verdict` now returns `detail` as
  `{ reason, category, detections }`; the warning is gone, `block_message` is
  unchanged.
- **Four more config fields exist on a 2.0.3 data plane but are not yet on the
  published schema page**: `rejection_mode` (`none` / `stealth` / `verbose`),
  `continue_on_detection`, `log_blocked_content`, and `proxy_config`, all
  announced in the
  [2.0.1 changelog](https://developer.konghq.com/ai-gateway/changelog/).
  Measured behaviour is in [Design decisions](#design-decisions); the shipped
  configuration keeps only schema-published keys and carries the rest
  commented out, so `scripts/check-plugin-schema.py --schema` keeps passing.
- **The AI Gateway 2.x runtime is Kong Gateway 3.14.0.3**, carrying an AI
  Gateway version label; what actually refuses the custom Lua plugin path is
  the Konnect control plane, which rejects a `type: prisma-airs-intercept`
  policy with HTTP 400, "policy type 'prisma-airs-intercept' is not
  supported". See [Why this exists](#why-this-exists).
- **`response_streaming: deny` refuses a stream before any guardrail call.**
  Measured: HTTP 400,
  `{"error":{"message":"response streaming is not enabled for this LLM"}}`, on
  the AI Model. Adopted for `airs-scan`; see
  [Design decisions](#design-decisions).

A fourth round, 2026-09-14, after PR #11 merged, settled the fail-open
behaviour, the guardrail-failure client contract, the `metrics.*` export path,
`proxy_config`, and put a concrete number on the streaming tail gap:

- **`stop_on_error: false` is fail-open on a guardrail-call failure, and only
  on that failure.** Measured against an unreachable endpoint: HTTP 200 with
  the model's answer, both phases logging the failure as an error, and
  `airs_verdict` never evaluated, since there is no guardrail response to
  evaluate. See [Design decisions](#design-decisions).
- **Every guardrail-call failure reaches the client as HTTP 500**, whatever
  `rejection_mode`, carrying the internal error text, and on a bad-status
  failure, the guardrail's own error body relayed verbatim. `timeout` is
  honoured to the millisecond: a 5.0 s timeout produced the 500 at 5.0 s. See
  [Design decisions](#design-decisions).
- **`metrics.*` are exported, through Kong's log serializer, not through
  Konnect's request analytics.** A `file-log` policy attached next to
  `airs-scan` carries `ai.proxy.custom-guardrail` with our exact values, and
  `ai.proxy.guardrail_triggered` alongside it; the Konnect Requests analytics
  API (`v2/api-requests`) still carries only the `ai-proxy` entry. That policy
  is shipped as `config/kongctl/airs-diagnostics-log.yaml`, writing to the data
  plane's standard output so a problem report is one `docker logs` away, with
  an `enabled` switch and the client-credential headers scrubbed out of the
  record. See [Design decisions](#design-decisions).
- **`proxy_config` works.** `http_proxy_host` / `http_proxy_port` on
  `airs-scan`, against an `http://` guardrail URL, routed both the INPUT and
  the OUTPUT call through the forward proxy. The `https_proxy_host` /
  `https_proxy_port` pair was verified in the fifth round, below.
- **The streaming tail gap, with a number on it.** A 419-character stream was
  scanned in four segments totalling 408 characters; the last 11 characters,
  containing the word the guardrail was set to block, were never sent to
  Prisma AIRS, and the stream completed HTTP 200. See
  [Streaming responses are scanned in segments](#streaming-responses-are-scanned-in-segments).

A fifth round, the same day, closed two of the remaining items:

- **`proxy_config` works for the https pair too.** The shipped `airs-scan`,
  against the real Prisma AIRS endpoint through a forward proxy speaking
  HTTP CONNECT: `scripts/test-airs.sh` 5/5, eleven `CONNECT` tunnels logged
  from the data plane. Proxy credentials and `no_proxy` were not exercised.
- **The verbose HTTP 500 body can be made generic with a `post-function`
  policy**, shipped as an optional file; see
  [Design decisions](#design-decisions). `exit-transformer`, tried first, does
  not intercept that response, with or without its `handle_unknown` /
  `handle_unexpected` switches
  ([exit-transformer](https://developer.konghq.com/plugins/exit-transformer/)
  hooks `kong.response.exit()` only).
- **The OpenAI-driver hypothesis for the `blocked_by_guard` chunk needed one
  more try.** A second model provider of type `openai` pointed at the local
  model's OpenAI-compatible endpoint answered 404 then 405 until
  `upstream_url` carried the full endpoint path: on that driver the field is
  the complete URL, `http://<host>/v1/chat/completions`, where the `ollama`
  driver takes a base URL. Settled in the sixth round, below.

A sixth round, the same day, settled the terminal chunk:

- **`finish_reason: "blocked_by_guard"` exists, and it is driver-dependent.**
  Same local model, same blocking guardrail, `guarding_mode: OUTPUT`, default
  buffer. Through the `ollama` driver the stream is cut with no terminal
  chunk, as measured in every earlier round. Through the `openai` driver the
  first segment is delivered, then a last chunk arrives with
  `finish_reason: "blocked_by_guard"` and the generic block message as
  `delta.content`, then `data: [DONE]`. With `rejection_mode: verbose` the
  last chunk carries `delta.content: "response blocked by guardrails"` and a
  `guardrail_result` object (`plugin`, `reason`, `code: GUARDRAIL_BLOCKED`,
  `type: guardrail_rejected`), with no category or detection name. In both
  cases the flagged segment has already reached the client. See
  [Streaming responses are scanned in segments](#streaming-responses-are-scanned-in-segments).

A seventh round, the same day, took the classic control plane variant out of
the untested column and probed three more limits:

- **The deck variant works on a classic control plane.** A Konnect classic
  control plane with one `kong/kong-gateway:3.14.0.14` data plane, the
  shipped `config/deck/airs-guardrail.yaml` with only the model target pointed
  at the local model: `scripts/test-airs.sh` 5/5 twice; `stream: true` on the
  service route refused with the same HTTP 400 body as on AI Gateway 2.x; the
  dedicated streaming route streams and its route-level `airs-prompt-scan`
  blocks a malicious prompt; the `OUTPUT` phase blocks a flagged response
  (HTTP 400, one `contents[].response` call); and
  `config/deck/airs-error-sanitizer.yaml` turns the outage HTTP 500 into
  `{"error":{"message":"Guardrail unavailable"}}`. Procedure in
  [docs/lab-classic-control-plane.md](docs/lab-classic-control-plane.md).
- **The Prisma AIRS payload limit fails closed.** Kong forwards the whole
  scanned text (3.58 million characters measured, no truncation). A 2.05 MB
  prompt was scanned and answered; a 3.5 MB prompt got HTTP 413 from Prisma
  AIRS, "The request body is too large", which `stop_on_error: true` turned
  into HTTP 500 to the client in 1.2 s, the 413 body relayed. Under
  `concatenate_all_content` the whole conversation counts against that limit.
- **Concurrency holds.** Twenty parallel requests, each with its own marker:
  twenty prompt scans and twenty response scans, every payload carrying
  exactly its own marker. Twenty parallel requests on the live tenant, every
  third one malicious: every verdict landed on the right request.
- **The suite's fifth case flaked on the response leg.** One run in eight was
  blocked with category `source_code`: the model had answered the question
  about prompt injection with a code snippet, and the lab profile detects
  source code. The prompt now asks for prose; five consecutive runs pass. A
  block on that case points at the profile, and the category is in the scan
  log.

An eleventh round traced a false positive from the Strata Cloud Manager UI back
to this repository's own payload, and fixed it:

- **Ordinary conversation was being blocked as prompt injection.** A two-turn
  exchange — "What is the capital of France? / The capital of France is Paris. /
  And Italy?" — came back `agent` + `injection`, 3/3. `text_source` joins
  message content with no indication of who said what, so the model's own answer
  arrived inside the prompt unattributed and read as an assertion planted there.
  The threat report's `pi` snippet was exactly that concatenation. Prefixing
  each turn `user:` / `assistant:` makes it benign while a real injection still
  blocks, whether newest or earlier.
- **`system:` must never be written into the scanned text.** Labelling the
  system message that way is the shape of a system-prompt spoof and blocks the
  whole conversation; the same content unlabelled is benign. Tool results and
  unknown roles are unlabelled for the same reason.
- **How it was traced, which is the reusable part.** The `scan_id` this
  repository puts in the client-facing block message is what closed the loop:
  it reaches the caller, so it is in the caller's logs, and
  `GET /v1/scan/results?scan_ids=` then `GET /v1/scan/reports?report_ids=`
  turn it into the detector list and the exact text that was judged. The AIRS
  API has no list-by-session endpoint, so without that id there is nothing to
  query.

A tenth round used the same mechanism to label scans and to scan tool calls,
and corrected a change made earlier the same day:

- **Prisma AIRS judges the LAST element of `contents[]` and nothing else.** The
  earlier elements are context, not scanned. Measured against a live tenant:
  an injection alone blocks; the same injection as the first of two elements,
  or the first of three, comes back `allow` / `benign`; as the last element it
  blocks again. So a scan carries **one** element holding everything that must
  be scanned. Splitting a conversation into one element per message reads like
  the schema's intent — "the last element is the one that needs to be scanned,
  and the previous elements are the context" — and silently stops scanning
  every turn but the newest. This repository briefly did exactly that, for a
  few hours on 2026-09-14, and the assertions now pin the single-element shape
  for that reason.
- **Tool calls can be scanned, behind `params.tool_scan`.** Tool definitions and
  the arguments a model generates are absent from `$(content)` under every
  `text_source`, so a tool call was only ever scanned on its way back in, as the
  text of its result. Reading `kong.request.get_body()` recovers them and they
  are appended to the scanned text. Measured with the guardrail in `INPUT` mode,
  on a conversation whose injection sat solely inside a tool call's arguments:
  allowed 5/5 with the setting off, blocked 5/5 with it on. `catalogue` adds the
  `tools[]` declaration, which a profile with the source-code detector will flag,
  since a JSON parameter schema reads as code.
- **`metadata` carries the model, the client address and the end user.**
  `ai_model`, `user_ip` and `app_user` are all reachable from a guardrail
  function. `app_user` prefers the authenticated Kong consumer and falls back to
  a configurable request header, which labels a scan and never authenticates
  one. `user_ip` is the address Kong considers the client's, so behind an
  untrusted load balancer it is the balancer: set `trusted_ips` on the data
  plane.
- **Everything degrades rather than breaks.** On a streamed response the
  `OUTPUT` segments have no request context, so the payload is the text Kong
  selected and `metadata` is `app_name` alone — and the segments are still
  scanned, seven of them on a 700-character stream, the same count as before.
  Every lookup is `pcall`-guarded.

A ninth round sent the correlation identifiers, which this repository had
declared out of reach for a configuration-only deployment:

- **The Kong PDK is reachable inside a guardrail function.** `kong` and `ngx`
  are tables in the function body. The earlier "no per-request value is
  reachable" conclusion came from probing what the plugin injects as a named
  ARGUMENT, which says nothing about the sandbox's globals. Working:
  `kong.request.get_header`, `kong.request.get_body().model`,
  `ngx.ctx.ai_model`, `kong.client.get_consumer()`, `kong.request.get_path()`,
  `ngx.var.request_id`. Not working: `kong.router.*` and
  `kong.log.serialize()`.
- **`kong.ctx.shared` survives from the `INPUT` phase to the `OUTPUT` phase**,
  so one identifier can be minted per exchange and reused by both scans. That
  is what `airs_correlation` does. The identifiers nest: `transaction_id` is
  one **round** — a prompt and the response it produced — and defaults to
  Kong's request id, the value the client receives as `X-Kong-Request-Id`;
  `session_id` is the **conversation** grouping several rounds, taken from a
  request header and falling back to the round so an exchange is never split
  across two sessions. Verified on the payloads reaching a lab echo server —
  matching round identifiers across both phases, one session identifier across
  two rounds — and accepted by the live Prisma AIRS tenant
  (`scripts/test-airs.sh` 5/5). Confirmed in the Strata Cloud Manager AI
  Sessions view: two rounds sent through Kong under one session header render
  as one session holding two transactions of two scans each.
- **`tr_id` is the older name of `session_id`, not of `transaction_id`**, so it
  is not sent. Six probes straight against a live tenant's
  `/v1/scan/sync/request`: a request carrying only `tr_id` comes back with
  `session_id` set to that value and a generated `transaction_id`; a request
  carrying only `transaction_id` comes back with a generated `session_id`; with
  `tr_id` and `session_id` both supplied, `session_id` wins. Sending the round
  under `tr_id` would therefore put the round identifier in the session slot.
- **An unguarded PDK call is a silent fail-open on streams.** Same policy, same
  streamed request: a function returning a constant produced 7 `OUTPUT` segment
  scans, the same function calling `kong.request.get_header` without a `pcall`
  produced **zero** — HTTP 200, stream delivered whole, nothing visible to the
  client — and the `pcall` version produced 7 again. On a stream's `OUTPUT`
  path there is no request context, and a raise there skips the scan instead of
  failing the request. Every PDK call in `airs_correlation` is wrapped, and the
  offline suite asserts that it never raises.
- **A nil field is omitted from the scan payload; an empty string is sent as
  JSON `false`.** So `airs_correlation` returns `nil`, never `""`, for an
  identifier it cannot build — which is also what a streamed `OUTPUT` segment
  gets, since it has no request context.

An eighth round added the diagnostics log, and closed the "how does a customer
report a problem" question:

- **One log on the node, with a switch.** `config/kongctl/airs-diagnostics-log.yaml`
  is a `file-log` policy writing the serializer record to the data plane's
  standard output, so a problem report is `docker logs` or `kubectl logs` and
  nothing else. Applied next to `airs-scan` with one `kongctl apply` and a `-f`
  per file — repeated `-f` flags share one reference namespace, so
  `!ref airs-diagnostics-log` resolves across them. One JSON record per request
  on both the allowed and the blocked case; `enabled: false` re-applied
  produces no record at all and leaves traffic untouched.
- **The record carries no credential and no prompt.** Kong's serializer
  includes request and response headers, so the policy removes `Authorization`,
  `x-api-key`, `apikey`, `Cookie` and `Set-Cookie` through
  `custom_fields_by_lua`: a request carrying the first three produced a record
  with none of them and no trace of their values. No body is logged either way,
  and `blocked_content` stays empty while `log_blocked_content` is `false`.
- **Scan latency is in the record on every request.** `input_processing_latency`
  and `output_processing_latency` measured 632 ms and 454 ms against the global
  Prisma AIRS endpoint on an allowed request — the zeros seen in round four were
  a local echo server answering in under a millisecond, not an unpopulated
  field. Everything else guardrail-side is populated only on a block: an allowed
  request carries no `scan_id`.

What remains unconfirmed:

- whether the templated `metrics.*` values appear in the Konnect UI views fed
  by the AI Gateway request-log channel, as distinct from the log-serializer
  export verified above and from the Requests analytics API, which carries
  none;
- whether other provider drivers (Anthropic, Bedrock, Gemini, Azure) end a
  blocked stream the `openai` way or the `ollama` way: only those two were
  measured.

Validate in a non-production environment before this reaches production traffic.

## Related

- Palo Alto Networks, official Kong integration assets:
  [PaloAltoNetworks/prisma-airs-integrations](https://github.com/PaloAltoNetworks/prisma-airs-integrations),
  specifically the
  [`custom-plugin-v3`](https://github.com/PaloAltoNetworks/prisma-airs-integrations/tree/main/Kong/custom-plugin-v3)
  flavours (buffered SSE scanning, MCP coverage) and the `request-callout`
  variant, for Kong Gateway and Konnect hybrid. Its deployment guide names this
  repository as the worked reference for AI Gateway 2.x
- Kong, [AI Custom Guardrail](https://developer.konghq.com/plugins/ai-custom-guardrail/)
- Kong, [AI Gateway Policies](https://developer.konghq.com/ai-gateway/policies/)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). To report a security issue, see
[SECURITY.md](SECURITY.md).

## Disclaimer

Community assets, not an official Palo Alto Networks or Kong product. Provided as
is, without support commitment from either vendor.

## Licence

MIT
