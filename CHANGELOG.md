# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Optional tool-call scanning, `params.tool_scan`.** Tool definitions and the
  arguments a model generates for a tool call are absent from `$(content)` under
  every `text_source` (LAB-VERIFIED 2026-09-08), so a tool call was scanned only
  on its way back in, as the text of its result. `airs_contents` can now rebuild
  the scanned text from `kong.request.get_body()` and append them:
  `calls` adds the arguments of each tool call, `catalogue` also prepends the
  `tools[]` declaration, and any other value — including the shipped default,
  which is the key commented out — leaves the payload exactly as it was.
  LAB-VERIFIED 2026-09-14 against a live tenant with the guardrail in `INPUT`
  mode, so only the prompt leg could act: a conversation whose injection sat
  solely inside a tool call's arguments was allowed 5/5 with the setting off and
  blocked 5/5 with it on. `scripts/test-airs.sh` passes 5/5 either way.
  Caution recorded in the guide: a JSON parameter schema reads as source code to
  a profile with that detector on, so `catalogue` will be flagged until the
  profile is tuned.
- **`metadata` now carries `ai_model`, `user_ip` and `app_user`** alongside
  `app_name`, built by a rewritten `airs_metadata`. `app_user` prefers the
  authenticated Kong consumer and falls back to the request header named by the
  new `params.user_header`; that header is caller-controlled, so it labels a
  scan and never authenticates one. `user_ip` is the address Kong considers the
  client's, which is `X-Forwarded-For` only when the peer is in the data plane's
  `trusted_ips`. Fields that cannot be built are omitted.
  This closes what the repository had recorded as impossible for a
  configuration-only deployment.
- **`params.context_messages`**, an optional cap on how many of the most recent
  conversation parts are assembled when `tool_scan` is on.
- 39 more assertions (110 total): 14 on the tool scanning, 11 on
  `airs_metadata`, 15 on `airs_correlation`, with `kong` and `ngx` stubbed.
  `scripts/run-lua-tests.sh` now enforces byte-identical copies of
  `airs_correlation` and `airs_metadata` as well.

- **Correlation identifiers in the scan payload.** `config/kongctl/airs-guardrail.yaml`
  and `config/deck/airs-guardrail.yaml` now send `transaction_id` and
  `session_id` on every scan, built by a new `airs_correlation` guardrail
  function. The identifiers nest: `transaction_id` is one **round** — a prompt
  and the response it produced — and defaults to Kong's request id, the value
  the client receives as `X-Kong-Request-Id`, so the `INPUT` and `OUTPUT` scans
  of one exchange carry the same value and Strata Cloud Manager shows one
  exchange instead of two unrelated entries. `session_id` is the
  **conversation** grouping several rounds; nothing in the gateway knows where
  a conversation begins, so it is taken from the `x-airs-session-id` request
  header and falls back to the round. Both header names are `config.params`
  entries (`session_header`, `transaction_header`) so they can be pointed at
  whatever header an application already sends. Headers that are empty, longer
  than 256 characters, not a string, or absent are ignored.
  `tr_id` is deliberately not sent: measured against a live tenant it is the
  older name of `session_id`, not of `transaction_id`, so the round value would
  land in the session slot.
  This reverses a statement carried since 0.2.0. The repository claimed no
  guardrail function could reach a per-request value and that correlation
  required the roadmap's sidecar. That conclusion came from probing which
  names the plugin accepts as injected ARGUMENTS; the function body has the
  full Kong PDK. LAB-VERIFIED 2026-09-14: `kong.ctx.shared` carries a value
  from the `INPUT` phase to the `OUTPUT` phase, the payloads reaching a lab
  echo server carry matching round identifiers across both phases and one
  session identifier across two rounds, the live Prisma AIRS tenant accepts
  the new fields (`scripts/test-airs.sh` 5/5), and the Strata Cloud Manager AI
  Sessions view renders two rounds sent under one session header as one
  session holding two transactions of two scans each.
- README: a "TL;DR — install and configure" section replacing the old Quick
  start. The three steps that actually matter (the key on the data planes, two
  `params` values, apply-attach-validate), a table of every optional `params`
  key with what it turns on, the two optional add-on policies, and what each
  HTTP status means to the client.
- 15 assertions for `airs_correlation` in `scripts/test-verdict-functions.lua`,
  with `kong` and `ngx` stubbed, and `scripts/run-lua-tests.sh` now enforces
  that the function is byte-identical across both config files and all four
  guardrail instances. Two of the assertions exist for the fail-open case
  below: the function must never raise, and must never produce an empty
  string.

- `config/kongctl/airs-diagnostics-log.yaml` and
  `config/deck/airs-diagnostics-log.yaml`: an optional `file-log` policy that
  writes Kong's log serializer record — the guardrail verdict, the block
  category and detections, the block direction, the per-phase scan latency,
  and `request.id` — to the data plane's standard output, so that reporting a
  problem is a single `docker logs` / `kubectl logs`. Without a logging policy
  none of that leaves the data plane: the Konnect Requests analytics view
  carries the `ai-proxy` entry only, and the access log carries the status and
  request id but no guardrail detail. `config.enabled` is the on/off switch;
  the policy ships enabled, since a log that is off cannot explain an incident
  that has already happened. `custom_fields_by_lua` removes `Authorization`,
  `x-api-key`, `apikey`, `Cookie` and `Set-Cookie` from the record, because
  Kong's serializer includes request and response headers.
  The kongctl variant is LAB-VERIFIED 2026-09-14 on Kong AI Gateway 2.0.3 /
  Kong Gateway 3.14.0.3 against the live Prisma AIRS tenant: a record per
  request on the allowed and on the blocked case, the three credential headers
  absent from the record and their values nowhere in it, and `enabled: false`
  re-applied producing no record with traffic unaffected. The deck variant is
  SYNTHESIZED from it; the classic control plane used for the previous round
  had already been torn down.
