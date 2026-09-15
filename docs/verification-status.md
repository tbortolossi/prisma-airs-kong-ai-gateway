# Verification status

Every claim this repository makes carries one of three states:

| Tag | Meaning |
|---|---|
| `DOCUMENTED` | published by Kong or Palo Alto Networks, with the URL in [sources.md](sources.md) |
| `SYNTHESIZED` | a transposition or an inference, not published anywhere |
| `LAB-VERIFIED` | applied and exercised against a live gateway, with the run recorded |

An offline unit test does not make a configuration block `LAB-VERIFIED`: it
proves the Lua is correct against the Prisma AIRS schema, not that Kong accepts
the configuration.

## Known gaps in this table

| Claim | Status | What would close it |
|---|---|---|
| The `OUTPUT` scan on a native `formats` value carries the raw upstream JSON envelope rather than the answer alone | **LAB-VERIFIED 2026-09-15, with a caveat** | Reproducing it with a provider that matches the format. The lab paired `formats: [anthropic]` with an `ollama` provider; the prompt-leg results depend only on the caller's body and stand on their own, the response-leg one does not |
| A non-`openai` `formats` value is not automatically degraded | **LAB-VERIFIED 2026-09-15**, and it corrected an inference | `anthropic` with string `content` is attributed byte for byte like `openai`; only the block-array form falls back to `text_source`. What decides it is the shape of `messages[].content`, not the format name |
| `config/deck/airs-diagnostics-log.yaml` | **SYNTHESIZED** | Apply it with `deck` on a classic control plane |
| `kong.client.get_consumer()` populates `metadata.app_user` | Reachable, never returned a value | One lab run with a key-auth consumer on the model |
| The 2026-09-15 payload work on the `deck` variant | Not re-run | The Lua is byte-identical and CI enforces that, but the deck path has not been exercised since 2026-09-14 |

Every configuration key used here, and every allowed value, comes from the
published Kong plugin schema and the Prisma AIRS OpenAPI client — see
[docs/sources.md](sources.md). The verdict functions are unit tested
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
  [Limitations](limitations.md).
- **`guarding_mode: BOTH` covers both phases in one policy**, with `$(source)`
  distinguishing them, and the two scans are sequential.
- **Streaming skips the `OUTPUT` phase entirely, with no error** — this is
  what the run measured on 2026-09-08, and the conclusion was wrong. Corrected
  2026-09-14: the phase does run on a stream, in segments; the 2026-09-08
  setup had `response_buffer_size: 65536`, which no stream in that run ever
  filled. See [Limitations](limitations.md).

Confirmed against the schema and the published examples: `guarding_mode`,
`text_source`, `params`/`request.*`/`response.*`/`functions`, `timeout`,
`ssl_verify`, `stop_on_error`, `response_buffer_size`, `allow_masking`,
`metrics`, `custom_metrics`, `request.auth`, dotted access to a function result
(`$(fn.field)`), and the `$(source)` values `INPUT` / `OUTPUT`. The plugin
instance uniqueness and route-over-service precedence behind the two-policy
design are documented on Kong's plugin entity page and in the `kong` GitHub
repository — see [docs/sources.md](sources.md).

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
  [Limitations](limitations.md).
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
  Measured behaviour is in [Design decisions](design-decisions.md); the shipped
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
  [Design decisions](design-decisions.md).

A fourth round, 2026-09-14, after PR #11 merged, settled the fail-open
behaviour, the guardrail-failure client contract, the `metrics.*` export path,
`proxy_config`, and put a concrete number on the streaming tail gap:

- **`stop_on_error: false` is fail-open on a guardrail-call failure, and only
  on that failure.** Measured against an unreachable endpoint: HTTP 200 with
  the model's answer, both phases logging the failure as an error, and
  `airs_verdict` never evaluated, since there is no guardrail response to
  evaluate. See [Design decisions](design-decisions.md).
- **Every guardrail-call failure reaches the client as HTTP 500**, whatever
  `rejection_mode`, carrying the internal error text, and on a bad-status
  failure, the guardrail's own error body relayed verbatim. `timeout` is
  honoured to the millisecond: a 5.0 s timeout produced the 500 at 5.0 s. See
  [Design decisions](design-decisions.md).
- **`metrics.*` are exported, through Kong's log serializer, not through
  Konnect's request analytics.** A `file-log` policy attached next to
  `airs-scan` carries `ai.proxy.custom-guardrail` with our exact values, and
  `ai.proxy.guardrail_triggered` alongside it; the Konnect Requests analytics
  API (`v2/api-requests`) still carries only the `ai-proxy` entry. That policy
  is shipped as `config/kongctl/airs-diagnostics-log.yaml`, writing to the data
  plane's standard output so a problem report is one `docker logs` away, with
  an `enabled` switch and the client-credential headers scrubbed out of the
  record. See [Design decisions](design-decisions.md).
- **`proxy_config` works.** `http_proxy_host` / `http_proxy_port` on
  `airs-scan`, against an `http://` guardrail URL, routed both the INPUT and
  the OUTPUT call through the forward proxy. The `https_proxy_host` /
  `https_proxy_port` pair was verified in the fifth round, below.
- **The streaming tail gap, with a number on it.** A 419-character stream was
  scanned in four segments totalling 408 characters; the last 11 characters,
  containing the word the guardrail was set to block, were never sent to
  Prisma AIRS, and the stream completed HTTP 200. See
  [Streaming responses are scanned in segments](limitations.md#streaming-responses-are-scanned-in-segments).

A fifth round, the same day, closed two of the remaining items:

- **`proxy_config` works for the https pair too.** The shipped `airs-scan`,
  against the real Prisma AIRS endpoint through a forward proxy speaking
  HTTP CONNECT: `scripts/test-airs.sh` 5/5, eleven `CONNECT` tunnels logged
  from the data plane. Proxy credentials and `no_proxy` were not exercised.
- **The verbose HTTP 500 body can be made generic with a `post-function`
  policy**, shipped as an optional file; see
  [Design decisions](design-decisions.md). `exit-transformer`, tried first, does
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
  [Streaming responses are scanned in segments](limitations.md#streaming-responses-are-scanned-in-segments).

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
  [docs/lab-classic-control-plane.md](lab-classic-control-plane.md).
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

