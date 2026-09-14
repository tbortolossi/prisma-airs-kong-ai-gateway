# CLAUDE.md

Project context for Claude Code. Committed and public. Anything confidential
(customer names, opportunity context, internal positioning) belongs in
`CLAUDE.local.md`, which is gitignored.

## What this repository is

Deployment assets for enforcing **Prisma AIRS AI Runtime (API Intercept)** as an
inline guardrail on **Kong AI Gateway**, using Kong's supported extension point
rather than a custom Lua plugin.

The integration is **configuration only**. It ships no Lua plugin, requires no
data plane image rebuild, and works with a Konnect SaaS control plane and
self-managed data planes.

Two control plane shapes are supported:

| Shape | Tooling | Unit of configuration |
|---|---|---|
| AI Gateway 2.x | `kongctl` | `ai_gateway_policies` of type `ai-custom-guardrail` |
| Gateway control plane (classic) | `deck` | `ai-custom-guardrail` plugin on a Service or Route |

The `config` block is identical in both. Only the wrapper differs. **Any change
to the guardrail logic must be applied to both files in the same commit.**
`scripts/run-lua-tests.sh` enforces this for the verdict functions and fails the
build if the two drift apart.

## Repository layout

```
README.md                            public entry point
CONTRIBUTING.md                      how to work on this repo
SECURITY.md                          how to report a security issue
CHANGELOG.md                         released changes
docs/deployment-guide.md             customer-facing procedure
docs/sources.md                      canonical upstream references
docs/lab-tool-calls.md               lab procedure: is function calling scanned?
docs/lab-streaming.md                lab procedure: is a streamed response scanned, and how?
docs/lab-classic-control-plane.md    lab procedure: the deck variant on a classic control plane
config/kongctl/airs-guardrail.yaml   AI Gateway 2.x
config/deck/airs-guardrail.yaml      classic Gateway control plane
config/kongctl/airs-error-sanitizer.yaml   optional: generic body on a guardrail-call failure
config/deck/airs-error-sanitizer.yaml      same, classic control plane
config/kongctl/airs-diagnostics-log.yaml   optional: serializer record to the node's stdout, on/off switch
config/deck/airs-diagnostics-log.yaml      same, classic control plane
scripts/test-airs.sh                 end-to-end suite, needs a live gateway
scripts/run-lua-tests.sh             offline verdict function tests
scripts/test-verdict-functions.lua   the assertions those tests run
scripts/check-plugin-schema.py       config parity + live-schema validation, used in CI
scripts/lab-echo-server.py           stands in for AIRS, reports what Kong emits
scripts/lab-tool-call-probe.sh       one completion, a marker per tool position
CLAUDE.md                            this file
CLAUDE.local.md                      private working context (gitignored)
```

## Non-negotiable rules

**1. Never invent a Kong configuration field or value.**
Every field name *and every enum value* in the YAML must come from the plugin
schema. The narrative plugin page is not sufficient: it does not mention
`guarding_mode` at all, and an earlier revision of this repository shipped
`guarding_mode: REQUEST` / `RESPONSE`, which the schema rejects — the enum is
`BOTH` / `INPUT` / `OUTPUT`. The schema is published inline as `window.schema` on
the configuration reference page, and is authoritative on a live data plane at
`GET /schemas/plugins/ai-custom-guardrail`.

If a capability is needed and the field is not in the schema, leave it out and
record the gap in `CLAUDE.local.md` rather than guessing a plausible name. A YAML
that looks right and fails to apply is worse than one with a documented gap.

**2. Tag every assertion with its verification status.**
Configuration blocks and documentation claims carry one of three states:

- `DOCUMENTED` — published by Kong or Palo Alto Networks, with the URL in `docs/sources.md`
- `SYNTHESIZED` — a transposition or inference, not published anywhere
- `LAB-VERIFIED` — actually applied and exercised against a live gateway

Never promote `SYNTHESIZED` to `LAB-VERIFIED` without a recorded test run. Never
present a `SYNTHESIZED` block to a customer as if it were `DOCUMENTED`. Offline
unit tests do not make a block `LAB-VERIFIED`: they prove the Lua is correct
against the AIRS schema, not that Kong accepts the configuration.