- `docs/deployment-guide.md`, "Collecting diagnostics": how to attach the
  policy (one `kongctl apply` with a `-f` per file, so `!ref` resolves across
  them), what to send when opening a case, and the instruction to read one
  captured record before handing the procedure to an operator.
- Step 6 of the guide now says to attach the diagnostics log from the first
  pilot model and leave it on for the rollout.

### Fixed

- **Ordinary multi-turn conversation was being blocked as prompt injection.**
  `text_source` joins message content with no indication of who said what, so
  the model's own previous answer arrived inside the prompt unattributed and
  read as an assertion planted there. Measured on a live tenant: "What is the
  capital of France? / The capital of France is Paris. / And Italy?" blocked
  3/3 as `agent` + `injection`, and the threat report's `pi` snippet was exactly
  that concatenation. `airs_contents` now rebuilds the scanned text from the
  request body with each turn prefixed `user:` or `assistant:`; the same
  exchange is benign 3/3 through the gateway, an injection still blocks whether
  it is the newest turn or an earlier one, and `scripts/test-airs.sh` stays 5/5.
  The system message is deliberately not prefixed: writing `system:` into
  scanned text is the shape of a system-prompt spoof and gets the whole
  conversation blocked, while the same content unlabelled is benign. Tool
  results and unrecognised roles are unlabelled for the same reason. Where the
  request body cannot be read, the text falls back to the `text_source`
  selection exactly as before.
- **Prisma AIRS judges only the LAST element of `contents[]`**, and this
  repository's own reading of the schema said otherwise for part of one working
  session. Measured against a live tenant: an injection sent alone blocks; the
  same injection as the first of two elements, or the first of three, comes back
  `allow` / `benign`; sent as the last element it blocks again; sent inside a
  single element together with benign text — the shape that has always shipped —
  it blocks. An intermediate version of `airs_contents` written the same day
  split the conversation into one element per message, which reads like the
  schema's wording and would have silently stopped scanning every turn but the
  newest. It never left the working tree. The shipped function returns one
  element, and the offline suite now pins that shape: a change that returns
  several elements fails four assertions.
  The same finding bounds `contents[].tool_event`, which a live tenant does
  accept and flag (`ecosystem` must be `mcp` and `method` one of `tools/call`
  or `tools/list`; anything else is refused with HTTP 400): a tool event is
  only judged when it is the last element, which would displace the prompt. One
  scan judges one thing, so the shipped configuration puts tool text inside the
  scanned element instead. Recorded in `docs/sources.md`.
- Two behaviours of `ai-custom-guardrail` that make a guardrail function
  dangerous if they are not known, both LAB-VERIFIED 2026-09-14 and both now
  documented in `CLAUDE.md` under "Technical constraints to respect".
  **An unguarded Kong PDK call is a silent fail-open on a streamed response**:
  on the `OUTPUT` path of a stream the function runs with no request context,
  and a raise there skips the guardrail call for that segment instead of
  failing the request. Measured on one streamed request with the same policy:
  a function returning a constant gave 7 `OUTPUT` segment scans, the same
  function calling `kong.request.get_header` unguarded gave zero with HTTP 200
  and the stream delivered whole, and the `pcall` version gave 7 again.
  **An empty string in `request.body` is rendered as JSON `false`**, not as an
  empty value: a field the function cannot build must be `nil`, which the
  plugin omits from the payload.
  Verified on the streamed path after both changes above: the `OUTPUT` segments
  are still scanned, seven of them on a 700-character stream, with the payload
  and the metadata falling back rather than the scan being skipped.
- The Prisma AIRS correlation identifiers were documented the wrong way round
  in this repository for part of one working session, and `docs/sources.md`
  now carries the measured behaviour. `transaction_id` is the round, not the
  session grouping key; `session_id` is the conversation; and `tr_id` is the
  older name of `session_id`, which is why it is no longer sent at all. The
  AI Sessions page's phrase "calls sharing the same transaction ID" is looser
  than the endpoint reference and than what the API actually does.
- The example log record in `docs/deployment-guide.md` showed
  `input_processing_latency` and `output_processing_latency` as `0`. They are
  not: the round-four capture that produced those zeros ran against a local
  echo server answering in under a millisecond. Against the real Prisma AIRS
  endpoint they carry the scan cost on every request, allowed included — 632 ms
  and 454 ms measured — which makes the record the place to answer a complaint
  about latency rather than a block. README, Verification status, says so too.
- `docs/deployment-guide.md` claimed "Kong data plane logs remain a third place
  a block is visible". The access log shows the status and `kong_request_id`
  only; the guardrail detail is not there without a logging policy. Reworded.

### Changed

- **The README's coverage matrix uses the same taxonomy as the other Kong
  integration.** `PaloAltoNetworks/prisma-airs-integrations` `Kong/custom-plugin-v3`
  names its scanning phases Prompt / Response / Streaming / Pre-tool call /
  Post-tool call, and carries a separate capabilities table and a "which flavour
  to deploy" table. This README now uses the same row labels and the same three
  tables, so the two integrations can be compared line by line rather than
  translated. "Which policy to attach" is the local equivalent of the flavour
  table: `airs-scan` against `airs-prompt-scan`, one per AI Model.
