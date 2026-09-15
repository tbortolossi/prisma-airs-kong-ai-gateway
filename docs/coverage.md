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

## Control planes and formats

| | Supported | Description |
|---|:--:|---|
| AI Gateway 2.x, `kongctl` | ✅ | The primary target. Policies of type `ai-custom-guardrail` |
| Classic Gateway control plane, `deck` | ✅ | The same `config` block, wrapped as a plugin on a Service or Route |
| OpenAI `chat/completions` request bodies | ✅ | |
| Other client body shapes | ⚠️ | Still scanned, but the text falls back to `text_source` unattributed |

Every claim above with its verification tag:
[docs/verification-status.md](verification-status.md).

---
