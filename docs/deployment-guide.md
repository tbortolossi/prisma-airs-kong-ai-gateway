# Deploying Prisma AIRS AI Runtime on Kong AI Gateway 2.x

**Scope:** Konnect AI Gateway 2.x control plane (SaaS), self-managed data planes running in containers.
**Outcome:** every prompt and every LLM response transiting the gateway is scanned by Prisma AIRS AI Runtime (API Intercept) and blocked on policy violation.
**Change footprint:** two declarative policy objects and one environment variable. No custom plugin, no data plane image rebuild, no application code change.

---

## 1. How it works

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

Both policies use the `ai-custom-guardrail` policy type, which is Kong's supported extension point for calling an external guardrail service over HTTP. Enforcement happens inline in the data plane, in your own infrastructure. Only the text to be scanned leaves your environment, and it goes directly to your Prisma AIRS tenant.

---

## 2. Prerequisites

Validate all five before starting. Each has a one-line check.

| # | Requirement | How to verify |
|---|---|---|
| 1 | Data planes on Kong Gateway 3.14 or later | `kong version` inside a data plane container, or the Data Plane Nodes view in Konnect |
| 2 | AI licence active on the control plane | `ai-custom-guardrail` appears in the control plane policy catalogue |
| 3 | An AI Model already defined and serving traffic, backed by AI Proxy or AI Proxy Advanced | A successful `curl` against your gateway proxy URL |
| 4 | Outbound HTTPS from the data planes to `service.api.aisecurity.paloaltonetworks.com:443` | `curl -sv https://service.api.aisecurity.paloaltonetworks.com` from inside a data plane container |
| 5 | `kongctl` installed and authenticated with a Konnect PAT | `kongctl --version` |

> **Requirement 3 is not optional.** `ai-custom-guardrail` extends AI Proxy. It does not work standalone.

> **Requirement 4 is the one that fails most often.** In a VNet-integrated container environment, egress usually traverses a NAT gateway or an outbound firewall. Because the configuration below fails closed, an unreachable Prisma AIRS endpoint will block LLM traffic rather than let it through. Get this allowed before you apply anything.

> **If your data planes are below 3.14**, `ai-custom-guardrail` is not available. An alternative exists using the `request-callout` plugin (Kong Gateway 3.10+), limited to prompt scanning and the OpenAI chat completion format. Raise this with your Kong and Palo Alto Networks contacts before proceeding.

If your Prisma AIRS tenant is not on the global endpoint, replace the URL in every step below with your regional endpoint.

---

## 3. Step 1 — Prepare Prisma AIRS

In Strata Cloud Manager:

1. Go to **Insights → AI Runtime Security → API Intercept** and create an AI Runtime Security API application. Copy the generated API key. This is the value of the `x-pan-token` header.
2. Create an **API security profile** and enable the detections you want to enforce: prompt injection, sensitive data (DLP), malicious URLs, toxic content, malicious code, database security as applicable.
3. Note the **exact profile name**. It must match the `params.profile` value in the policy configuration.
4. Set the profile to **alert-only** for the initial rollout. You will switch it to block in Step 6, after measuring false positives on real traffic.

---

## 4. Step 2 — Provision the API key on the data planes

The policy configuration never contains the key in clear text. It carries a reference, `{vault://env/airs-token}`, which Kong resolves at runtime against the environment variable `AIRS_TOKEN` on the data plane. `config.params` is a referenceable field, so the substitution happens there.

This uses Kong's built-in environment variable backend. **No external secret manager or Vault product is required, and no Vault entity needs to be created.** The reference name is uppercased and hyphens become underscores, so `airs-token` maps to `AIRS_TOKEN`.

The key is therefore resolved inside your own infrastructure. It never transits the SaaS control plane and never appears in version-controlled configuration.

### Azure Container Apps

```bash
# Store the key as an application secret
az containerapp secret set \
  --name <data-plane-app> \
  --resource-group <resource-group> \
  --secrets airs-token=<PRISMA_AIRS_API_KEY>

# Expose it to the container as an environment variable
az containerapp update \
  --name <data-plane-app> \
  --resource-group <resource-group> \
  --set-env-vars AIRS_TOKEN=secretref:airs-token
```

This generates one new revision. It is the only moment the data planes restart during this deployment.

Key rotation later is a secret update plus a revision, with no change to the Kong configuration.

### Kubernetes

```bash
kubectl create secret generic prisma-airs \
  --from-literal=airs-token=<PRISMA_AIRS_API_KEY> \
  -n <namespace>
```

Then reference it in the data plane deployment:

```yaml
env:
  - name: AIRS_TOKEN
    valueFrom:
      secretKeyRef:
        name: prisma-airs
        key: airs-token
```