- **The README leads with a coverage matrix.** Following the shape used by the
  other integrations in `PaloAltoNetworks/prisma-airs-integrations` (the Azure
  APIM assets in particular), the first thing on the page is now three tables
  saying what is supported, what is partial and what is not: scanning phases,
  features, control planes and request formats. Everything carries a note, and
  the honest entries are there too — masking, `tool_event` objects and profile
  selection by UUID are not available, streamed response scanning and tool-call
  scanning are partial.
- **The README is an entry point again, not a manual.** It was 975 lines, most
  of it reference material a reader had to scroll past to find the install
  steps. Now 281: what it is, a TL;DR that states plainly what has to be done,
  the limitations as a table, and a map of where the detail lives. Three new
  documents carry what moved, unchanged in substance —
  `docs/limitations.md`, `docs/design-decisions.md` and
  `docs/verification-status.md`.
- `docs/limitations.md` records a measurement the README never stated plainly:
  a streamed answer shorter than one `response_buffer_size` segment is not
  scanned at all, and lowering the setting does not help — 32 characters
  streamed records `output_processing_latency: 0` at buffer 100, at 20 and at 1,
  while the same answer sent non-streamed records 460 ms. Most chat answers are
  shorter than a segment, so this is the common case rather than an edge case.

- `config/deck/airs-guardrail.yaml` and `config/deck/airs-error-sanitizer.yaml`
  are LAB-VERIFIED: applied with deck to a Konnect classic control plane with a
  `kong/kong-gateway:3.14.0.14` data plane, the model target pointed at a
  local model. `scripts/test-airs.sh` 5/5 twice, `stream: true` refused on
  the service route, the streaming route streaming with its route-level
  `airs-prompt-scan` blocking a malicious prompt, the `OUTPUT` phase blocking
  a flagged response, and the sanitizer turning the outage HTTP 500 into the
  generic body. Procedure in `docs/lab-classic-control-plane.md`.
- `scripts/test-airs.sh`, case 5 asks for an answer in prose. Measured: one
  run in eight was blocked on the response leg with category `source_code`
  because the model answered with a code snippet; five consecutive runs pass
  with the new wording. The comment says what a block on that case means.

### Added

- Measured behaviour at the Prisma AIRS payload limit: Kong forwards the
  whole scanned text (3.58 million characters, no truncation); a 2.05 MB
  prompt is scanned; a 3.5 MB one gets HTTP 413 from Prisma AIRS, turned into
  a fail-closed HTTP 500 in 1.2 s. README, guide (`text_source` trade-off
  and a troubleshooting row), `docs/sources.md` and `CLAUDE.md`.
- Concurrency check: twenty parallel requests with distinct markers produce
  twenty prompt and twenty response scans with no payload mixing, and twenty
  parallel requests on the live tenant with every third one malicious get
  the right verdict each. README, Verification status.
- `docs/lab-classic-control-plane.md`.

### Changed

- Streaming posture is now presented as two modes, one line apart on the AI
  Model. Simple mode, the default: `airs-scan` on every model with
  `response_streaming` left at `allow`; non-streamed responses scanned whole
  before delivery, streamed responses scanned per segment on a best-effort,
  detect-after-delivery basis. Strict mode: `response_streaming: deny` on
  models where no unscanned character may reach the client, `airs-prompt-scan`
  on models that must stream. The kongctl attachment example now shows the
  `deny` line commented, as the strict option.
- Measured what a stream leaks before a block, with a guardrail blocking every
  segment on a local model at about 450 characters per second: with a 3 s
  verdict latency the whole 1005-character answer was delivered and the
  stream ended normally; with 0.5 s about 320 characters; with 0.05 s about
  120. The per-segment scans are asynchronous and do not slow the stream
  (2.3 s with nine 0.5 s scans against 2.2 s without a guardrail), which is
  why they cannot hold it back. README, guide and `docs/lab-streaming.md`
  carry the numbers and the rule of thumb: output rate times scan latency,
  plus one segment.

### Changed

- The terminal chunk of a blocked stream is driver-dependent, measured
  2026-09-14 on the same local model through two drivers: the `ollama`
  driver cuts the stream with no `finish_reason` chunk, as every earlier
  round saw; the `openai` driver ends it with a chunk carrying
  `finish_reason: "blocked_by_guard"` and the generic block message, then
  `data: [DONE]`, and under `rejection_mode: verbose` a `guardrail_result`
  object without category or detection. README, `docs/deployment-guide.md`,
  `docs/lab-streaming.md` and `CLAUDE.md` no longer describe the cut as the
  only behaviour, and the item leaves "What remains unconfirmed"; what
  remains is the behaviour of the other drivers.
- Lab note: for the `openai` driver, a target's `upstream_url` is the full
  endpoint URL (`.../v1/chat/completions`); a base URL answers 405 and a
  base URL ending in `/v1` answers 404 from the model server. The `ollama`
  driver takes a base URL.

### Added

- `config/kongctl/airs-error-sanitizer.yaml`, an optional `post-function`
  policy that replaces the verbose `HTTP 500` body returned when Prisma AIRS
  cannot be consulted with `{"error":{"message":"Guardrail unavailable"}}`,
  leaving blocks, allowed responses and streams untouched (measured
  2026-09-14). `config/deck/airs-error-sanitizer.yaml` is the classic
  control plane transposition, not exercised. `exit-transformer` was tried
  first and does not intercept that response.
- CI refuses an uncommented `stop_on_error: false` or
  `continue_on_detection: true` under `config/`, next to the existing
  `guarding_mode` guard, and `scripts/check-plugin-schema.py --parity` now
  parses every YAML under `config/`, so the optional files are checked too.

### Changed

- `proxy_config` is verified for both pairs: the https pair carried the
  supplied configuration to the real Prisma AIRS endpoint through an HTTP
  CONNECT proxy with the validation suite passing. README, guide,
  `docs/sources.md` and both configuration file comments updated.
