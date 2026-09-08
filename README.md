# Prisma AIRS on Kong AI Gateway

**Kong AI Gateway 2.x removes the custom Lua plugin path — and with it, the way
Prisma AIRS was integrated with Kong until now.** This repository restores the
enforcement without Lua, using configuration only.

Enforce **Prisma AIRS AI Runtime (API Intercept)** as an inline guardrail on
**Kong AI Gateway**, with a Konnect SaaS control plane and self-managed data
planes, including Azure Container Apps and Kubernetes. No custom plugin, no data
plane image rebuild.

> [!IMPORTANT]
> **Streaming bypasses response scanning, silently.** When a client sets
> `stream: true`, Kong never invokes the `OUTPUT` phase: the guardrail service
> receives no call, there is no error and no warning, and the complete SSE stream
> reaches the client. Prompt scanning is unaffected. Any caller can therefore opt
> itself out of response scanning with one flag in its own request body.
>
> This is Kong's behaviour, measured on a live gateway on 2026-09-08, not a
> configuration choice made here — no setting in this repository changes it.
> Scope your deployment around it before you deploy: either refuse `stream: true`
> at the gateway, or accept prompt-only coverage on the models that must stream.
> The measurement is in
> [Streaming silently bypasses response scanning](#streaming-silently-bypasses-response-scanning);
> the two supported ways to handle it are in [Design decisions](#design-decisions).

---

## Why this exists

Kong AI Gateway 2.x replaced the plugin-centric model with AI entities and
[AI Policies](https://developer.konghq.com/ai-gateway/policies/). Two
consequences follow, and together they are the reason this repository exists.

**Custom Lua plugins have no place on an AI Gateway 2.x control plane.** The
Prisma AIRS plugin published by Palo Alto Networks
([prisma-airs-integrations](https://github.com/PaloAltoNetworks/prisma-airs-integrations))
remains fully valid where a custom plugin can still be loaded — self-hosted Kong
Gateway, and Konnect hybrid with a
[custom data plane image](https://developer.konghq.com/custom-plugins/konnect-hybrid-mode/).
It cannot be deployed on an AI Gateway 2.x control plane, where configuration is
expressed as AI entities and policies rather than as plugins shipped inside the
data plane image. Teams moving to v2 lose the integration they had.

**The v2 policy catalogue has no Prisma AIRS type.** It ships vendor-specific
guardrail policies for several third-party providers; Prisma AIRS is not among
them. There is nothing to select in the catalogue.

What v2 does provide is `ai-custom-guardrail`, Kong's supported extension point
for calling an external guardrail service over HTTP. This repository uses it to
carry the same Prisma AIRS enforcement — prompt scan, response scan, fail closed
— as declarative configuration, applied through `kongctl` on an AI Gateway 2.x
control plane or through `deck` on a classic Gateway control plane.

## What it does

```
   Client app
       │  POST /v1/chat/completions
       ▼
┌────────────────────────────────────────────────────┐
│  Kong AI Gateway data plane                        │
│                                                     │
│  AI Policy: airs-scan (guarding_mode: BOTH)        │
│      INPUT phase  (prompt)   ──────────────────────┼──► Prisma AIRS  /v1/scan/sync/request
│      allow ▼ block → rejected                      │        (action: allow | block)
│  AI Model → upstream LLM provider                  │
│      OUTPUT phase (response) ──────────────────────┼──► Prisma AIRS  /v1/scan/sync/request
│      allow ▼ block → rejected                      │
│                                                     │
│  Streaming models attach airs-prompt-scan          │
│  (guarding_mode: INPUT) instead: prompt only        │
└─────────────────────────────────────────────────────┘
       │
       ▼  200, or a rejection with "Blocked by Prisma AIRS"
   Client app
```

One policy, two phases: `airs-scan` runs `guarding_mode: BOTH`, scanning the
prompt in its `INPUT` phase and the model output in its `OUTPUT` phase.
Attach one of the two per AI Model: streaming models take `airs-prompt-scan`
(`guarding_mode: INPUT`), which covers the prompt only, instead of `airs-scan`. See [Design decisions](#design-decisions).

Enforcement happens in the data plane, in your own infrastructure. Only the text
to be scanned leaves your environment, and it goes directly to your Prisma AIRS
tenant.

Detections available depend on your Prisma AIRS security profile: prompt
injection, sensitive data (DLP), malicious URLs, toxic content, malicious code,
source code, topic violations, and — on responses — database security and
ungrounded content.

## Scope and limits

What this configuration scans is the prompt text and the response text on the LLM
path. Two adjacent surfaces are not covered, and are stated here rather than left
to be discovered in production.

### MCP traffic is out of scope

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

### Tool calls on the LLM path: message content only

Settled on a live gateway on 2026-09-08 (Kong AI Gateway 2.0.3, data plane
3.14.0.3-enterprise), with the procedure in
[docs/lab-tool-calls.md](docs/lab-tool-calls.md). `$(content)` carries message
**content**, and nothing else:

| Position | `last_message` | `concatenate_user_content` | `concatenate_all_content` |
|---|---|---|---|
| system message | no | no | **scanned** |
| user message | last message only | **scanned** | **scanned** |
| `tools[].function.description` | no | no | **no** |
| assistant `tool_calls[].function.arguments` | no | no | **no** |
| `role: "tool"` result content | no | no | **scanned** |

Two consequences, and they point in opposite directions.

**Tool definitions and generated tool arguments are never scanned**, under any
`text_source`. They are not message content, so they never enter `$(content)`.
A poisoned tool description, and the arguments the model chooses to send to a
tool, are invisible to this configuration. That is the same class of gap as the
MCP one above, and it has the same cause: the guardrail sees the text of the
conversation, not the structure around it.

**Tool results are scanned** under `concatenate_all_content` — a `role: "tool"`
message is a message with content like any other. So data coming back from a
tool, which is where an untrusted external system injects into the context, does
reach Prisma AIRS.

The concatenation itself is worth knowing: messages are joined with `\n\n` in
**reverse chronological order**, most recent first, with a trailing separator.
Under `concatenate_all_content` the system prompt is included, which is a
false-positive surface if it contains instructions that read like an injection.

### Streaming silently bypasses response scanning

With `stream: true`, the `OUTPUT` phase is never invoked. Not deferred, not
partial: the guardrail service receives no call at all, and the complete SSE
stream reaches the client. Prompt scanning still applies.

Measured on 2026-09-08 by pointing the `OUTPUT` policy at a guardrail service
that answers `action: block` for everything. The non-streamed request was
rejected with HTTP 400. The streamed request returned HTTP 200 and all 34 SSE
chunks, and the guardrail service logged one single call — the non-streamed one.

There is no error and no warning, so a client that sets `stream: true` silently
downgrades itself to prompt-only coverage. See
[Design decisions](#design-decisions) for the two ways to handle it.

The `OUTPUT` phase also carries no prompt context alongside the response it
scans, which is a design limit rather than a schema gap.

## Requirements

| | |
|---|---|
| Kong Gateway data planes | 3.14 or later, with an AI licence |
| Existing chain | `ai-proxy` or `ai-proxy-advanced` already in place |
| Prisma AIRS | An API Intercept application and a named security profile |
| Network | Outbound HTTPS from the data planes to `service.api.aisecurity.paloaltonetworks.com:443` |

Below Kong Gateway 3.14, `ai-custom-guardrail` is unavailable. An alternative
based on the `request-callout` plugin exists upstream, limited to prompt scanning
and the OpenAI chat completion format.

## Quick start

```bash
# 1. Provision the Prisma AIRS key on the data planes
az containerapp secret set --name <dp-app> --resource-group <rg> \
  --secrets airs-token=<PRISMA_AIRS_API_KEY>
az containerapp update --name <dp-app> --resource-group <rg> \
  --set-env-vars AIRS_TOKEN=secretref:airs-token

# 2. Apply the policies
export KONNECT_PAT="<konnect pat>"
export AI_GATEWAY_ID="<ai gateway id>"
kongctl apply -f config/kongctl/airs-guardrail.yaml --pat "$KONNECT_PAT"

# 3. Attach one policy to your AI Model, then validate
export KONG_PROXY_URL="https://<proxy>"
export CLIENT_KEY="<client credential>"
./scripts/test-airs.sh
```

Full procedure, including the classic Gateway control plane variant, progressive
rollout and troubleshooting: **[docs/deployment-guide.md](docs/deployment-guide.md)**.

## Repository layout

```
docs/deployment-guide.md             step-by-step deployment procedure
docs/sources.md                      canonical upstream references
docs/lab-tool-calls.md               lab procedure: is function calling scanned?
config/kongctl/airs-guardrail.yaml   AI Gateway 2.x
config/deck/airs-guardrail.yaml      classic Gateway control plane
scripts/test-airs.sh                 five-case validation suite, needs a live gateway
scripts/run-lua-tests.sh             offline unit tests for the verdict functions
scripts/test-verdict-functions.lua   the assertions those tests run
scripts/check-plugin-schema.py       config parity and live-schema validation, used in CI
scripts/lab-echo-server.py           stands in for Prisma AIRS, logs what Kong emits
scripts/lab-tool-call-probe.sh       one completion, a marker per tool call position
```

## Design decisions

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

**Fail closed by default, through two mechanisms, and only one verdict passes.**
`stop_on_error: true` covers a failed call to Prisma AIRS. The `airs_verdict`
function covers a call that succeeds but returns an unusable verdict, including
`category: "error"` and `category: "timeout"`, which AIRS returns alongside
`action: "allow"`. Only `action: "allow"` passes traffic; any other action, a
missing or malformed verdict, or a degraded scan category blocks. Switching to
fail-open for a pilot requires changing both mechanisms together.

**Generic block message.** The client only ever sees "Blocked by Prisma AIRS",
optionally followed by " [scan_id=...]" — never the category or the detection
names, and the same generic message is returned on a fail-closed block as on a
real detection. Naming the detection to the caller is an evasion oracle: it lets
an attacker use the block response itself to map which inputs trip which
detector. The detection detail is not lost: it is in the Prisma AIRS scan logs
in Strata Cloud Manager, correlated by `scan_id`, which is the channel to rely
on. The configuration also routes it to `metrics.block_reason` /
`metrics.block_detail`; the schema accepts those fields, but they do not surface
on the data plane's own metrics endpoint, even with the Prometheus policy and
`ai_metrics` enabled — whose AI families are LLM request, cost and token
counters, not guardrail metrics. Treat Kong-side metrics as unconfirmed and
Strata Cloud Manager as the record. Palo Alto's own reference
integration ([`request-callout` config](https://github.com/PaloAltoNetworks/prisma-airs-integrations))
follows the same pattern, returning a generic "Blocked by AI security scan".

**Secrets in the slot built for them.** The API key is a
`{vault://env/airs-token}` reference resolved by the data plane at runtime, and
it is carried by `request.auth` (`location: header`, `name: x-pan-token`) rather
than by `config.params` plus a `$(conf.params.api_key)` interpolation. Both
fields are referenceable, so the vault reference resolves either way — verified
against a live tenant — but `request.auth.value` is also stored encrypted, and
the credential no longer appears in the `conf` table that guardrail functions
receive. The key never transits the SaaS control plane and never appears in
version control.

**Streaming, and what to do about it.** Response scanning is not merely
"incompatible" with SSE — it is skipped, silently, as measured above. Two
workable answers, and the choice is a policy one:

- attach `airs-scan` and **refuse streaming** at the gateway or in the client
  contract, so that response coverage is real for every request;
- attach `airs-prompt-scan` on models that must stream, and state plainly that
  those models have prompt-only coverage.

What does not work is attaching `airs-scan` to a streaming model and assuming
the response is inspected. `response_buffer_size: 65536` remains a starting
value for the buffered case; it has no effect on a streamed response, since no
scan happens at all.

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

## Verification status

Every configuration key used here, and every allowed value, comes from the
published Kong plugin schema and the Prisma AIRS OpenAPI client — see
[docs/sources.md](docs/sources.md). The verdict functions are unit tested
offline, and the whole configuration was exercised against a live gateway:

```bash
./scripts/run-lua-tests.sh     # 63 assertions, offline
./scripts/test-airs.sh         # 5 cases, needs a live gateway
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
  [Scope and limits](#scope-and-limits).
- **`guarding_mode: BOTH` covers both phases in one policy**, with `$(source)`
  distinguishing them, and the two scans are sequential.
- **Streaming skips the `OUTPUT` phase entirely**, with no error — see
  [Scope and limits](#scope-and-limits).

Confirmed against the schema and the published examples: `guarding_mode`,
`text_source`, `params`/`request.*`/`response.*`/`functions`, `timeout`,
`ssl_verify`, `stop_on_error`, `response_buffer_size`, `allow_masking`,
`metrics`, `custom_metrics`, `request.auth`, dotted access to a function result
(`$(fn.field)`), and the `$(source)` values `INPUT` / `OUTPUT`. The plugin
instance uniqueness and route-over-service precedence behind the two-policy
design are documented on Kong's plugin entity page and in the `kong` GitHub
repository — see [docs/sources.md](docs/sources.md).

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

What remains unconfirmed:

- whether `metrics.*` templates are rendered and exported anywhere. The fields
  apply and traffic flows, but nothing guardrail-related appears on the data
  plane's metrics endpoint. Checking Konnect's AI analytics view is the
  remaining step;
- the `response_buffer_size: 65536` value, a starting point rather than a
  measured figure, and one that only applies to buffered responses.

Validate in a non-production environment before this reaches production traffic.

## Related

- Palo Alto Networks, official Kong integration assets:
  [PaloAltoNetworks/prisma-airs-integrations](https://github.com/PaloAltoNetworks/prisma-airs-integrations)
  (custom Lua plugin and `request-callout` variants, for Kong Gateway and Konnect hybrid)
- Kong, [AI Custom Guardrail](https://developer.konghq.com/plugins/ai-custom-guardrail/)
- Kong, [AI Gateway Policies](https://developer.konghq.com/ai-gateway/policies/)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). To report a security issue, see
[SECURITY.md](SECURITY.md).

## Disclaimer

Community assets, not an official Palo Alto Networks or Kong product. Provided as
is, without support commitment from either vendor.

## Licence

MIT