### Alternatives

If your organisation requires a managed secret store, Kong supports Azure Key Vault, AWS Secrets Manager, GCP Secret Manager, HashiCorp Vault and the Konnect Config Store as vault backends. Create the corresponding Vault entity and replace the reference with, for example, `{vault://azure/airs-token}`. The rest of this procedure is unchanged.

---

## 5. Step 3 — Apply the AI Policies

Use [`config/kongctl/airs-guardrail.yaml`](../config/kongctl/airs-guardrail.yaml) from this repository. Adjust `params.profile` to your Prisma AIRS profile name and `params.app_name` to a label that will identify this gateway in your Prisma AIRS scan logs.

Three things in that file are worth understanding before you apply it.

**`guarding_mode` is `INPUT` on one policy and `OUTPUT` on the other.** The plugin also accepts `BOTH`, but Prisma AIRS keys prompts and responses differently — `contents[].prompt` versus `contents[].response` — so each direction needs its own request body. That is why there are two policies rather than one.

**The request body is a flat map of strings.** `ai-custom-guardrail` does not accept nested YAML under `request.body`. The nested Prisma AIRS payload is produced by small Lua functions that return a table, which the plugin serialises into JSON:

```yaml
      request:
        body:
          ai_profile: "$(airs_profile)"
          metadata: "$(airs_metadata)"
          contents: "$(airs_contents(content))"

      functions:
        airs_profile: |
          return function(conf)
            return { profile_name = conf.params.profile }
          end
```

**Two mechanisms enforce fail-closed, and you need both.** `stop_on_error: true` covers the case where the call to Prisma AIRS itself fails — timeout, TLS error, non-2xx. The `airs_verdict` function covers the case where Prisma AIRS answers but the verdict is unusable, including `category: "error"` and `category: "timeout"`, which AIRS returns with `action: "allow"`.

Apply it:

```bash
export KONNECT_PAT="<your Konnect personal access token>"
export AI_GATEWAY_ID="<your AI Gateway id>"

kongctl apply -f config/kongctl/airs-guardrail.yaml --pat "$KONNECT_PAT"
```

At this point the policies exist but are not yet enforcing anything. They take effect once attached in Step 4.

### Classic Gateway control plane

If your control plane is a classic Gateway control plane rather than an AI Gateway 2.x one, use [`config/deck/airs-guardrail.yaml`](../config/deck/airs-guardrail.yaml) instead. The `config` block is identical; only the wrapper differs.

```bash
deck gateway sync config/deck/airs-guardrail.yaml \
  --konnect-token "$KONNECT_PAT" \
  --konnect-control-plane-name "<control plane name>"
```

---

## 6. Step 4 — Attach the policies to your AI Model

Add the two references to the `policies` array of the AI Model you want to protect, then re-apply that model definition.

```yaml
ai_gateway_models:
  - ref: my-gpt-4o
    ai_gateway: !lookup { id: !env AI_GATEWAY_ID }
    name: my-gpt-4o
    type: model
    formats:
      - type: openai
    policies:
      - !ref airs-prompt-scan
      - !ref airs-response-scan
    targets:
      - name: gpt-4o
        provider: generic-openai
        config:
          type: openai
    capabilities:
      - generate
```

```bash
kongctl apply -f ai-model.yaml --pat "$KONNECT_PAT"
```

The control plane pushes the change to all connected data planes within seconds. No restart is required.

To protect every model on the gateway instead, declare the policies with `global: true` rather than referencing them per model.

---

## 7. Step 5 — Validate

Run the supplied `test-airs.sh`, or issue the calls manually.

```bash
export KONG_PROXY_URL="https://<your gateway proxy url>"
export CLIENT_KEY="<your client credential>"
export MODEL_NAME="my-gpt-4o"

./scripts/test-airs.sh
```

Expected outcome:

| Case | Prompt | Expected |
|---|---|---|
| 1 | Benign technical question | allowed, `200` |
| 2 | Prompt injection / jailbreak attempt | rejected, with an injection reason |
| 3 | Payment card data in the prompt | rejected, with a DLP reason |
| 4 | Malicious URL in the prompt | rejected, with a URL category reason |
| 5 | Legitimate security-related question | allowed, `200` |

Case 5 matters as much as the blocking cases. It is the one that reveals an over-aggressive security profile, and it is the case most often omitted from a proof of concept.

Every block message carries a `scan_id`. Correlate it with the scan logs in Strata Cloud Manager to confirm the end-to-end path and to see the full detection detail.

**Resilience test:** temporarily block egress to `service.api.aisecurity.paloaltonetworks.com:443` and replay case 1. With the configuration as supplied, the request must be rejected, not allowed. This confirms fail-closed behaviour is genuinely active.

