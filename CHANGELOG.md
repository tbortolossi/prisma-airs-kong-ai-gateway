# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

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
  phase that is never invoked under `stream: true`.
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
