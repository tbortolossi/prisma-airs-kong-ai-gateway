# Install and configure

Four things, all four required:

1. put the Prisma AIRS key on the data planes,
2. export your deployment values where `kongctl` runs,
3. apply the policies,
4. **attach one of them to your AI Model.**

Step 4 is the one that gets missed: a policy that is not attached passes
everything unscanned. A wrong profile name in step 2 fails the other way and
blocks everything. Step 5 tells them apart in one run.

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

## 2. Export your deployment values

Do not edit
[`config/kongctl/airs-guardrail.yaml`](../config/kongctl/airs-guardrail.yaml).
Every value that differs from one deployment to the next is read from an
environment variable by `kongctl` at apply time, through its
[`!env` tag](https://developer.konghq.com/kongctl/declarative/). Set them on the
machine or pipeline that runs `kongctl` — not on the data planes:

| Variable | Set it to | Typical value |
|---|---|---|
| `AIRS_PROFILE` | your security profile name, exactly | — no default. A wrong name makes **every request fail closed** |
| `AIRS_APP_NAME` | a label for this gateway in your scan logs | `kong-ai-gateway` |
| `AIRS_SESSION_HEADER` | the request header your application uses for the conversation id | `x-airs-session-id` |
| `AIRS_TRANSACTION_HEADER` | the request header naming one round, if your application sends one | `x-airs-transaction-id` |
| `AIRS_USER_HEADER` | the request header carrying the end user | `x-airs-user` |
| `AIRS_SCAN_URL` | the Prisma AIRS scan endpoint | `https://service.api.aisecurity.paloaltonetworks.com/v1/scan/sync/request`, or your regional endpoint |

```bash
export AIRS_PROFILE="<your security profile name>"
export AIRS_APP_NAME="kong-ai-gateway"
export AIRS_SESSION_HEADER="x-airs-session-id"
export AIRS_TRANSACTION_HEADER="x-airs-transaction-id"
export AIRS_USER_HEADER="x-airs-user"
export AIRS_SCAN_URL="https://service.api.aisecurity.paloaltonetworks.com/v1/scan/sync/request"
```

All six are required. If one is unset, `kongctl` stops before sending anything
(`environment variable not set: AIRS_PROFILE`), so a missing value can never
overwrite a live one. A header your application does not send is harmless:
the gateway falls back to its own identifiers — see "Optional settings" below.

These are the values stored in the policy in clear text; they are not secrets.
The API key is not among them: it stays a vault reference, resolved on the
data plane (step 1).

## 3. Apply

`kongctl` reads the token from `KONGCTL_DEFAULT_KONNECT_PAT` in the
environment, so it never appears on the command line, where any process on
the host could read it via `ps`.

```bash
export KONGCTL_DEFAULT_KONNECT_PAT="<konnect pat>"
export AI_GATEWAY_ID="<ai gateway id>"

kongctl apply -f config/kongctl/airs-guardrail.yaml
```

This creates the policies. It does **not** put them in the request path.

Read the result back to check the values landed:

```bash
kongctl get ai-gateway policies --gateway-id "$AI_GATEWAY_ID" airs-scan -o json
```

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
[deployment guide](deployment-guide.md). `deck` only substitutes variables
prefixed with `DECK_`, so the same six values are exported as
`DECK_AIRS_PROFILE`, `DECK_AIRS_APP_NAME` and so on.

## Updating to a new version

1. Replace `config/kongctl/airs-guardrail.yaml` with the new file, as is.
2. Re-run step 3 with the same six variables exported.
3. Read the policy back (step 3) and re-run `./scripts/test-airs.sh`.

Your values live in your environment, not in the file, so there is nothing to
merge.

**Coming from a version that carried the values in the file** (`profile:
"kong-airs-prod"` and so on): read your current values from the live policy
before the first update, and export them. With `jq`, one command does it:

```bash
eval "$(kongctl get ai-gateway policies --gateway-id "$AI_GATEWAY_ID" airs-scan -o json | jq -r '
  .config as $c | {
    AIRS_PROFILE: $c.params.profile,
    AIRS_APP_NAME: $c.params.app_name,
    AIRS_SESSION_HEADER: $c.params.session_header,
    AIRS_TRANSACTION_HEADER: $c.params.transaction_header,
    AIRS_USER_HEADER: $c.params.user_header,
    AIRS_SCAN_URL: $c.request.url
  } | to_entries[] | "export \(.key)=\(.value | @sh)"')"

env | grep ^AIRS_     # six lines, none of them "null"
```

It maps `config.params.profile`, `.app_name`, `.session_header`,
`.transaction_header`, `.user_header` and `config.request.url` onto the six
variables. A value that prints `null` is a field your live policy does not
have yet: export it by hand with the typical value from step 2.

With the same values exported, the apply reports `No changes detected` on those
fields and updates only what changed in the new version.

> [!NOTE]
> `kongctl apply` updates a value that changed, but does not remove a key that
> is on the live policy and absent from the file. If you added an optional key
> by hand (for example `rejection_mode` or `tool_scan`) and want it gone, set it
> back to its default value explicitly, or remove it in the Konnect UI.

---

## Optional settings

### `params`, all off unless the caller sends the header

| Key | What it turns on |
|---|---|
| `session_header` | the header naming the **conversation**, sent as `session_id`, so a whole conversation is one AI Session |
| `user_header` | the header naming the **end user**, used as `metadata.app_user` when no Kong consumer is authenticated. It labels a scan, it never authenticates one |
| `transaction_header` | lets the caller name the **round**; by default the round is Kong's request id, which the client also gets as `X-Kong-Request-Id` |
| `tool_scan` | `calls` scans the arguments a model generates for a tool call; `catalogue` adds the `tools[]` declaration — expect a source-code detector to flag that one |
| `context_messages` | caps how many recent conversation parts are assembled, to bound cost and stay under the 2 MB scan limit |

`session_header`, `transaction_header` and `user_header` are set from
`AIRS_SESSION_HEADER`, `AIRS_TRANSACTION_HEADER` and `AIRS_USER_HEADER` (step
2). `tool_scan` and `context_messages` ship commented out in the file.

With a front-end that already knows its user and its conversation, naming two
headers is the whole integration. Open WebUI, for instance:

```bash
export AIRS_SESSION_HEADER="x-openwebui-chat-id"
export AIRS_USER_HEADER="x-openwebui-user-email"
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