- README and `docs/deployment-guide.md` no longer describe the verbose
  `HTTP 500` body as not configurable; they point at the optional sanitizer.
- README, "What remains unconfirmed": the `finish_reason: 'blocked_by_guard'`
  item now records that an OpenAI-driver model could not be brought up in the
  lab (plain-text 404 from the data plane), so the driver hypothesis is
  untested; the Konnect item is narrowed to the UI views fed by the AI
  Gateway request-log channel.

### Changed

- README: the "community assets, not an official Palo Alto Networks or Kong
  product" statement now also appears under the opening paragraph, not only in
  the `Disclaimer` section at the foot of the page. The repository is public and
  carries a personal copyright; a reader arriving from a link should not have to
  scroll past four hundred lines to learn that neither vendor supports it. The
  `Disclaimer` section itself is unchanged.
- `docs/deployment-guide.md`: the **Outcome** line claimed that every prompt and
  every response transiting the gateway is scanned. That is false for a streamed
  response, as the same document already said nine sections further down. It now
  states the streaming exception where the reader decides whether the deployment
  meets the requirement.
- `docs/deployment-guide.md`: dropped the section numbers from the headings. They
  ran one to eleven while the procedure runs Step 1 to Step 6, so "section 5" and
  "Step 3" named the same place. The step headings keep their own numbering, which
  is the one the text cross-references.
- `docs/sources.md`: the `ScanRequest` and `ScanResponse` property lists were
  incomplete. Both models carry three optional correlation identifiers —
  `tr_id`, `session_id` and `transaction_id` — and none of them is deprecated.
  Added, together with a reference to Palo Alto Networks' AI Sessions page,
  which is what explains why they matter: sessions group API calls sharing the
  same transaction ID, and AIRS generates one per atomic call when none is
  supplied.
- `scripts/lab-echo-server.py`: reports all three correlation identifiers and
  echoes them back, instead of echoing a `tr_id` that no configuration in this
  repository sends. A lab run now shows their absence rather than hiding it.
  Its header also still instructed the operator to blank `params.api_key`,
  which has not existed since the credential moved to `request.auth` in 0.3.0.

### Added

- README: an `IMPORTANT` callout above the fold stating that `stream: true`
  silently bypasses response scanning. The finding was already documented in
  *Scope and limits* and in *Design decisions*, but only for a reader who got
  that far — it belongs where deployment scope is decided, not where it is
  verified. Corrected 2026-09-14 — see *Fixed*, below.
- `docs/deployment-guide.md`: a "Scan correlation" operational consideration and
  a matching troubleshooting row, stating that no correlation identifier is sent
  and what that means when reading the Prisma AIRS scan logs — the two scans of
  one exchange are not linked, and the AI Sessions view groups nothing. Blocking
  and profile tuning are unaffected.

### Known gap

- The guardrail sends no correlation identifier to Prisma AIRS, so the prompt
  scan and the response scan of the same exchange are not linked in the scan
  log and the AI Sessions view groups nothing. This cannot be fixed in
  configuration: a guardrail function receives only `source`, `content`, `conf`
  and `resp`, so any value it could produce would either be constant across all
  traffic or differ between the two phases. It is part of the v0.5 sidecar
  scope, for the same reason as `metadata.app_user` and `metadata.ai_model`.

### Fixed

- `docs/lab-tool-calls.md` still told the reader to neutralise `params.api_key`
  before pointing the policy at the echo server. Since 0.3.0 the credential is
  `request.auth.value`, so following the procedure as written would have sent
  the real Prisma AIRS token to the lab listener. The procedure now replaces
  `request.auth.value`, and its stale "block code never observed" bullet now
  states the verified HTTP 400.
- `scripts/lab-tool-call-probe.sh` passed the client credential as a curl `-H`
  argument, visible in the process list. It now uses the same curl config file
  as `scripts/test-airs.sh`. Both scripts also JSON-escape `MODEL_NAME`.
- CI: a failure to fetch the published plugin schema (exit 3) is reported as a
  warning on push and pull request, where the parity and Lua checks still gate
  the change, and fails only the weekly cron, whose purpose is that fetch.
- Comments in both configuration files still called the raising-function case
  `SYNTHESIZED` and described streaming as a buffering nuance. Both now carry
  the lab findings: HTTP 500 independent of `stop_on_error`, and an OUTPUT
  phase that is never invoked under `stream: true` (this second point was
  itself corrected 2026-09-14 — see below).
- `docs/sources.md` now cites the Request Callout plugin page for the
  "Kong Gateway 3.10+" note in the deployment guide.

### Added

- Eight offline assertions on the `cjson.safe` branch of `airs_verdict`:
  `require` raising, `require` raising a table shaped like an allow verdict,
  a module without `decode`, and `decode` returning a non-table all fail
  closed with the generic message, against both verdict copies. 63 assertions
  in total, up from 55.
- `requirements-dev.txt` pins PyYAML for `scripts/check-plugin-schema.py`; CI
  installs from it and Dependabot now tracks the `pip` ecosystem.

### Changed

- `scripts/lab-echo-server.py` takes its request counter under a lock, so two
  concurrent requests can no longer share a `scan_id`.
- `scripts/test-airs.sh` and `scripts/lab-tool-call-probe.sh` reject a
  `CLIENT_KEY` containing a newline before writing the curl config file.
