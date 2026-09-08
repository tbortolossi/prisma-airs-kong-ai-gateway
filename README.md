# Prisma AIRS on Kong AI Gateway

Enforce **Prisma AIRS AI Runtime (API Intercept)** as an inline guardrail on
**Kong AI Gateway**, with configuration only. No custom Lua plugin, no data plane
image rebuild.

Works with a Konnect SaaS control plane and self-managed data planes, including
Azure Container Apps and Kubernetes.

---

## Why this exists

Kong AI Gateway 2.x replaced the plugin-centric model with AI entities and AI
Policies. The Prisma AIRS custom Lua plugin published by Palo Alto Networks still
applies to self-hosted Kong Gateway and to Konnect hybrid deployments with a
custom data plane image, but it cannot be loaded on an AI Gateway 2.x control
plane, and the v2 policy catalogue has no dedicated Prisma AIRS type.

This repository closes that gap using `ai-custom-guardrail`, Kong's supported
extension point for calling an external guardrail service over HTTP.

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
config/kongctl/airs-guardrail.yaml   AI Gateway 2.x
config/deck/airs-guardrail.yaml      classic Gateway control plane
scripts/test-airs.sh                 five-case validation suite, needs a live gateway
scripts/run-lua-tests.sh             offline unit tests for the verdict functions
scripts/test-verdict-functions.lua   the assertions those tests run
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

Two things remain to be confirmed against a live gateway, and are called out in
the configuration comments:

- the explicit-argument call form `$(airs_contents(content))`, which follows the
  plugin documentation but appears in no published example;
- whether Kong delivers the guardrail response as a table or a string in the
  `OUTPUT` phase. The verdict function handles both.

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
