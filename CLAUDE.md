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
config/kongctl/airs-guardrail.yaml   AI Gateway 2.x
config/deck/airs-guardrail.yaml      classic Gateway control plane
scripts/test-airs.sh                 end-to-end suite, needs a live gateway
scripts/run-lua-tests.sh             offline verdict function tests
scripts/test-verdict-functions.lua   the assertions those tests run
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

**4. Fail-closed is the default, through both mechanisms.**
`stop_on_error: true` handles a failed call to Prisma AIRS. The `airs_verdict`
Lua function handles a successful call that returns an unusable verdict —
including `category: "error"` and `category: "timeout"`, which AIRS returns
alongside `action: "allow"`. Changing one without the other does not change the
behaviour. Fail-open is an explicitly documented opt-in for pilot phases, never
the shipped default.

**5. Customer-facing documents stay customer-facing.**
`docs/deployment-guide.md` contains no internal commentary, no verification tags,
no competitive positioning. Working notes go in `CLAUDE.local.md`.

## Technical constraints to respect

- `ai-custom-guardrail` requires **Kong Gateway 3.14+** and an AI licence.
- It requires `ai-proxy` or `ai-proxy-advanced` in the chain. It does not work standalone.
- `guarding_mode` is `BOTH` / `INPUT` / `OUTPUT`. Prompt and response scanning use
  different Prisma AIRS payload keys (`contents[].prompt` vs `contents[].response`),
  which is why there are two policies rather than one with `BOTH`.
- `request.body`, `request.headers`, `request.queries` and `params` are **flat maps
  of strings**. Nested YAML fails validation. Nested JSON is produced by a function
  that returns a Lua table, as in Kong's Azure Content Safety example.
- The built-in expression variables are `$(source)`, `$(conf)`, `$(content)` and
  `$(resp)`. Kong documents them as usable *as arguments to functions*, but not
  inside a function body.
- Response scanning forces buffering and is incompatible with SSE streaming.
- Prisma AIRS endpoints are regional. The global endpoint is the default; keep
  the URL a single point of change.

## Conventions

- YAML: two-space indent, no tabs, comments in English.
- Lua verdict functions: guard clause first, then detection extraction, then
  verdict. Keep them under 40 lines. No external requires, with one exception —
  the `OUTPUT` verdict function may attempt a `cjson.safe` decode inside a
  `pcall`, because Kong documents `$(resp)` as a string in that phase. The
  `pcall` must fail closed if the require or the decode fails.
- Shell: `set -u`, and no `set -e` in `test-airs.sh` specifically (a non-zero curl
  must not abort the remaining cases). Scripts must pass `shellcheck`.
- Documentation: English. Every external claim carries a link.

## Before opening a PR

- `./scripts/run-lua-tests.sh` passes.
- Both `config/kongctl/` and `config/deck/` updated in step.
- `docs/sources.md` updated if a new upstream reference was used.
- Verification tags reviewed, and anything downgraded is flagged in the PR body.
- `CHANGELOG.md` updated for anything user-visible.
- No secret, no customer identifier, no internal hostname.

## Working context

Private notes, roadmap and open lab questions: @CLAUDE.local.md
Canonical upstream sources: @docs/sources.md