- `scripts/run-lua-tests.sh` pins its Docker fallback image to a digest.
- Comments only: the `metrics` blocks in both configuration files state the
  split between `block_reason` (generic message with `scan_id`, for
  correlation) and `block_detail` (category and detections), and `CLAUDE.md`
  describes that wiring rather than a looser one. The deck file notes that the
  `ai-proxy-advanced` header value must carry its own `Bearer ` prefix.

### Fixed

- **The streaming statement was wrong, and the error was this repository's
  own.** README, both configuration files, and the guide all said Kong never
  invokes the `OUTPUT` phase on a `stream: true` response. Measured again
  2026-09-14: the phase does run on a stream, in segments of about
  `response_buffer_size` bytes — a 309-character stream produced three
  `OUTPUT` calls (101 / 104 / 103 characters) at the schema default of 100.
  What the 2026-09-08 run actually measured was the effect of
  `response_buffer_size: 65536`, set in both `config/kongctl/airs-guardrail.yaml`
  and `config/deck/airs-guardrail.yaml`: no stream in that run ever
  accumulated 65536 bytes before ending, so the threshold was never crossed.
  Both configuration files drop the field, letting the schema default apply.
  README corrected throughout: the `IMPORTANT` callout, *Scope and limits*,
  *Design decisions*, and *Verification status*.
- `metrics.block_detail: "$(airs_verdict.detail)"` evaluated to a string. The
  data plane logged a warning on every single request, allowed or blocked, in
  both phases — `metric input_block_detail has unexpected type string,
  expected table` — which is the likely reason nothing guardrail-related was
  ever seen on the metrics endpoint. `airs_verdict` now returns `detail` as a
  table, `{ reason, category, detections }`, in both configuration files; the
  warning is gone, measured over the same request set. `block_message` is
  unchanged.
- The header comments in both `config/kongctl/airs-guardrail.yaml` and
  `config/deck/airs-guardrail.yaml` still described the old streaming and
  `block_detail` behaviour. Corrected to match the two fixes above.

### Changed

- `response_buffer_size` is no longer set in either policy; the schema default
  (100) applies. It only affects a streamed response — a non-streamed one is
  always scanned in one call regardless of the value.
- `airs_verdict`'s `detail` return value is now a table,
  `{ reason, category, detections }`, instead of a string. This changes what
  `metrics.block_detail` carries; it does not change `block_message`, the
  fixed generic text returned to the client.
- The kongctl attachment example adds `config.response_streaming: deny`
  alongside `!ref airs-scan`. The deck variant sets `response_streaming: deny`
  on the service-level `ai-proxy-advanced` and gives the streaming route a
  route-level `ai-proxy-advanced` with `response_streaming: allow`, next to
  `airs-prompt-scan` — the same route-over-service precedence the file already
  relied on for the guardrail policies themselves.
- `scripts/test-airs.sh` gains a streaming probe that reports what it observes
  but asserts nothing, so a still-open question (whether a blocked stream ever
  carries a `finish_reason: 'blocked_by_guard'` terminal chunk) does not fail
  the suite.
- README: *Why this exists* now names the v2 catalogue's partner guardrails —
  `ai-aws-guardrails`, `ai-azure-content-safety`, `ai-gcp-model-armor`,
  `ai-lakera-guard`, and NVIDIA NeMo Guardrails since AI Gateway 2.0.1 — and
  states that the custom Lua plugin path is closed by the Konnect control
  plane rejecting a `prisma-airs-intercept` policy type, not by the data plane
  runtime, which is Kong Gateway 3.14.0.3 underneath the AI Gateway 2.0.3
  label. *Related* now points at the `custom-plugin-v3` flavours of Palo Alto
  Networks' integration assets, which now cite this repository as the AI
  Gateway 2.x reference.

### Added

- Both configuration files gain commented-out lines for `rejection_mode`,
  `continue_on_detection` and `log_blocked_content` — present on a 2.0.3 data
  plane, absent from the published schema page, so shipping them uncommented
  would fail `scripts/check-plugin-schema.py --schema` until Kong publishes
  the field. Measured: `rejection_mode: verbose` returns HTTP 403 with a
  structured `GUARDRAIL_BLOCKED` body; `stealth` returns HTTP 403 and drops
  the `scan_id`; `continue_on_detection: true` turns a block into HTTP 200
  while still calling the guardrail, a monitoring mode for a pilot.
- `docs/lab-streaming.md`, a lab procedure for whether a streamed response is
  scanned, and how.
- New offline assertions covering the table-shaped `detail` return value.

### Known gap

- On a streamed response, the segment that trips a detection has already
  reached the client before the block takes effect; only what follows it is
  prevented. Content still below `response_buffer_size` when the stream ends
  is never scanned. The `finish_reason: 'blocked_by_guard'` terminal chunk the
  schema text describes has still not been observed.

### Fixed

- README ("Design decisions > Fail closed by default...") and
  `docs/deployment-guide.md` ("Fail-closed behaviour") both said that
  switching to fail-open required changing `stop_on_error` and the Lua
  verdict branches together, and that either change alone still blocked.
  Measured against an unreachable guardrail endpoint: `stop_on_error: false`
  alone returns HTTP 200 with the model's answer, unscanned, while both
  phases log the failure as an error. The two mechanisms cover two different
  failures: a failed call to Prisma AIRS, and a successful call with an
  unusable verdict, not one shared switch.
- README (Verification status) no longer carries "whether `metrics.*`
  templates are exported to Konnect's own AI analytics view" as unconfirmed.
  They are exported through Kong's log serializer, as
  `ai.proxy.custom-guardrail.*` and `ai.proxy.guardrail_triggered`, verified
  with a `file-log` policy attached next to `airs-scan`. Konnect's own
  Requests analytics API (`v2/api-requests`) still carries only the
  `ai-proxy` entry; only the Konnect UI dashboards remain unchecked.

