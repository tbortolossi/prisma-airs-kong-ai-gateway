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
| Role attribution in the scanned text | ✅ | Turns prefixed `user:` / `assistant:`, which is what keeps ordinary conversation benign |
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

This is the axis that does matter, and it affects one feature rather than
whether a scan happens. An AI Model's
[`formats`](https://developer.konghq.com/ai-gateway/entities/ai-model/) array
controls the shape callers use. `openai` is the default for every provider, and
Kong translates upstream responses into it; a native format passes the request
upstream without conversion.

The scanned text is rebuilt from `messages[]` in the caller's body, which is
what gives each turn its `user:` / `assistant:` label and what `params.tool_scan`
reads. That rebuild is OpenAI-shaped.

| `formats` | Turn attribution and `tool_scan` | Scanning itself |
|---|:--:|---|
| `openai` (default) | ✅ | Full |
| `anthropic`, `bedrock` | ⚠️ | Unaffected — falls back to `text_source`, scanned but unattributed |
| `cohere`, `gemini`, `huggingface` | ⚠️ | Unaffected — falls back to `text_source`, scanned but unattributed |

The fallback is deliberate and it is not a failure mode: when no usable string
is found in `messages[]`, `airs_contents` returns the flat `text_source` text
rather than an empty scan. Two offline assertions pin it. **A scan always
happens.** What is lost on a native format is the turn attribution — and
unattributed conversation is what gets ordinary multi-turn exchanges flagged as
prompt injection, so on a native format expect that false positive and tune the
profile for it.

> **Verification.** The fallback path itself is LAB-VERIFIED through the offline
> suite. The mapping from each native format to "no usable string in
> `messages[]`" is **SYNTHESIZED** — inferred from the vendors' own request
> schemas, where message content is an array of blocks rather than a string.
> No native format has been exercised against a live gateway. See
> [verification-status.md](verification-status.md).