**Offline check:** `./scripts/run-lua-tests.sh` exercises the verdict functions against the documented Prisma AIRS response shapes without a gateway or network access. Run it after any change to the Lua.

---

## 8. Step 6 — Progressive rollout

1. Attach `airs-prompt-scan` only, to a single non-production model, with the Prisma AIRS profile in **alert-only**.
2. Run real traffic for several days. Review the scan logs in Strata Cloud Manager and tune the profile there. Profile changes take effect without any Kong redeployment.
3. Switch the Prisma AIRS profile to **block** once the false positive rate is acceptable.
4. Extend to the remaining models.
5. Add `airs-response-scan` last, and **only on models that do not serve streaming responses**.

---

## 9. Operational considerations

**Streaming.** Response scanning requires the gateway to buffer the response before it can be evaluated. `config.response_buffer_size` controls how much is accumulated before each call to the guardrail service. If your applications consume server-sent events, either they lose streaming on protected routes, or you enforce prompt scanning only. Decide this before the rollout rather than during it.

**Fail-closed behaviour.** As supplied, a Prisma AIRS outage blocks LLM traffic. This is the appropriate default for a regulated environment, but it is an availability dependency that must be accepted explicitly. For a pilot phase, set `stop_on_error: false` and change `block = true` to `block = false` in the fail-closed branches of both `airs_verdict` functions, then alert on the condition instead. Both changes are required: either one alone still blocks.

**Latency.** Each scan is a synchronous HTTPS call to Prisma AIRS, bounded by `config.timeout` (5000 ms in the supplied configuration; the plugin default is 10000 ms). Budget for it in your end-to-end latency targets. Enforcing both prompt and response scanning means two calls per LLM request.

**Capacity.** Every data plane replica opens its own connections to Prisma AIRS, so scan volume scales with your autoscaling. Size this against your Prisma AIRS tenant quota before load testing.

**Observability.** Blocked requests are visible in three places: the Kong data plane logs, the AI Gateway metrics, and the Prisma AIRS scan logs in Strata Cloud Manager. The `scan_id` in the block message is the correlation key across all three. `config.metrics.block_reason` and `config.metrics.block_details` can be set if you want the reason recorded in Kong's own logs.

---

## 10. Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| Policy rejected at apply time on `guarding_mode` | A value other than `BOTH`, `INPUT` or `OUTPUT` | Use `INPUT` for the prompt scan and `OUTPUT` for the response scan |
| Policy rejected at apply time on `request.body` | Nested YAML under `request.body` | Body values must be strings. Build nested JSON with a function that returns a Lua table |
| All requests blocked with "scan unavailable" | Egress to the Prisma AIRS endpoint not permitted | Verify prerequisite 4 from inside a data plane container |
| `401` from Prisma AIRS in the data plane logs | The vault reference did not resolve, and the literal string was sent as the token | Confirm `AIRS_TOKEN` is set in the container and that the revision was applied. Fall back to a managed vault backend if needed |
| `404` or profile error from Prisma AIRS | `params.profile` does not match the profile name in Strata Cloud Manager | Correct the value and re-apply |
| Policies applied but nothing is scanned | Policies not attached to the model, or no AI Proxy in the chain | Check the `policies` array on the AI Model, or set `global: true`. Confirm AI Proxy or AI Proxy Advanced is configured |
| Streaming responses break after enabling response scanning | Response buffering | Detach `airs-response-scan` from streaming models |
| Legitimate traffic blocked | Security profile too aggressive | Tune the profile in Strata Cloud Manager. No Kong change required |

---

## 11. References

- Kong, AI Custom Guardrail plugin: https://developer.konghq.com/plugins/ai-custom-guardrail/
- Kong, AI Custom Guardrail configuration reference: https://developer.konghq.com/plugins/ai-custom-guardrail/reference/
- Kong, AI Gateway Policies: https://developer.konghq.com/ai-gateway/policies/
- Kong, AI Policy entity: https://developer.konghq.com/ai-gateway/entities/ai-policy/
- Kong, declarative configuration with kongctl: https://developer.konghq.com/kongctl/declarative/
- Kong, Vault entity and backends: https://developer.konghq.com/gateway/entities/vault/
- Palo Alto Networks, Prisma AIRS AI Runtime API Intercept: https://pan.dev/prisma-airs/api/airuntimesecurity/airuntimesecurityapi/
- Palo Alto Networks, Kong integration assets: https://github.com/PaloAltoNetworks/prisma-airs-integrations

---

*Validate this configuration in a non-production environment before applying it to production traffic.*
