# Prisma AIRS on Kong AI Gateway

**Kong AI Gateway 2.x removes the custom Lua plugin path — and with it, the way
Prisma AIRS was integrated with Kong until now.** This repository restores the
enforcement without Lua, using configuration only.

Enforce **Prisma AIRS AI Runtime (API Intercept)** as an inline guardrail on
**Kong AI Gateway**, with a Konnect SaaS control plane and self-managed data
planes, including Azure Container Apps and Kubernetes. No custom plugin, no data
plane image rebuild.

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
┌──────────────────────────────────────────┐
│  Kong AI Gateway data plane              │
│                                          │
│  AI Policy: airs-prompt-scan   ──────────┼──► Prisma AIRS  /v1/scan/sync/request
│      allow ▼ block → rejected            │        (action: allow | block)
│  AI Model → upstream LLM provider        │
│      ▼                                   │
│  AI Policy: airs-response-scan ──────────┼──► Prisma AIRS  /v1/scan/sync/request
│      allow ▼ block → rejected            │
└──────────────────────────────────────────┘
       │
       ▼  200, or an error carrying the block reason
   Client app
```

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

### Tool calls on the LLM path are not confirmed

A chat completion carrying `tools[]`, an assistant message carrying
`tool_calls[].function.arguments`, or a `role: "tool"` result is a different
question from MCP, and it is open. `text_source` accepts `last_message`,
`concatenate_user_content` and `concatenate_all_content`, and no published Kong
documentation states what `$(content)` contains in each case beyond message text.
Until that is observed on a live gateway, do not assume function-calling
arguments are scanned. It is listed under
[Verification status](#verification-status) below, and
[docs/lab-tool-calls.md](docs/lab-tool-calls.md) is the procedure that settles
it: an echo server that stands in for Prisma AIRS and reports which positions
reached the scanned text.

### Already stated elsewhere

Response scanning buffers and is incompatible with SSE streaming, and the
`OUTPUT` phase carries no prompt context alongside the response it scans — both
are covered under [Design decisions](#design-decisions).

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

# 3. Attach them to your AI Model, then validate
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
scripts/lab-echo-server.py           stands in for Prisma AIRS, logs what Kong emits
scripts/lab-tool-call-probe.sh       one completion, a marker per tool call position
```

## Design decisions

**Two policies, not one.** `guarding_mode` accepts `BOTH`, but Prisma AIRS uses
different payload keys for prompts (`contents[].prompt`) and responses
(`contents[].response`), so each direction needs its own request body. One policy
runs `INPUT`, the other `OUTPUT`.

**Nested JSON comes from functions.** `request.body` is a flat map of strings —
nested YAML fails schema validation. The Prisma AIRS payload is assembled by small
Lua functions that return a table, following Kong's own Azure Content Safety
example.

**Fail closed by default, through two mechanisms.** `stop_on_error: true` covers a
failed call to Prisma AIRS. The `airs_verdict` function covers a call that
succeeds but returns an unusable verdict, including `category: "error"` and
`category: "timeout"`, which AIRS returns alongside `action: "allow"`. Switching
to fail-open for a pilot requires changing both.

**Secrets by reference.** The API key is a `{vault://env/airs-token}` reference
resolved by the data plane at runtime. `config.params` is a referenceable field,
so the substitution happens there. The key never transits the SaaS control plane
and never appears in version control.

**Response scanning is opt-in per model.** It requires buffering and is
incompatible with server-sent event streaming.

## Verification status

Every configuration key used here, and every allowed value, comes from the
published Kong plugin schema and the Prisma AIRS OpenAPI client — see
[docs/sources.md](docs/sources.md). The verdict functions are unit tested offline:

```bash
./scripts/run-lua-tests.sh
```

Three things remain to be confirmed against a live gateway. The first two are
also called out in the configuration comments:

- the explicit-argument call form `$(airs_contents(content))`, which follows the
  plugin documentation but appears in no published example;
- whether Kong delivers the guardrail response as a table or a string in the
  `OUTPUT` phase. The verdict function handles both;
- what `$(content)` actually contains under `concatenate_all_content` — in
  particular whether tool definitions, tool call arguments and tool results are
  included, which decides whether function calling is scanned at all. See
  [Scope and limits](#scope-and-limits).

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