### Changed

- README (the "Generic block message" paragraph) and
  `docs/deployment-guide.md` ("Observability"): both now point at attaching a
  logging policy (`file-log`, `http-log`, ...) and reading
  `ai.proxy.custom-guardrail.*`, replacing the earlier "export to Konnect
  analytics still unconfirmed" statement. The Prisma AIRS scan log in Strata
  Cloud Manager remains the record for detection detail.
- The `proxy_config` comment in both `config/kongctl/airs-guardrail.yaml` and
  `config/deck/airs-guardrail.yaml` now says verified, for an `http://`
  guardrail URL through a forward proxy, rather than untested.
- `scripts/test-airs.sh`'s closing note now states the expected HTTP 500 on a
  guardrail outage.

### Added

- README: a measured failure-mode table under "Fail closed by default"
  (unreachable endpoint, a 5.0 s timeout, a guardrail HTTP 500, and a
  non-JSON guardrail body), all HTTP 500 to the client carrying the internal
  error text, the guardrail's own body relayed verbatim on the HTTP 500 case,
  and `rejection_mode` shown to have no effect on any of them.
- README and `docs/lab-streaming.md`: the streaming tail-gap example, a
  419-character stream scanned in four segments totalling 408 characters, the
  last 11 characters (the word that would have blocked the response) never
  sent to Prisma AIRS, the stream completing HTTP 200.

### Known gap

- A guardrail-call failure returns the internal error text to the client, and
  on a bad-status failure relays the guardrail's own error body verbatim; this
  is not configurable. The 500 body discloses that a guardrail step exists and
  how it failed.
- `finish_reason: 'blocked_by_guard'` still not observed on a blocked stream.

## [0.3.0] — 2026-09-08

Second lab round on the same gateway, closing every question the first one left
open. One configuration change follows from it.

### Changed

- **The Prisma AIRS credential moves to `request.auth`.** `location: header`,
  `name: x-pan-token`, `value: "{vault://env/airs-token}"`, replacing
  `params.api_key` plus a `$(conf.params.api_key)` interpolation. Verified
  against a live tenant: `scripts/test-airs.sh` passes 5 of 5. Two reasons this
  is not cosmetic — `request.auth.value` is stored encrypted, which a
  `config.params` value is not, and the key disappears from the `conf` table
  that guardrail functions receive.
- README and `docs/deployment-guide.md`: attaching two `ai-custom-guardrail`
  policies to one AI Model is **accepted** by AI Gateway 2.x, contrary to what
  this repository stated. Coverage does not stack — only one executes — and it
  is not the one declaration order suggests: with both attached, the `INPUT`
  policy ran while the model listed `airs-scan` first. The deck side still
  rejects the second instance at apply time. Attach exactly one, and verify with
  `GET /v1/ai-gateways/<id>/models`.
- README and `docs/deployment-guide.md`: the guardrail's `metrics.*` fields are
  no longer presented as a reliable record. They apply, but nothing
  guardrail-related appears on the data plane's metrics endpoint, including with
  a `prometheus` policy and `ai_metrics: true`, whose AI families are LLM
  request, cost and token counters. The Prisma AIRS scan log in Strata Cloud
  Manager, correlated by `scan_id`, is the channel to rely on.
- The comment above the verdict's string-decoding branch now explains why it is
  kept rather than deleted as dead code: `require` and `cjson.safe.decode` were
  verified to work inside a guardrail function, so the branch is live cover if a
  Kong release ever passes `$(resp)` as a string — and without it, such a
  release would fail every request closed.

### Added

- README, Verification status: the injectable parameter set. Only `source`,
  `content` and `conf` are accepted in a guardrail function; `resp` is accepted
  but empty on the request side; every other name tried is rejected with
  *argument '<name>' is not allowed in guardrail functions*. Consequence for
  anyone planning to enrich the Prisma AIRS `metadata` object: the Kong consumer
  identity and the model name are unreachable from configuration alone.
- README, Verification status: a guardrail function that raises fails the
  request closed with HTTP 500, independently of `stop_on_error` — and its Lua
  error text reaches the client, so an `error()` message must not carry anything
  sensitive.

## [0.2.0] — 2026-09-08

**First live-gateway run, 2026-09-08.** Konnect AI Gateway 2.x control plane,
one self-managed data plane (`kong/kong-ai-gateway:2.0.3`, Kong Gateway
3.14.0.3-enterprise), a local Ollama as the model, a live Prisma AIRS tenant.
`scripts/test-airs.sh`: 5 of 5 cases matched. Six previously unverified
statements are now measured, and one of them was a defect that made the shipped
configuration unusable.

### Fixed

- **The guardrail never ran.** `request.body.contents` referenced its function as
  `$(airs_contents(source, content))`. That form is not valid: the data plane
  answers HTTP 500, *failed to render by function: invalid expression syntax*,
  and no request reaches the model. Functions must be referenced bare, `$(fn)`;
  the plugin injects the built-ins **by parameter name**, rejecting any other
  name with *argument 'a' is not allowed in guardrail functions*. The function
  signatures were already correct, so the fix is the reference itself, applied to
  both `config/kongctl/` and `config/deck/`.

### Changed

- README and `docs/deployment-guide.md`: **streaming does not degrade response
  scanning, it removes it.** With `stream: true` the `OUTPUT` phase is never
  invoked — a guardrail service answering `action: block` for everything received
  no call at all, and the complete SSE stream reached the client with HTTP 200,
  while the same policy blocked the non-streamed request with 400. No error is
  raised, so a client opts itself out of response scanning by setting one flag.
  The previous text, which inferred chunked buffering from `response_buffer_size`,
  is withdrawn.
