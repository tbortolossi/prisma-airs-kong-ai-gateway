# Install and configure

Four things, all four required:

1. put the Prisma AIRS key on the data planes,
2. set your security profile name in the YAML,
3. apply the policies,
4. **attach one of them to your AI Model.**

Steps 2 and 4 are the ones that get missed, and they fail in opposite
directions: the placeholder profile blocks everything, a policy that is not
attached passes everything unscanned. Step 5 tells them apart in one run.

For a production rollout — progressive enablement, the classic control plane
variant, troubleshooting — read [deployment-guide.md](deployment-guide.md)
instead.

## Prerequisites

| | |
|---|---|
| Kong Gateway data planes | 3.14 or later, with an AI licence |
| Existing chain | `ai-proxy` or `ai-proxy-advanced` — `ai-custom-guardrail` does not work standalone |
| Prisma AIRS | An API Intercept application and a named security profile |
| Network | Outbound HTTPS to `service.api.aisecurity.paloaltonetworks.com:443` |

Below 3.14 the plugin does not exist; an upstream `request-callout` variant
covers prompt scanning only.

## 1. Put the key on the data planes

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

## 2. Set two values in the YAML

In `params`, on both policies in
[`config/kongctl/airs-guardrail.yaml`](../config/kongctl/airs-guardrail.yaml):

| Key | Set it to | Ships as |
|---|---|---|
| `profile` | your security profile name, exactly | `kong-airs-prod` — a placeholder. Leave it and **every request fails closed** |
| `app_name` | a label for this gateway in your scan logs | `kong-ai-gateway` |

Not on the global endpoint? Change `request.url` too. It is the only place.

## 3. Apply

```bash
export KONNECT_PAT="<konnect pat>"
export AI_GATEWAY_ID="<ai gateway id>"

kongctl apply -f config/kongctl/airs-guardrail.yaml --pat "$KONNECT_PAT"
```

This creates the policies. It does **not** put them in the request path.

## 4. Attach one policy to your AI Model

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

## 5. Validate

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
[`config/deck/airs-guardrail.yaml`](../config/deck/airs-guardrail.yaml) and the
[deployment guide](deployment-guide.md).

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
| [`airs-diagnostics-log.yaml`](../config/kongctl/airs-diagnostics-log.yaml) | writes the guardrail's record — block reason, category, detections, per-phase scan latency, request id — to the node's stdout, so a problem report is one `docker logs`. Has an `enabled` switch and scrubs client credentials |
| [`airs-error-sanitizer.yaml`](../config/kongctl/airs-error-sanitizer.yaml) | replaces the `HTTP 500` body returned when Prisma AIRS cannot be consulted with a fixed generic one |

Both have a `config/deck/` counterpart.

### What the client sees

| Status | Meaning |
|---|---|
| `200` | allowed |
| `400` | blocked — `{"error":{"message":"Blocked by Prisma AIRS [scan_id=...]"}}`. The category and detection names never leave the gateway; the `scan_id` finds the full verdict in Strata Cloud Manager |
| `500` | Prisma AIRS could not be consulted, and fail-closed refused rather than pass the request unscanned |

---
