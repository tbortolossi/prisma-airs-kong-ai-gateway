# Limitations to plan for

What this configuration scans is the prompt text and the response text on the
LLM path. Everything below is a boundary of that, measured rather than assumed,
and stated here so none of it is discovered in production.

| Limitation | Short version | Mitigation |
|---|---|---|
| MCP traffic | Kong allows no guardrail on MCP at all | Call Prisma AIRS from outside the gateway |
| Tool definitions and generated tool arguments | No `text_source` exposes them | `params.tool_scan`, off by default |
| Non-text message parts (images, audio) | The text parts of an array `content` are assembled and scanned; the parts themselves (`image_url`, `input_audio`) are never sent to Prisma AIRS | — |
| A streamed response | Scanned in ~100-byte segments, and **an answer shorter than one segment is never scanned at all** | Stop the response streaming — see below |
| The `OUTPUT` phase on a stream | No request context, so no correlation identifiers | Non-streamed exchanges are unaffected |
| Scan payload size | Prisma AIRS refuses above about 2 MB | `params.context_messages`, or `text_source: last_message` |
| Prompt scanning | Never affected by any of the above | — |

The last row is the one to keep in mind: **every limitation on this page is on
the response leg.** The prompt is scanned before the model is called, on every
path, in every posture.

What this configuration scans is the prompt text and the response text on the LLM
path. Two adjacent surfaces are not covered, and are stated here rather than left
to be discovered in production.

## MCP traffic is out of scope

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

## Tool calls on the LLM path

Settled on a live gateway on 2026-09-08 (Kong AI Gateway 2.0.3, data plane
3.14.0.3-enterprise), with the procedure in
[docs/lab-tool-calls.md](lab-tool-calls.md). `$(content)` carries message
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
See [Design decisions](design-decisions.md).

## Streaming responses are scanned in segments

Corrected 2026-09-14; this section previously said the `OUTPUT` phase was
never invoked on a `stream: true` response, and that was wrong. The phase does
run: it scans the streamed content in segments of about
`response_buffer_size` bytes, each segment as one call to Prisma AIRS. Content
still below the threshold when the stream ends is never scanned, so a short
stream, or one that never fills a segment, can go unscanned even though the
phase ran.

Measured with the schema default (100 bytes — this repository no longer
overrides it, see [Design decisions](design-decisions.md)): a 309-character
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

**The practical consequence is larger than the tail.** Most chat answers are
shorter than one segment, so under a streaming front-end the response leg is
largely uncovered — not partially, not late: not scanned. Measured 2026-09-15
against a live tenant, reading `output_processing_latency` from the diagnostics
log:

| Answer | `response_buffer_size` | Response scanned |
|---|---|---|
| 32 characters, streamed | 100 (default) | **no** — latency 0 |
| 32 characters, streamed | 20 | **no** — latency 0 |
| 32 characters, streamed | 1 | **no** — latency 0 |
| 478 characters, streamed | 20 | yes — 551 ms |
| 32 characters, **not** streamed | any | yes — 460 ms |

So lowering `response_buffer_size` does not help: there is a floor of roughly
100 bytes before the `OUTPUT` phase runs on a stream at all, and the setting
does not reach it. The only way to scan a short answer is to stop the response
streaming — `config.response_streaming: deny` on the AI Model, or the calling
application's own non-streaming option, after which the same answer is scanned
whole in one call.

A third posture exists and is worth knowing even though this repository cannot
ship it, since its scope is configuration only: a hop in front of the gateway
that requests a non-streamed completion and re-emits it to the client as
server-sent events. The client keeps a streaming interface, every response is
scanned whole before a byte reaches it, and the price is time to first token —
nothing is shown until the model has finished and the scan has returned.

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
before it. See [Design decisions](design-decisions.md) for the two ways to
handle it.

The `OUTPUT` phase also carries no prompt context alongside the response it
scans, which is a design limit rather than a schema gap.

