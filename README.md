# Prisma AIRS on Kong AI Gateway

Enforce **Prisma AIRS AI Runtime (API Intercept)** as an inline guardrail on
**Kong AI Gateway** — prompt scan, response scan, fail closed — using Kong's
supported extension point rather than a custom Lua plugin.

**Configuration only.** No Lua plugin, no data plane image rebuild. It works on a
Konnect SaaS control plane with self-managed data planes, including Azure
Container Apps and Kubernetes. Enforcement runs in your own infrastructure; only
the text to be scanned leaves it, and it goes straight to your Prisma AIRS
tenant.

*Community assets, published by an individual contributor. Not an official Palo
Alto Networks or Kong product, and covered by no support commitment from either
vendor — see [Disclaimer](#disclaimer). Provided under the MIT licence.*

```
   Client app
       │  POST /v1/chat/completions
       ▼
┌─────────────────────────────────────────────────────┐
│  Kong AI Gateway data plane                         │
│                                                     │
│  AI Policy: airs-scan (guarding_mode: BOTH)         │
│      INPUT phase  (prompt)   ───────────────────────┼──► Prisma AIRS
│      allow ▼ block → rejected                       │    /v1/scan/sync/request
│  AI Model → upstream LLM provider                   │    (action: allow | block)
│      OUTPUT phase (response) ───────────────────────┼──►
│      allow ▼ block → rejected                       │
│                                                     │
│  Streaming models attach airs-prompt-scan instead   │
│  (guarding_mode: INPUT): prompt only                │
└─────────────────────────────────────────────────────┘
       │
       ▼  200, or a rejection with "Blocked by Prisma AIRS"
   Client app
```

Attach exactly **one** policy per AI Model — `airs-scan` for prompt and
response, `airs-prompt-scan` for a model that must stream. Never both: Kong runs
one instance of a given plugin per request, and two attached policies give
silently degraded coverage rather than an error.

---

## Documentation

| If you want to | Read |
|---|---|
| install it | the TL;DR below |
| deploy it properly, with rollout and troubleshooting | [docs/deployment-guide.md](docs/deployment-guide.md) |
| know what it does **not** cover | [docs/limitations.md](docs/limitations.md) |
| understand why it is built this way | [docs/design-decisions.md](docs/design-decisions.md) |
| check a claim before repeating it to a customer | [docs/verification-status.md](docs/verification-status.md) |
| find the upstream reference behind a field | [docs/sources.md](docs/sources.md) |

---

## TL;DR — install and configure

**What you actually have to do: deploy the YAML, put the Prisma AIRS key on the
data planes, set your profile name, and attach the policy to your AI Model.**
That is the whole integration, provided the prerequisites below are already
true.

### Prerequisites

| | |
|---|---|
| Kong Gateway data planes | 3.14 or later, with an AI licence |
| Existing chain | `ai-proxy` or `ai-proxy-advanced` already in place — `ai-custom-guardrail` does not work standalone |
| Prisma AIRS | An API Intercept application and a named security profile |
| Network | Outbound HTTPS from the data planes to `service.api.aisecurity.paloaltonetworks.com:443` |

Below Kong Gateway 3.14, `ai-custom-guardrail` is unavailable. An alternative
based on the `request-callout` plugin exists upstream, limited to prompt
scanning and the OpenAI chat completion format.

### 1. Put the Prisma AIRS key on the data planes

As the environment variable `AIRS_TOKEN`. The configuration never holds the key:
it carries the reference `{vault://env/airs-token}`, which Kong resolves against
that variable, inside your own infrastructure.

```bash
# Azure Container Apps
az containerapp secret set --name <dp-app> --resource-group <rg> \
  --secrets airs-token=<PRISMA_AIRS_API_KEY>
az containerapp update --name <dp-app> --resource-group <rg> \
  --set-env-vars AIRS_TOKEN=secretref:airs-token

# Kubernetes
kubectl create secret generic prisma-airs -n <ns> \
  --from-literal=airs-token=<PRISMA_AIRS_API_KEY>
# then mount it as AIRS_TOKEN in the data plane deployment
```

### 2. Set two values in the YAML

In `params`, on both policies in
[`config/kongctl/airs-guardrail.yaml`](config/kongctl/airs-guardrail.yaml).
Nothing else has to change to get a working deployment:

| `params` key | Set it to | Ships as |
|---|---|---|
| `profile` | your Prisma AIRS security profile name, exactly | `kong-airs-prod` — a placeholder. Leave it and **every request fails closed** |
| `app_name` | a label identifying this gateway in your scan logs | `kong-ai-gateway` |

If your tenant is not on the global endpoint, change `request.url` too — it is
the single point of change for the region.

### 3. Apply, attach, validate

```bash
export KONNECT_PAT="<konnect pat>"
export AI_GATEWAY_ID="<ai gateway id>"

kongctl apply -f config/kongctl/airs-guardrail.yaml --pat "$KONNECT_PAT"
# then attach ONE policy to your AI Model:
#   policies:
#     - !ref airs-scan

export KONG_PROXY_URL="https://<proxy>"
export CLIENT_KEY="<client credential>"
./scripts/test-airs.sh          # 5 cases: 1 allowed, 3 blocked, 1 streaming probe
```

On a classic Gateway control plane the configuration is identical, wrapped for
`deck`: use [`config/deck/airs-guardrail.yaml`](config/deck/airs-guardrail.yaml)
and see the [deployment guide](docs/deployment-guide.md).

### Optional `params`, all off unless set

| Key | What it turns on |
|---|---|
| `session_header` | the request header naming the **conversation**, forwarded to Prisma AIRS as `session_id` so a whole conversation is one AI Session. Without it, each exchange is its own session |
| `user_header` | the request header naming the **end user**, used as `metadata.app_user` when no Kong consumer is authenticated. Caller-controlled: it labels a scan, it never authenticates one |
| `transaction_header` | lets the caller name the **round** itself; by default the round is Kong's own request id, which the client also receives as `X-Kong-Request-Id` |
| `tool_scan` | `calls` also scans the arguments a model generates for a tool call, which no `text_source` exposes; `catalogue` adds the `tools[]` declaration on top — expect a profile with the source-code detector to flag that one |
| `context_messages` | caps how many of the most recent conversation parts are assembled, to bound cost and stay under the 2 MB scan limit |

With a front-end that already knows its user and its conversation, naming two
headers is the whole integration. For Open WebUI, for instance:

```yaml
params:
  session_header: "x-openwebui-chat-id"
  user_header: "x-openwebui-user-email"
```

### Optional add-on policies

| File | What it does |
|---|---|
| [`config/kongctl/airs-diagnostics-log.yaml`](config/kongctl/airs-diagnostics-log.yaml) | writes the guardrail's own record — block reason, category, detections, per-phase scan latency, request id — to the data plane's standard output, so reporting a problem is one `docker logs` / `kubectl logs`. Carries an `enabled` switch and scrubs client credentials out of the record |
| [`config/kongctl/airs-error-sanitizer.yaml`](config/kongctl/airs-error-sanitizer.yaml) | replaces the `HTTP 500` body Kong returns when Prisma AIRS cannot be consulted with a fixed generic one |

Each has a `config/deck/` counterpart for the classic control plane.

### What the client sees

| Status | Meaning |
|---|---|
| `200` | allowed |
| `400` | blocked by policy — body `{"error":{"message":"Blocked by Prisma AIRS [scan_id=...]"}}`. The category and the detection names never leave the gateway; the `scan_id` is how you find the full verdict in Strata Cloud Manager, or through `GET /v1/scan/results?scan_ids=` |
| `500` | Prisma AIRS could not be consulted, and fail-closed refused the request rather than let it through unscanned |

---

## Limitations to plan for

Full detail, with the measurements behind each row, in
**[docs/limitations.md](docs/limitations.md)**.

| Limitation | Short version | What to do |
|---|---|---|
| **MCP traffic** | Kong allows no guardrail on MCP at all — the restriction is Kong's, not Prisma AIRS's | Call Prisma AIRS from outside the gateway |
| **Streamed responses** | Scanned in segments of about 100 bytes, and **an answer shorter than one segment is never scanned at all** — which is most chat answers | Stop the response streaming where response coverage must be guaranteed |
| **Blocks on a stream** | A flagged segment has already reached the client by the time the verdict arrives | Treat streaming response coverage as best effort |
| **Tool definitions and arguments** | No `text_source` exposes them | `params.tool_scan`, off by default |
| **Correlation on a stream** | The `OUTPUT` phase has no request context, so those scans carry no session or round | Non-streamed exchanges are unaffected |
| **Payload size** | Prisma AIRS refuses a scan above about 2 MB | `params.context_messages`, or `text_source: last_message` |

**Prompt scanning is never affected by any of these.** Every row above is on the
response leg; the prompt is scanned before the model is called, on every path
and in every posture.

Detections available depend on your Prisma AIRS security profile: prompt
injection, sensitive data (DLP), malicious URLs, toxic content, malicious code,
source code, topic violations, and — on responses — database security and
ungrounded content.

---

## Why this exists

Kong AI Gateway 2.x replaced the plugin-centric model with AI entities and
[AI Policies](https://developer.konghq.com/ai-gateway/policies/). Two
consequences follow, and together they are the reason this repository exists.

**Custom Lua plugins have no place on an AI Gateway 2.x control plane.** The
Prisma AIRS plugin published by Palo Alto Networks
([prisma-airs-integrations, `custom-plugin-v3`](https://github.com/PaloAltoNetworks/prisma-airs-integrations/tree/main/Kong/custom-plugin-v3))
remains fully valid where a custom plugin can still be loaded — self-hosted Kong
Gateway, and Konnect hybrid with a
[custom data plane image](https://developer.konghq.com/custom-plugins/konnect-hybrid-mode/).
It cannot be deployed on an AI Gateway 2.x control plane. Teams moving to v2
lose the integration they had.

This is a control-plane restriction, not a runtime one. The AI Gateway 2.x data
plane is itself a Kong Gateway 3.14 runtime carrying an AI Gateway version
label. What refuses the custom Lua plugin path on 2.x is the Konnect API:
applying an `ai_gateway_policies` entry of `type: prisma-airs-intercept` is
rejected outright, HTTP 400, "policy type 'prisma-airs-intercept' is not
supported". The catalogue is closed at the control plane, independently of what
the data plane underneath could otherwise run.

**The v2 policy catalogue has no Prisma AIRS type.** It ships vendor-specific
guardrail policies for `ai-aws-guardrails`, `ai-azure-content-safety`,
`ai-gcp-model-armor` and `ai-lakera-guard`, joined by NVIDIA NeMo Guardrails
since AI Gateway 2.0.1. Prisma AIRS is not among them. There is nothing to
select in the catalogue.

What v2 does provide is `ai-custom-guardrail`, Kong's supported extension point
for calling an external guardrail service over HTTP. This repository uses it to
carry the same enforcement as declarative configuration, applied through
`kongctl` on an AI Gateway 2.x control plane or through `deck` on a classic
Gateway control plane.

---

## Repository layout

```
docs/deployment-guide.md             step-by-step deployment procedure
docs/limitations.md                  what this does not cover, and why
docs/design-decisions.md             why the configuration is shaped this way
docs/verification-status.md          every claim, with its verification tag
docs/sources.md                      canonical upstream references
docs/lab-tool-calls.md               lab procedure: is function calling scanned?
docs/lab-streaming.md                lab procedure: is a streamed response scanned, and how?
docs/lab-classic-control-plane.md    lab procedure: the deck variant on a classic control plane
config/kongctl/airs-guardrail.yaml   AI Gateway 2.x
config/deck/airs-guardrail.yaml      classic Gateway control plane
config/kongctl/airs-error-sanitizer.yaml   optional: generic body when Prisma AIRS cannot be consulted
config/deck/airs-error-sanitizer.yaml      same, classic control plane
config/kongctl/airs-diagnostics-log.yaml   optional: one diagnostics log on the node, with an on/off switch
config/deck/airs-diagnostics-log.yaml      same, classic control plane
scripts/test-airs.sh                 five-case validation suite, needs a live gateway
scripts/run-lua-tests.sh             offline unit tests for the verdict functions
scripts/test-verdict-functions.lua   the assertions those tests run
scripts/check-plugin-schema.py       config parity and live-schema validation, used in CI
scripts/lab-echo-server.py           stands in for Prisma AIRS, logs what Kong emits
scripts/lab-tool-call-probe.sh       one completion, a marker per tool call position
```

## Related

- Palo Alto Networks, official Kong integration assets:
  [PaloAltoNetworks/prisma-airs-integrations](https://github.com/PaloAltoNetworks/prisma-airs-integrations),
  specifically the
  [`custom-plugin-v3`](https://github.com/PaloAltoNetworks/prisma-airs-integrations/tree/main/Kong/custom-plugin-v3)
  flavours (buffered SSE scanning, MCP coverage) and the `request-callout`
  variant, for Kong Gateway and Konnect hybrid. Its deployment guide names this
  repository as the worked reference for AI Gateway 2.x
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
