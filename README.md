# Prisma AIRS on Kong AI Gateway

Enforce **Prisma AIRS AI Runtime (API Intercept)** as an inline guardrail on
**Kong AI Gateway**. Prompt scan, response scan, fail closed.

**Configuration only** — no Lua plugin, no data plane image rebuild. Works on a
Konnect SaaS control plane with self-managed data planes.

*Community assets from an individual contributor. Not an official Palo Alto
Networks or Kong product, no support commitment from either vendor. MIT
licence. See [Disclaimer](#disclaimer).*

---

## Coverage

✅ supported  ⚠️ partial, read the note  ❌ not available

### Scanning phases

| Phase | | Notes |
|---|:--:|---|
| Prompt | ✅ | Every request, before the model is called |
| Response, not streamed | ✅ | One scan carrying the whole body |
| Response, streamed | ⚠️ | Scanned in ~100-byte segments. An answer shorter than one segment is **not scanned at all**, and a block arrives after that segment reached the client |
| Tool definitions and generated arguments | ⚠️ | `params.tool_scan`, ships off. No `text_source` exposes them |
| Tool results | ✅ | A `role: "tool"` message is scanned as message content |
| MCP traffic | ❌ | Kong allows no guardrail on MCP — the limit is Kong's, not Prisma AIRS's |

### Features

| Feature | | Notes |
|---|:--:|---|
| Fail closed on a Prisma AIRS outage | ✅ | The default. Two mechanisms covering two failure classes |
| Monitor mode for a pilot | ✅ | `continue_on_detection`, ships commented out |
| Session and round correlation | ✅ | `session_id` + `transaction_id`. Not on streamed responses |
| `metadata`: app, user, user IP, model | ✅ | Rendered in the Strata Cloud Manager transaction panel |
| Role attribution in the scanned text | ✅ | `user:` / `assistant:`, which is what keeps ordinary conversation benign |
| Diagnostics log on the node | ✅ | Optional policy, with an on/off switch |
| Generic body when the scan fails | ✅ | Optional policy |
| Regional Prisma AIRS endpoints | ✅ | One URL to change |
| Forward proxy, http and https | ✅ | `proxy_config` |
| Prompt and response masking | ❌ | `allow_masking` exists in the plugin schema; not used or tested here |
| `contents[].tool_event` objects | ❌ | Prisma AIRS accepts them, but judges only the last element, so they would displace the prompt |
| Security profile by UUID | ❌ | The profile **name** is sent |

### Control planes and formats

| | | Notes |
|---|:--:|---|
| AI Gateway 2.x, `kongctl` | ✅ | The primary target |
| Classic Gateway control plane, `deck` | ✅ | Same configuration, different wrapper |
| OpenAI `chat/completions` request bodies | ✅ | |
| Other client body shapes | ⚠️ | Still scanned, but the text falls back to `text_source` unattributed |

Every claim above with its verification tag:
[docs/verification-status.md](docs/verification-status.md).

---

## What this does

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

- Enforcement runs in your own infrastructure. Only the text to be scanned
  leaves it, straight to your Prisma AIRS tenant.
- Attach exactly **one** policy per AI Model. Two are accepted and give
  silently degraded coverage.
- Which detections fire is your security profile's business: prompt injection,
  DLP, malicious URLs, toxic content, malicious code, source code, topic
  violations, and on responses database security and ungrounded content.

---

## Quick start

Four things, all four required:

1. put the Prisma AIRS key on the data planes,
2. set your security profile name in the YAML,
3. apply the policies,
4. **attach one of them to your AI Model.**

Steps 2 and 4 are the ones that get missed, and they fail in opposite
directions: the placeholder profile blocks everything, a policy that is not
attached passes everything unscanned.

### Prerequisites

| | |
|---|---|
| Kong Gateway data planes | 3.14 or later, with an AI licence |
| Existing chain | `ai-proxy` or `ai-proxy-advanced` — `ai-custom-guardrail` does not work standalone |
| Prisma AIRS | An API Intercept application and a named security profile |
| Network | Outbound HTTPS to `service.api.aisecurity.paloaltonetworks.com:443` |

Below 3.14 the plugin does not exist; an upstream `request-callout` variant
covers prompt scanning only.

### 1. Put the key on the data planes

As `AIRS_TOKEN`. The YAML carries `{vault://env/airs-token}` and never the key
itself.

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
[`config/kongctl/airs-guardrail.yaml`](config/kongctl/airs-guardrail.yaml):

| Key | Set it to | Ships as |
|---|---|---|
| `profile` | your security profile name, exactly | `kong-airs-prod` — a placeholder. Leave it and **every request fails closed** |
| `app_name` | a label for this gateway in your scan logs | `kong-ai-gateway` |

Not on the global endpoint? Change `request.url` too. It is the only place.

### 3. Apply

```bash
export KONNECT_PAT="<konnect pat>"
export AI_GATEWAY_ID="<ai gateway id>"

kongctl apply -f config/kongctl/airs-guardrail.yaml --pat "$KONNECT_PAT"
```

This creates the policies. It does **not** put them in the request path.

### 4. Attach one policy to your AI Model

```yaml
ai_gateway_models:
  - ref: <your-model>
    # ...
    policies:
      - !ref airs-scan          # prompt and response
      # - !ref airs-prompt-scan # prompt only, for a model that must stream
```

> [!WARNING]
> **This is the step that fails quietly.** Skip it and the gateway keeps
> answering `200` with nothing scanned — no error, no log line, nothing visible
> to the client.

### 5. Validate

```bash
export KONG_PROXY_URL="https://<proxy>"
export CLIENT_KEY="<client credential>"
./scripts/test-airs.sh     # 1 allowed, 3 blocked, 1 streaming probe
```

| Result | Meaning |
|---|---|
| 5/5 as expected | done |
| Everything allowed | the policy is not attached — step 4 |
| Everything blocked | the profile name is wrong, fail-closed is working — step 2 |
| `HTTP 500` everywhere | Prisma AIRS unreachable: key, endpoint, or egress |

On a classic control plane, same configuration wrapped for `deck`:
[`config/deck/airs-guardrail.yaml`](config/deck/airs-guardrail.yaml) and the
[deployment guide](docs/deployment-guide.md).

---

## Optional settings

### `params`, all off unless set

| Key | What it turns on |
|---|---|
| `session_header` | the header naming the **conversation**, sent as `session_id`, so a whole conversation is one AI Session |
| `user_header` | the header naming the **end user**, used as `metadata.app_user` when no Kong consumer is authenticated. It labels a scan, it never authenticates one |
| `transaction_header` | lets the caller name the **round**; by default the round is Kong's request id, which the client also gets as `X-Kong-Request-Id` |
| `tool_scan` | `calls` scans the arguments a model generates for a tool call; `catalogue` adds the `tools[]` declaration — expect a source-code detector to flag that one |
| `context_messages` | caps how many recent conversation parts are assembled, to bound cost and stay under the 2 MB scan limit |

With a front-end that already knows its user and its conversation, naming two
headers is the whole integration. Open WebUI, for instance:

```yaml
params:
  session_header: "x-openwebui-chat-id"
  user_header: "x-openwebui-user-email"
```

### Add-on policies

| File | What it does |
|---|---|
| [`airs-diagnostics-log.yaml`](config/kongctl/airs-diagnostics-log.yaml) | writes the guardrail's record — block reason, category, detections, per-phase scan latency, request id — to the node's stdout, so a problem report is one `docker logs`. Has an `enabled` switch and scrubs client credentials |
| [`airs-error-sanitizer.yaml`](config/kongctl/airs-error-sanitizer.yaml) | replaces the `HTTP 500` body returned when Prisma AIRS cannot be consulted with a fixed generic one |

Both have a `config/deck/` counterpart.

### What the client sees

| Status | Meaning |
|---|---|
| `200` | allowed |
| `400` | blocked — `{"error":{"message":"Blocked by Prisma AIRS [scan_id=...]"}}`. The category and detection names never leave the gateway; the `scan_id` finds the full verdict in Strata Cloud Manager |
| `500` | Prisma AIRS could not be consulted, and fail-closed refused rather than pass the request unscanned |

---

## Limitations

Detail and measurements: **[docs/limitations.md](docs/limitations.md)**.

| Limitation | What to do |
|---|---|
| **MCP traffic is not covered at all** | Call Prisma AIRS from outside the gateway |
| **A streamed answer shorter than ~100 bytes is never scanned** — most chat answers | Stop the response streaming where coverage must be guaranteed |
| **A block on a stream arrives after the flagged segment reached the client** | Treat streamed response coverage as best effort |
| **Streamed scans carry no session or round** | Non-streamed exchanges are unaffected |
| **Tool definitions and arguments need `params.tool_scan`** | Turn it on, knowing `catalogue` trips source-code detectors |
| **Prisma AIRS refuses a scan above about 2 MB** | `params.context_messages`, or `text_source: last_message` |

**Prompt scanning is never affected by any of this.** Every row is on the
response leg.

---

## Documentation

| To | Read |
|---|---|
| deploy properly, with rollout and troubleshooting | [deployment-guide.md](docs/deployment-guide.md) |
| know what is not covered | [limitations.md](docs/limitations.md) |
| understand why it is built this way | [design-decisions.md](docs/design-decisions.md) |
| check a claim before repeating it | [verification-status.md](docs/verification-status.md) |
| find the upstream reference behind a field | [sources.md](docs/sources.md) |
| know why this repository exists | [why-this-exists.md](docs/why-this-exists.md) |

Lab procedures: [tool calls](docs/lab-tool-calls.md),
[streaming](docs/lab-streaming.md),
[classic control plane](docs/lab-classic-control-plane.md).

## Repository layout

```
config/kongctl/airs-guardrail.yaml         AI Gateway 2.x
config/deck/airs-guardrail.yaml            classic Gateway control plane
config/*/airs-diagnostics-log.yaml         optional: diagnostics log, on/off switch
config/*/airs-error-sanitizer.yaml         optional: generic body on a scan failure
scripts/test-airs.sh                       five-case validation, needs a live gateway
scripts/run-lua-tests.sh                   offline unit tests for the verdict functions
scripts/check-plugin-schema.py             config parity and schema validation, used in CI
scripts/lab-echo-server.py                 stands in for Prisma AIRS, logs what Kong emits
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
