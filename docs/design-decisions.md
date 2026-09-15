# Design decisions

Why the shipped configuration is shaped the way it is. Each choice below was
either forced by the plugin schema or settled by a measurement; the measurements
themselves, with their verification tags, are in
[verification-status.md](verification-status.md).

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
[`config/kongctl/airs-error-sanitizer.yaml`](../config/kongctl/airs-error-sanitizer.yaml),
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
[Streaming responses are scanned in segments](limitations.md#streaming-responses-are-scanned-in-segments),
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