- README: tool calls on the LLM path are no longer "not confirmed". `$(content)`
  carries message content only, joined by `\n\n` in reverse chronological order.
  Tool definitions and generated tool-call arguments are never scanned, under any
  `text_source`; `role: "tool"` results are, under `concatenate_all_content`.
- README and `docs/deployment-guide.md`: a block returns **HTTP 400** with the
  body `{"error":{"message":"..."}}`. That is now stated as the client contract.
- README and `docs/deployment-guide.md`: measured latency replaces the previous
  qualitative warning. Median end to end, EU data plane against the global AIRS
  endpoint, upstream model answering in ~30 ms: 73 ms with no policy, 577 ms with
  `airs-prompt-scan` (one scan), 876 ms with `airs-scan` (two sequential scans).
  The plugin itself costs about 3 ms; the rest is the round trip to Prisma AIRS,
  which makes a regional endpoint the main latency lever.
- README, Verification status: `$(resp)` is a Lua table in both phases, `OUTPUT`
  included, so the defensive `cjson.safe` decode is dead code. Left in place for
  now, because removing it also means rewriting the assertions that cover it.

**Breaking change to policy names and layout.** The two-policies-by-direction
layout (one `INPUT` policy plus one `OUTPUT` policy attached together to the
same model) is gone. `airs-response-scan` no longer exists. `airs-prompt-scan`
keeps its name but is now the `INPUT`-only variant meant specifically for
streaming models, attached alone. A new policy, `airs-scan`
(`guarding_mode: BOTH`), covers prompt and response together and is the default
choice for non-streaming models. Exactly one of `airs-scan` /
`airs-prompt-scan` is attached per AI Model (kongctl) or per scope (deck) — see
Fixed, below, for why attaching two no longer works and never reliably did.

### Added

- README: a **Scope and limits** section. MCP traffic is out of scope, with the
  reason sourced from Kong — `ai-mcp-proxy` lists guardrails on MCP requests and
  responses as unsupported and forbids chaining with other AI plugins on the same
  Service or Route, and the AI MCP Server entity accepts no guardrail policy. The
  same section records that the limit is Kong-side only: Prisma AIRS API
  Intercept already scans MCP through `contents[].tool_event`.
- README: tool calls on the LLM path are declared unconfirmed rather than
  implied. Whether `$(content)` carries `tools[]`, `tool_calls[].function.arguments`
  and `role: "tool"` results is now an item under Verification status.
- `docs/sources.md`: the AI MCP Proxy plugin and AI MCP Server entity pages as
  the source of the scope boundary, and the Prisma AIRS MCP threat detection and
  MCP Server pages.
- `scripts/lab-echo-server.py`, `scripts/lab-tool-call-probe.sh` and
  `docs/lab-tool-calls.md`: a lab procedure that settles whether function calling
  is scanned. The echo server stands in for the Prisma AIRS endpoint, logs the
  payload the policy actually emits, and reports which of five marked positions —
  system message, user message, tool definition, tool call arguments, tool result
  — reached the scanned text. Standard library only, no dependency to install.
  The same run also exposes the emitted `contents` object, so it can confirm the
  explicit-argument call form and the HTTP status returned on a block.
- `airs-scan` policy (`guarding_mode: BOTH`): scans the prompt in its `INPUT`
  phase and the model output in its `OUTPUT` phase from a single policy, using
  `$(source)` to pick `contents[].prompt` versus `contents[].response`.
- `scripts/check-plugin-schema.py`, run in CI: `--parity` fails the build if
  `config/kongctl/airs-guardrail.yaml` and `config/deck/airs-guardrail.yaml`
  carry a different `config` block for a given guardrail instance; `--schema`
  fails the build if any config key, or any enum value, is not present in the
  live published `ai-custom-guardrail` schema.
- 38 more offline assertions (55 total, up from 17): the verdict cases now run
  against both `airs-scan` and `airs-prompt-scan`'s copies of `airs_verdict`
  rather than one, a `cjson.safe` stub exercises the string-decode branch of
  `$(resp)` for real, and 7 new cases cover `airs_contents`, including that it
  raises rather than accepts a non-string `content`.
- `docs/sources.md`: the Kong plugin entity page and the `kong` GitHub
  repository (`plugins.lua`, `000_base.lua`) as the source for plugin instance
  uniqueness and route-over-service precedence; the deck sync and deck tags
  pages; the AI Proxy Advanced reference's `auth.header_value` note; the
  kongctl README's `--pat` flag; the `request-callout` config as the source of
  the generic block body and its HTTP 403; and the Prisma AIRS API page's 2 MB
  synchronous scan payload limit.

### Changed

- README: the opening paragraph and **Why this exists** now lead with the reason
  the repository exists. Kong AI Gateway 2.x removes the custom Lua plugin path,
  so the Prisma AIRS plugin published by Palo Alto Networks cannot be deployed on
  an AI Gateway 2.x control plane, and the v2 policy catalogue carries no Prisma
  AIRS type. The nuance is kept explicit: that plugin remains valid on
  self-hosted Kong Gateway and on Konnect hybrid with a custom data plane image.
- Both config files: the two policies now differ by **coverage**
  (`airs-scan` = `BOTH`, `airs-prompt-scan` = `INPUT`) rather than by
  **direction** (one `INPUT`-only, one `OUTPUT`-only policy meant to be attached
  together). The deck variant attaches `airs-scan` at Service level and
  `airs-prompt-scan` at Route level, on a dedicated streaming route, relying on
  Kong's route-over-service plugin precedence.
