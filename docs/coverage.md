# Coverage matrix

What this integration scans, what it scans partially, and what it does not
reach. ✅ supported, ⚠️ partial — read the note, ❌ not available.

The row labels follow the ones used by
[`Kong/custom-plugin-v3`](https://github.com/PaloAltoNetworks/prisma-airs-integrations/tree/main/Kong/custom-plugin-v3)
in `PaloAltoNetworks/prisma-airs-integrations`, so the two integrations can be
compared line by line.

Every claim here with its verification tag:
[verification-status.md](verification-status.md). What the partial rows mean in
practice, with the measurements: [limitations.md](limitations.md).

## Scanning phases

| Scanning phase | Supported | Description |
|---|:--:|---|
| Prompt | ✅ | Scanned before the model is called, on every path and in every posture |
| Response | ✅ | Not streamed: one scan carrying the whole body, before the client receives it |
| Streaming | ⚠️ | Scanned in segments of about 100 bytes. An answer shorter than one segment is **not scanned at all**, and a block arrives after that segment has reached the client |
| Pre-tool call | ⚠️ | The arguments a model generates for a tool call, and optionally the `tools[]` catalogue, via `params.tool_scan`. Ships off — no `text_source` exposes them |
| Post-tool call | ✅ | Tool results scanned on return: a `role: "tool"` message is message content like any other |
| MCP | ❌ | Kong allows no guardrail on MCP traffic. The limit is Kong's — Prisma AIRS scans MCP natively |

## Which policy to attach

Exactly one per AI Model. Two are accepted and give silently degraded coverage.

| Policy | `guarding_mode` | Covers | Use when |
|---|:--:|---|---|
| `airs-scan` | `BOTH` | prompt and response | default |
| `airs-prompt-scan` | `INPUT` | prompt only | the model must stream, and you want the coverage gap stated rather than hidden |

## Additional capabilities

| Capability | Supported | Description |
|---|:--:|---|
| Fail closed on a Prisma AIRS outage | ✅ | The default. Two mechanisms covering two failure classes |
| Observe-only rollout | ✅ | `continue_on_detection` scans and records without blocking; ships commented out |
| Session and round correlation | ✅ | `session_id` and `transaction_id`, so one conversation is one AI Session. Not on streamed responses |
| Scan metadata | ✅ | Application, end user, user IP and model name, rendered in the Strata Cloud Manager transaction panel |
| Role attribution in the scanned text | ✅ | Turns prefixed `user:` / `assistant:`, which is what keeps ordinary conversation benign. Covers array-shaped `content` (assembled from its `type: "text"` parts) the same as a plain string; `image_url` / `input_audio` parts are skipped, never scanned |
| Structured evidence | ✅ | The guardrail's own record on Kong's log serializer, as an optional policy with an on/off switch |
| Regional endpoints | ✅ | One URL, the single point of change |
| Forward proxy | ✅ | `proxy_config`, http and https pairs, both exercised against the real endpoint. Ships commented out: the published schema page does not list the field yet |
| Generic body when the scan fails | ✅ | Optional policy replacing the `HTTP 500` internal text |
| DLP masking | ❌ | `allow_masking` exists in the plugin schema; not used or tested here |
| `contents[].tool_event` objects | ❌ | Prisma AIRS accepts them, but judges only the last element of `contents[]`, so one would displace the prompt |
| Per-request profile routing | ❌ | One profile per policy, by name |
| Profile selection by UUID | ❌ | The profile **name** is sent |

## Control planes

| | Supported | Description |
|---|:--:|---|
| AI Gateway 2.x, `kongctl` | ✅ | The primary target. Policies of type `ai-custom-guardrail` |
| Classic Gateway control plane, `deck` | ✅ | The same `config` block, wrapped as a plugin on a Service or Route |

## Upstream LLM providers

| | Supported | Description |
|---|:--:|---|
| Every provider Kong AI Gateway proxies | ✅ | OpenAI, Azure AI, Anthropic, Bedrock, SageMaker, Gemini, Vercel, Cohere, Hugging Face, Llama, Mistral, xAI, DashScope, Kimi, Cerebras, Ollama, Databricks, DeepSeek, vLLM |

**There is no provider list to maintain here, and that is the point of
integrating at the guardrail extension point.** `ai-custom-guardrail` runs
alongside `ai-proxy` / `ai-proxy-advanced`, after Kong has normalised the
exchange, so the guardrail never sees a provider's native wire format. A plugin
that reads the raw provider body has to parse each one and therefore publishes a
list of the ones it understands; this integration does not, because Kong has
already done that work. Adding a provider to your gateway does not change
anything here.

## Client-facing request format

This is the axis that does matter, and it affects turn attribution rather than
whether a scan happens. An AI Model's
[`formats`](https://developer.konghq.com/ai-gateway/entities/ai-model/) array
controls the shape callers use: `openai` (the default for every provider, where
Kong translates upstream responses into the OpenAI shape), `anthropic`,
`bedrock`, `cohere`, `gemini`, `huggingface`. A native format passes the request
upstream without conversion.

The scanned prompt is rebuilt from `messages[]` in the caller's body — that is
what gives each turn its `user:` / `assistant:` label and what `params.tool_scan`
reads. **What decides whether that works is the shape of `messages[].content`,
not the name of the format.**

LAB-VERIFIED 2026-09-15 against a data plane, payloads read off an echo server:

| Caller's body | Prompt scan carries |
|---|---|
| `openai`, string content | `user: … \n\n assistant: … \n\n user: …` — attributed |
| `anthropic`, **string** content | the same, byte for byte — attributed |
| `anthropic`, **block-array** content (`[{"type":"text","text":…}]`) | attributed the same way — see the fix below (LAB-VERIFIED 2026-09-15 via the Open WebUI shim path, not re-run against this `anthropic`-format lab) |

So a native format is not automatically degraded. Anthropic's Messages API
accepts `content` as a plain string, and in that form the rebuild works exactly
as it does on `openai`. The block-array form — which Anthropic, Bedrock
Converse and any multimodal payload use — was the fallback case at the time of
this lab run: `airs_contents` only read `content` as a string, so an
array-shaped turn contributed nothing, and once every turn in the conversation
was shaped that way the whole scan fell back to the flat `text_source` text.

**Array `content` is now assembled and attributed, not just a fallback.**
Since 2026-09-15, `airs_contents` reads an array `content` part by part:
`type: "text"` parts are concatenated and labelled `user:` / `assistant:`
exactly like a string turn; `image_url`, `input_audio` and other non-text
parts are skipped — they carry nothing to scan, and are never sent to Prisma
AIRS; a part shape the function does not recognise still falls back to the
full flat text, so a turn is never silently narrowed. This is also what
covers a file attachment on an `openai`-format client — Open WebUI and most
SDKs send `content` as an array once a file is attached — which is the case
that motivated the fix. LAB-VERIFIED 2026-09-15 through the Open WebUI shim
path: a benign array-content turn allowed, an injection hidden in an
array-content turn's text part blocked, and an image-only turn and a
text-plus-image turn both allowed. The attributed payload itself was not
captured on an echo server this run; see
[verification-status.md](verification-status.md) for the exact tag.

**A scan always happens.** What can still be lost is turn attribution, and
only on a content shape the function does not recognise at all, which falls
back to the flat, unattributed `text_source` text — and unattributed
conversation is exactly what gets ordinary multi-turn exchanges flagged as
prompt injection. Expect that false positive there and tune the profile for
it.

### The response leg on a native format

Measured in the same run, and it is a separate caveat. On `openai` the `OUTPUT`
scan carried the answer alone, 29 characters. On the native format it carried
the **raw upstream JSON envelope**, 388 characters — the answer wrapped in the
provider's own metadata (`model`, `created_at`, durations, token counts).

The response is still scanned, and the answer text is inside what is scanned.
But a JSON envelope is the kind of text a profile with the source-code detector
flags, so a native format raises the false-positive risk on the response leg as
well as on the prompt leg.

> **Verification limit.** This lab paired `formats: [anthropic]` with an
> `ollama` provider, which is a lab convenience rather than a realistic
> deployment. The prompt-leg results depend only on the body the caller sends
> and stand on their own. The response-leg result is consistent with Kong
> documenting that a native format passes upstream without conversion, but it
> has not been reproduced against a matching provider.