**3. Secrets never appear in this repository.**
The API key is always a vault reference (`{vault://env/airs-token}`) or a
placeholder. No real token, no customer tenant identifier, no profile name from a
real deployment. Placeholder profile name is `kong-airs-prod`.

**4. Fail-closed is the default, through two mechanisms that cover two
different failures.** `stop_on_error: true` handles a call to Prisma AIRS that
fails (unreachable, timeout, non-2xx, undecodable body): the client gets HTTP
500 with the internal error text. LAB-VERIFIED 2026-09-14: `stop_on_error:
false` alone passes the traffic unscanned on such a failure (HTTP 200, model
called, `airs_verdict` never evaluated). The `airs_verdict` Lua function handles
a successful call that returns an unusable verdict — `action` missing, or
`category: "error"` / `"timeout"`, which AIRS returns alongside `action:
"allow"`. Both as shipped give fail-closed on both failures; relaxing one
relaxes only its own failure class. Fail-open is an explicitly documented
opt-in for pilot phases, never the shipped default.

**5. Customer-facing documents stay customer-facing.**
`docs/deployment-guide.md` contains no internal commentary, no verification tags,
no competitive positioning. Working notes go in `CLAUDE.local.md`.

## Technical constraints to respect

- `ai-custom-guardrail` requires **Kong Gateway 3.14+** and an AI licence.
- It requires `ai-proxy` or `ai-proxy-advanced` in the chain. It does not work standalone.
- `guarding_mode` is `BOTH` / `INPUT` / `OUTPUT`. Two policies exist, differing by
  **coverage, not direction**: `airs-scan` (`BOTH`) scans the prompt in its `INPUT`
  phase and the model output in its `OUTPUT` phase from one policy, picking
  `contents[].prompt` vs `contents[].response` from `$(source)`; `airs-prompt-scan`
  (`INPUT`) is the prompt-only variant for streaming models. Exactly one is
  attached per AI Model (kongctl) or per scope (deck) — never two on the same
  scope. Kong keys a plugin instance on `{name, route, service, consumer}`
  (`cache_key`), and that key is a `UNIQUE` column in the underlying table
  ([`kong/db/schema/entities/plugins.lua`](https://github.com/Kong/kong/blob/master/kong/db/schema/entities/plugins.lua),
  [`000_base.lua`](https://github.com/Kong/kong/blob/master/kong/db/migrations/core/000_base.lua)),
  so a second `ai-custom-guardrail` on the same Service is rejected at apply
  time; Kong also runs one instance of a given plugin per request, with a
  route-level instance overriding the service-level one
  ([plugin entity](https://developer.konghq.com/gateway/entities/plugin/)). The
  deck variant puts `airs-scan` at Service level and `airs-prompt-scan` at
  Route level on the streaming route, using that precedence directly.
- `request.body`, `request.headers`, `request.queries` and `params` are **flat maps
  of strings**. Nested YAML fails validation. Nested JSON is produced by a function
  that returns a Lua table, as in Kong's Azure Content Safety example.
- The built-in expression variables are `$(source)`, `$(conf)`, `$(content)` and
  `$(resp)`. Kong documents them as usable *as arguments to functions*, but not
  inside a function body.
- A function that receives content to forward to Prisma AIRS **must type-guard
  it as a string and raise otherwise**. If the explicit-argument call form is
  ever not honoured by a Kong version, the documented implicit signature
  (`function(conf)`) would pass the whole `conf` table — API key included, after
  vault resolution — where a string is expected. A permissive fallback such as
  `content or ""` would then ship it to Prisma AIRS as scanned text. `airs_contents`
  in both files raises on anything but a string; there is no fallback.
- Streaming, LAB-VERIFIED 2026-09-14 (correcting the 2026-09-08 reading): the
  `OUTPUT` phase does run on a `stream: true` response, in segments of about
  `response_buffer_size` bytes (schema default 100), one guardrail call per
  segment; content still below the threshold when the stream ends is never
  scanned; a block ends the stream after the flagged segment has already been
  delivered, HTTP 200 already sent; on the `ollama` driver it is cut with no
  terminal chunk, on the `openai` driver a last chunk carries
  `finish_reason: "blocked_by_guard"` then `data: [DONE]` (LAB-VERIFIED
  2026-09-14, sixth round). Non-streamed
  responses are always one call carrying the whole body, whatever the buffer
  value. The `65536` this repository shipped is what produced "no OUTPUT call"
  on 2026-09-08. The shipped config therefore no longer sets
  `response_buffer_size`. Two documented postures: simple mode leaves
  `response_streaming` at `allow` (streams scanned per segment,
  asynchronously, best effort: roughly output rate x scan latency leaks
  before a cut, LAB-VERIFIED 2026-09-14); strict mode sets
  `response_streaming: deny` on the model (kongctl) or on `ai-proxy-advanced`
  (deck) and gives models that must stream `airs-prompt-scan`. Never reintroduce a large
  buffer value "to scan a whole streamed answer at once": it scans nothing.
- The published schema page lags the data plane. The 2.0.3 data plane
  (Kong Gateway 3.14.0.3) also has `rejection_mode` (`none` / `stealth` /
  `verbose`), `continue_on_detection`, `log_blocked_content` and
  `proxy_config`, announced in the AI Gateway 2.0.1 changelog and absent from
  `window.schema`. They ship commented out: `check-plugin-schema.py --schema`
  validates against the published page and would fail on them. Get the live
  schema from the data plane (the Admin API is not exposed on the AI Gateway
  image; `resty -e` with the plugin's `schema` module works, see
  `CLAUDE.local.md`).
- **The Kong PDK is reachable inside a guardrail function body** — `kong` and
  `ngx` are tables, `require` works — and **every PDK call must be wrapped in
  `pcall`**. On the `OUTPUT` path of a streamed response the function runs with
  no request context; an unguarded raise there does not fail the request, it
  silently skips the guardrail call for that segment (LAB-VERIFIED 2026-09-14:
  constant → 7 segment scans, unguarded PDK call → 0 with HTTP 200 and the
  stream delivered whole, `pcall` → 7 again). An unguarded PDK call is a
  fail-OPEN. `kong.ctx.shared` carries a value from the `INPUT` phase to the
  `OUTPUT` phase of the same non-streamed request, which is what
  `airs_correlation` uses to mint one `tr_id` per exchange. The older note in
  `CLAUDE.local.md` saying no per-request value is reachable (Q7) is wrong: it
  tested which names the plugin injects as arguments, not the sandbox globals.
- **The scanned text must attribute each turn.** `text_source` joins message
  content only, with no roles, and that alone gets ordinary conversation
  blocked as prompt injection: the model's own previous answer, unattributed,
  reads as an assertion planted in the prompt (LAB-VERIFIED 2026-09-14, 3/3,
  with the threat report's `pi` snippet showing the exact text). `airs_contents`
  prefixes `user:` and `assistant:`. It must NEVER prefix `system:` — that is
  the shape of a system-prompt spoof and blocks the whole conversation; the
  system message, tool results and unknown roles go in unlabelled.
- **Prisma AIRS judges only the LAST element of `contents[]`.** The earlier
  elements are context and are not scanned (LAB-VERIFIED 2026-09-14: an
  injection first of two, or first of three, comes back `allow`/`benign`; the
  same injection last, or alone, blocks). So `airs_contents` returns ONE
  element containing everything that must be scanned. Splitting the
  conversation into one element per message matches a natural reading of the
  schema and silently stops scanning every turn but the newest — this
  repository wrote that version and caught it in lab the same day. The offline
  suite pins the single-element shape; do not "fix" it.
- A `contents[].tool_event` is accepted and detected, with two server-side
  allowlists: `ecosystem` must be `mcp` (`openai` → HTTP 400 `unsupported
  ecosystem`) and `method` one of `tools/call` / `tools/list` (anything else →
  `unsupported method`). But it is judged only as the last element, so it
  cannot share a scan with the prompt. Tool text therefore goes inside the
  scanned prompt element, behind `params.tool_scan`.
- The AIRS correlation identifiers nest and must not be swapped:
  `transaction_id` is one **round**, a prompt and the response it produced, and
  `session_id` is the **conversation** grouping several rounds. `tr_id` is the
  older name of `session_id`, NOT of `transaction_id` — measured on a live
  tenant, a request carrying only `tr_id` comes back with `session_id` set to
  that value, and `session_id` wins when both are sent. It is therefore never
  sent from this repository. Neither the AI Sessions page ("calls sharing the
  same transaction ID") nor the field descriptions settle this; only the
  tenant's own echo does. The gateway can mint a round on its own (Kong's
  request id) but never a conversation — only the caller knows where one
  starts, so `session_id` comes from a request header and falls back to the
  round.
- **A `request.body` field that is `nil` is omitted from the scan payload; a
  field that is an empty string is rendered as JSON `false`** (LAB-VERIFIED
  2026-09-14). A function that cannot build an optional identifier must return
  `nil` for it, never `""`.
- `metrics.block_detail` must evaluate to a Lua table. As a string, the data
  plane logs `metric input_block_detail has unexpected type string, expected
  table` at every request and drops the metric (LAB-VERIFIED 2026-09-14).
  `metrics.block_reason` accepts a string.
- Prisma AIRS refuses a scan payload above about 2 MB with HTTP 413, which
  `stop_on_error: true` turns into HTTP 500 (LAB-VERIFIED 2026-09-14). Kong
  does not truncate the scanned text. Under `concatenate_all_content` the
  whole conversation counts.
- Prisma AIRS endpoints are regional. The global endpoint is the default; keep
  the URL a single point of change.

## Conventions

- YAML: two-space indent, no tabs, comments in English.
- Lua verdict functions: guard clause first, then detection extraction, then
  verdict. Keep them under 40 lines. No external requires, with one exception —
  `airs_verdict` may attempt a `cjson.safe` decode inside a `pcall` when `$(resp)`
  arrives as a string, because Kong documents `$(resp)` as a string in the
  `OUTPUT` phase. The `pcall` must fail closed if the require or the decode fails.
- `airs_verdict` returns `{ block, block_message, detail }`, where `detail` is
  a table `{ reason, category, detections }` (a string is rejected by the
  metric, see above). Only
  `action == "allow"` passes; any other action, a missing or non-string action,
  or `category` of `"error"` / `"timeout"` blocks. `block_message` is always the
  fixed, generic client-facing text ("Blocked by Prisma AIRS", optionally with
  `[scan_id=...]`) — never the category or a detection name, on any path,
  including fail-closed. Category and detection names go only in `detail`,
  which callers wire to `metrics.block_detail`; `metrics.block_reason` receives
  the generic `block_message` (with its `scan_id`) for correlation, and neither
  ever feeds `response.block_message` with a category.
- Every copy of `airs_verdict`, `airs_contents` and `airs_correlation` must be
  byte-identical: across `config/kongctl/` and `config/deck/`, and across every
  guardrail instance within one file. `scripts/run-lua-tests.sh` enforces this
  and runs its assertions against the shipped Lua (no copy lives in the test
  file itself; the count is printed by the script).
- Shell: `set -u`, and no `set -e` in `test-airs.sh` specifically (a non-zero curl
  must not abort the remaining cases). Scripts must pass `shellcheck`.
- Documentation: English. Every external claim carries a link.

## Before opening a PR

- `./scripts/run-lua-tests.sh` passes.
- `python3 scripts/check-plugin-schema.py --parity` passes (kongctl/deck config
  blocks identical per instance).
- `python3 scripts/check-plugin-schema.py --schema` passes (every key and enum
  value exists in the live published schema).
- Both `config/kongctl/` and `config/deck/` updated in step.
- `docs/sources.md` updated if a new upstream reference was used.
- Verification tags reviewed, and anything downgraded is flagged in the PR body.
- `CHANGELOG.md` updated for anything user-visible.
- No secret, no customer identifier, no internal hostname.

## Working context

Private notes, roadmap and open lab questions: @CLAUDE.local.md
Canonical upstream sources: @docs/sources.md