- `airs_contents` in both files now takes `source` as an explicit first
  argument and switches on it (`INPUT` → `contents[].prompt`, `OUTPUT` →
  `contents[].response`), replacing the pair of direction-specific functions
  that each policy carried before.
- `docs/deployment-guide.md`: the classic control plane procedure now requires
  a `deck gateway diff` before every `sync`, and recommends tag-scoping with
  `--select-tag` or merging the plugin blocks into an existing state file,
  rather than syncing this repository's file standalone — `deck gateway sync`
  deletes anything not present in the file it is given. The Step 4 attachment
  instructions now attach one policy, not two, chosen by whether the model
  streams. The validation step now calls for capturing the emitted payload
  against a throwaway endpoint and a disposable token before pointing the
  configuration at the real Prisma AIRS key and the real credential.
- `docs/deployment-guide.md`: fixed a reference to a non-existent
  `config.metrics.block_details` field; the schema field is
  `metrics.block_detail`.
- `CONTRIBUTING.md`: assertion count updated to 55, and the pre-PR checklist now
  runs `scripts/check-plugin-schema.py --parity` and `--schema` alongside
  `scripts/run-lua-tests.sh` and `shellcheck`.

### Fixed

- The client-facing block message could be read as carrying, or was assumed to
  eventually carry, the Prisma AIRS category and detection names. Both
  `airs_verdict` functions now return a fixed, generic message — "Blocked by
  Prisma AIRS", optionally with " [scan_id=...]" — on every block path,
  including the fail-closed ones, with the category and detection names routed
  instead to `metrics.block_reason` / `metrics.block_detail` and the Prisma AIRS
  scan log. Naming the detection to the caller is an evasion oracle: it lets an
  attacker use the block response itself to map which inputs trip which
  detector.
- `airs_contents` now raises when `content` is not a string, rather than
  silently coercing or passing it through. The plugin injects its built-ins by
  parameter name, so a signature change or a Kong upgrade that alters that
  mapping would otherwise let the whole `conf` table — including the resolved
  API key — be JSON-encoded into `contents[].prompt` and shipped to Prisma
  AIRS. The type guard fails the request closed instead.
- The previous layout, which attached one `INPUT` policy and one `OUTPUT`
  policy to the same model, could not have worked on the deck variant: Kong
  keys a plugin instance on `{name, route, service, consumer}`, and that key is
  a unique column in the underlying table, so a second `ai-custom-guardrail`
  instance on the same Service is rejected at apply time. It is also
  redundant on the kongctl variant, since Kong runs a single instance of a
  given plugin per request. Replaced by the coverage design described above.
- `docs/deployment-guide.md` no longer claims response scanning is flatly
  "incompatible with SSE streaming" — that statement was unverified, and the
  chunked-buffering reading that briefly replaced it was wrong too. It now
  describes the measured behaviour: a streamed response is not scanned at all.

### Security

- Block responses no longer leak the Prisma AIRS category or detection names to
  the calling client, on any path, closing the evasion-oracle risk described
  under Fixed. See `SECURITY.md` for the issue class.
- `airs_contents`'s type guard prevents the plugin configuration — API key
  included, after vault resolution — from ever being shipped to Prisma AIRS as
  scanned text if a future Kong version changes how built-ins are injected into
  guardrail functions. See `SECURITY.md` for the issue class.

## [0.1.0] — 2026-09-08

First public release. Configuration-only enforcement of Prisma AIRS AI Runtime
(API Intercept) as an inline guardrail on Kong AI Gateway, for both an AI Gateway
2.x control plane and a classic Gateway control plane.

Everything below was fixed during the pre-publication audit, against the
published `ai-custom-guardrail` schema and the Prisma AIRS OpenAPI client. None of
it had run before, because all three defects fail at apply time.

### Fixed

- `guarding_mode` used `REQUEST` and `RESPONSE`, which are not valid values. The
  enum is `BOTH` / `INPUT` / `OUTPUT`. The prompt policy is now `INPUT` and the
  response policy `OUTPUT`.
- `request.body` used nested YAML. The schema accepts a flat map of strings only.
  The nested Prisma AIRS payload is now built by Lua functions returning a table,
  following Kong's Azure Content Safety example.
- `timeout`, `ssl_verify`, `stop_on_error` and `response_buffer_size` were
  documented as non-existent and deliberately omitted. All four are in the
  schema. `stop_on_error: true` is the mechanism that actually enforces
  fail-closed when the call to Prisma AIRS itself fails, which the Lua verdict
  function cannot cover.

### Added

- `scripts/run-lua-tests.sh` and `scripts/test-verdict-functions.lua`: 17
  offline assertions covering the verdict functions against the documented
  Prisma AIRS response shapes, plus a parity check that fails if the kongctl and
  deck configs carry different Lua.
- Verdict handling for `category: "error"` and `category: "timeout"`, which
  Prisma AIRS returns alongside `action: "allow"` when its own scan degrades.
  These previously passed through as allowed.
- `Accept: application/json` on the Prisma AIRS request, matching the reference
  integration published by Palo Alto Networks.
- CI: YAML parse, config parity, offline Lua suite, `shellcheck`, and a Gitleaks
  secret scan.
- `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `.editorconfig`.

### Changed

- `scripts/test-airs.sh` now asserts an expected verdict per case and exits
  non-zero on a mismatch, instead of only printing status codes. It asserts
  "not 200" rather than a specific status, because the status returned on a block
  has not been observed yet.
- `docs/sources.md` records the plugin schema, both published guardrail examples,
  and the Prisma AIRS OpenAPI client as the sources of truth.
- README lists the actual Prisma AIRS detection names, and notes that
  `db_security` and `ungrounded` are response-only.
