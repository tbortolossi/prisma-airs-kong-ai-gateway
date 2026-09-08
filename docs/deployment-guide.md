# Deploying Prisma AIRS AI Runtime on Kong AI Gateway 2.x

**Scope:** Konnect AI Gateway 2.x control plane (SaaS), self-managed data planes running in containers.
**Outcome:** every prompt transiting the gateway is scanned by Prisma AIRS AI Runtime (API Intercept) and blocked on policy violation, and so is every non-streamed LLM response. A request that sets `stream: true` is not response-scanned: Kong skips the `OUTPUT` phase entirely, with no error and no warning. Scope your deployment around that before you start — see Operational considerations.
**Change footprint:** two declarative policy objects and one environment variable. No custom plugin, no data plane image rebuild, no application code change.

---

## How it works

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

`airs-scan` and `airs-prompt-scan` both use the `ai-custom-guardrail` policy type, which is Kong's supported extension point for calling an external guardrail service over HTTP. Exactly one of them is attached to a given AI Model. Enforcement happens inline in the data plane, in your own infrastructure. Only the text to be scanned leaves your environment, and it goes directly to your Prisma AIRS tenant.

---

## Prerequisites

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

## Step 1 — Prepare Prisma AIRS

In Strata Cloud Manager:

1. Go to **Insights → AI Runtime Security → API Intercept** and create an AI Runtime Security API application. Copy the generated API key. This is the value of the `x-pan-token` header.
2. Create an **API security profile** and enable the detections you want to enforce: prompt injection, sensitive data (DLP), malicious URLs, toxic content, malicious code, database security as applicable.
3. Note the **exact profile name**. It must match the `params.profile` value in the policy configuration.
4. Set the profile to **alert-only** for the initial rollout. You will switch it to block in Step 6, after measuring false positives on real traffic.

---

## Step 2 — Provision the API key on the data planes

The policy configuration never contains the key in clear text. It carries a reference, `{vault://env/airs-token}`, which Kong resolves at runtime against the environment variable `AIRS_TOKEN` on the data plane. The reference sits in `request.auth.value`, the schema slot meant for a guardrail credential: it is referenceable, so the vault reference resolves, and it is stored encrypted. Keeping the key out of `config.params` also keeps it out of the `conf` table that guardrail functions receive.

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

## Step 3 — Apply the AI Policies

Use [`config/kongctl/airs-guardrail.yaml`](../config/kongctl/airs-guardrail.yaml) from this repository. Adjust `params.profile` to your Prisma AIRS profile name and `params.app_name` to a label that will identify this gateway in your Prisma AIRS scan logs.

Three things in that file are worth understanding before you apply it.

**Two policies exist, one per model.** `airs-scan` runs `guarding_mode: BOTH`: it scans the prompt in its `INPUT` phase and the model output in its `OUTPUT` phase. `airs-prompt-scan` runs `guarding_mode: INPUT` and scans the prompt only — attach it to models that serve streaming responses. A single request-body function reads `$(source)` (`INPUT` or `OUTPUT`) to decide whether it is building `contents[].prompt` or `contents[].response`, since Prisma AIRS keys the two differently. Attach exactly one of the two policies per AI Model; do not attach both to the same model.

**The request body is a flat map of strings.** `ai-custom-guardrail` does not accept nested YAML under `request.body`. The nested Prisma AIRS payload is produced by small Lua functions that return a table, which the plugin serialises into JSON:

```yaml
      request:
        body:
          ai_profile: "$(airs_profile)"
          metadata: "$(airs_metadata)"
          contents: "$(airs_contents)"

      functions:
        airs_profile: |
          return function(conf)
            return { profile_name = conf.params.profile }
          end

        airs_contents: |
          return function(source, content)
            if source == "INPUT" then return { { prompt = content } } end
            return { { response = content } }
          end
```

A function is referenced **bare**, `$(airs_contents)`, never called with
arguments. The plugin injects its built-ins **by parameter name**: declare
`(source, content)` and you receive the phase and the text to scan, declare
`(conf)` and you receive the plugin configuration, declare `(resp)` and you
receive the guardrail service response. Any other parameter name is rejected
with *argument '<name>' is not allowed in guardrail functions*, and calling a
function with explicit arguments produces HTTP 500 and *failed to render by
function: invalid expression syntax* on every request.

**Two mechanisms enforce fail-closed, and you need both.** `stop_on_error: true` covers the case where the call to Prisma AIRS itself fails — timeout, TLS error, non-2xx. The `airs_verdict` function covers the case where Prisma AIRS answers but the verdict is unusable, including `category: "error"` and `category: "timeout"`, which AIRS returns with `action: "allow"`.

Apply it:

```bash
export KONNECT_PAT="<your Konnect personal access token>"
export AI_GATEWAY_ID="<your AI Gateway id>"

kongctl apply -f config/kongctl/airs-guardrail.yaml --pat "$KONNECT_PAT"
```

`kongctl` addresses the US Konnect API by default. If your organisation is in
another geo, pass it explicitly, or every call returns `404 Not Found` on a
gateway id that plainly exists:

```bash
kongctl apply -f config/kongctl/airs-guardrail.yaml --pat "$KONNECT_PAT" \
  --base-url https://eu.api.konghq.com
```

At this point the policies exist but are not yet enforcing anything. They take effect once attached in Step 4.

### Classic Gateway control plane

If your control plane is a classic Gateway control plane rather than an AI Gateway 2.x one, use [`config/deck/airs-guardrail.yaml`](../config/deck/airs-guardrail.yaml) instead. The `config` block is identical; only the wrapper differs.

That file declares `airs-scan` at the Service level and `airs-prompt-scan` at the Route level, on a dedicated streaming route. This relies on Kong plugin precedence: a route-level instance of a plugin overrides the service-level instance of the same plugin for requests on that route, so the streaming route gets the `INPUT`-only variant while the rest of the service keeps prompt-and-response coverage. Route it accordingly if you change the paths.

**`deck gateway sync` deletes everything not in the file you give it.** Any configuration already in your Gateway that is not present in the declarative file is removed. Never run a bare sync of this repository's file against a control plane that already has other Services, Routes or plugins configured. Two safe paths:

1. Preview first, always:

   ```bash
   deck gateway diff config/deck/airs-guardrail.yaml \
     --konnect-token "$KONNECT_PAT" \
     --konnect-control-plane-name "<control plane name>"
   ```

   Review every deletion it reports before running `sync`.

2. Scope the sync to a tag, or merge the plugin blocks into your existing state file. Add a tag to the entities you own and pass `--select-tag` so `sync` only manages entities carrying that tag, leaving the rest of the control plane alone. Alternatively, copy the `ai-custom-guardrail` plugin blocks from this file into your own declarative state file rather than syncing this file standalone.

The `ai-proxy-advanced` block in this file expects `OPENAI_KEY` to hold the **full** auth header value, including the scheme — `auth.header_value` is documented as "the full auth header value for 'header_name', for example 'Bearer key' or just 'key'". Store the secret behind `{vault://env/openai-key}` as `Bearer <your key>`, not the bare key.

```bash
deck gateway sync config/deck/airs-guardrail.yaml \
  --konnect-token "$KONNECT_PAT" \
  --konnect-control-plane-name "<control plane name>"
```

---

## Step 4 — Attach a policy to your AI Model

Add **one** reference to the `policies` array of the AI Model you want to protect, then re-apply that model definition. Do not reference both policies on the same model: Kong runs a single instance of a given plugin per request, so a second guardrail reference does not add coverage, and `airs-scan` already covers both directions.

Use `airs-scan` for models that return a complete response, and `airs-prompt-scan` for models that serve streaming responses, which are not response-scanned in any case — see Operational considerations.

```yaml
ai_gateway_models:
  - ref: my-gpt-4o
    ai_gateway: !lookup { id: !env AI_GATEWAY_ID }
    name: my-gpt-4o
    type: model
    formats:
      - type: openai
    policies:
      - !ref airs-scan            # prompt and response
      # - !ref airs-prompt-scan   # prompt only, for streaming models
    targets:
      - name: gpt-4o
        provider: generic-openai
        config:
          type: openai
    capabilities:
      - generate
```

A `!ref` resolves only against resources declared in the **same applied
document**. Applying the model on its own leaves the reference unresolved, and
the model keeps whatever policy it already had — quietly, with the apply
reporting success. Apply the policies and the model together:

```bash
cat config/kongctl/airs-guardrail.yaml ai-model.yaml \
  | kongctl apply -f - --pat "$KONNECT_PAT"
```

Then confirm what is actually attached, rather than trusting the apply output:

```bash
curl -s -H "Authorization: Bearer $KONNECT_PAT" \
  "https://eu.api.konghq.com/v1/ai-gateways/$AI_GATEWAY_ID/models" \
  | jq -r '.data[] | "\(.name): \(.policies)"'
```

The control plane pushes the change to all connected data planes within seconds. No restart is required.

To protect every model on the gateway with the same policy instead, declare that one policy with `global: true` rather than referencing it per model.

---

## Step 5 — Validate

**Before pointing this at your real Prisma AIRS key, capture what the policy actually sends.** Point `request.url` at a throwaway echo endpoint and a disposable token, apply that variant, send one request, and inspect the payload the plugin emitted — in particular the shape of `contents[]`. This confirms the configuration builds the request you expect before your production credential and your production prompts are involved. Revert `request.url` and the token once satisfied.

Then run the supplied `test-airs.sh` against the real endpoint, or issue the calls manually.

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
| 2 | Prompt injection / jailbreak attempt | rejected |
| 3 | Payment card data in the prompt | rejected |
| 4 | Malicious URL in the prompt | rejected |
| 5 | Legitimate security-related question | allowed, `200` |

Case 5 matters as much as the blocking cases. It is the one that reveals an over-aggressive security profile, and it is the case most often omitted from a proof of concept.

**Block responses carry no detection detail.** A rejected request receives the generic message "Blocked by Prisma AIRS", optionally followed by "[scan_id=...]" — never the category or the detection name, including on a fail-closed block. The category and the detection names are not lost: they are recorded in Kong's own metrics and in the Prisma AIRS scan logs in Strata Cloud Manager, both keyed by `scan_id`. Correlate the `scan_id` from the response with Strata Cloud Manager to see the full detection detail and to confirm the end-to-end path. `test-airs.sh` treats a response as a guardrail block only when its body carries the "Prisma AIRS" marker, and prints the distinct HTTP status codes it observed across the run. A block returns **HTTP 400**, with the body `{"error":{"message":"Blocked by Prisma AIRS [scan_id=...]"}}`; handle that status on the client side as a policy rejection rather than a gateway fault.

**Resilience test:** temporarily block egress to `service.api.aisecurity.paloaltonetworks.com:443` and replay case 1. With the configuration as supplied, the request must be rejected, not allowed. This confirms fail-closed behaviour is genuinely active.

**Offline check:** `./scripts/run-lua-tests.sh` exercises the verdict functions against the documented Prisma AIRS response shapes without a gateway or network access. Run it after any change to the Lua.

---

## Step 6 — Progressive rollout

1. Attach `airs-prompt-scan` to a single non-production model, with the Prisma AIRS profile in **alert-only**.
2. Run real traffic for several days. Review the scan logs in Strata Cloud Manager and tune the profile there. Profile changes take effect without any Kong redeployment.
3. Switch the Prisma AIRS profile to **block** once the false positive rate is acceptable.
4. Extend `airs-prompt-scan` to the remaining models.
5. On models that do not serve streaming responses, switch from `airs-prompt-scan` to `airs-scan` to add response scanning. Detach the old policy reference when you attach the new one — do not attach both.

---

## Operational considerations

**Streaming.** A request that sets `stream: true` is not response-scanned. The `OUTPUT` phase is skipped entirely: the guardrail service receives no call, the complete stream reaches the client, and no error is raised. Prompt scanning still applies, so a streaming request keeps `INPUT` coverage and loses `OUTPUT` coverage, silently. Decide which of the two you want: either refuse `stream: true` at the gateway or in your client contract and keep `airs-scan` everywhere, or attach `airs-prompt-scan` to streaming models and record that those models have prompt-only coverage. What you must not do is attach `airs-scan` to a streaming model and assume the response is inspected. `config.response_buffer_size` (default 100 bytes, set to 65536 here) governs how much of a buffered, non-streamed response is accumulated before the guardrail call; it has no effect on a streamed response.

**Fail-closed behaviour.** As supplied, a Prisma AIRS outage blocks LLM traffic. This is the appropriate default for a regulated environment, but it is an availability dependency that must be accepted explicitly. Failing open requires two coordinated changes, made together, in **both** `config/kongctl/airs-guardrail.yaml` and `config/deck/airs-guardrail.yaml`:

1. Set `stop_on_error: false` on the policy, so a failed call to Prisma AIRS no longer blocks by itself.
2. In every `airs_verdict` function, change the fail-closed branches — the ones that currently `return { block = true, ... }` when the verdict is missing, malformed, or carries `category: "error"` / `category: "timeout"` — to `block = false`, and alert on the condition instead of blocking on it.

Either change alone still blocks: `stop_on_error: false` only stops the plugin's own error handling from blocking, while the Lua still fails closed on an unusable verdict, and vice versa. Treat this as a pilot-only posture, not a shipped default.

**Latency.** Each scan is a synchronous HTTPS call to Prisma AIRS, bounded by `config.timeout` (5000 ms in the supplied configuration; the plugin default is 10000 ms). `airs-prompt-scan` makes one call per request; `airs-scan` makes two, sequentially — the prompt before the model is called, the complete response after. Measured once, from a data plane in France against the **global** Prisma AIRS endpoint, with an upstream model answering in about 30 ms: median 73 ms with no policy, 577 ms with `airs-prompt-scan`, 876 ms with `airs-scan`. The guardrail plugin itself accounts for about 3 ms; the rest is the call to Prisma AIRS. Treat this as one data point rather than a specification — the TCP connection to that endpoint completes in about 25 ms, so the delay is dominated by the scan and its backhaul, not by the first network hop, and it will differ on your path. Measure your own before fixing a latency budget, and if your tenant offers a regional endpoint, measure it against the global one rather than assuming which is faster.

**Capacity.** Every data plane replica opens its own connections to Prisma AIRS, so scan volume scales with your autoscaling. Size this against your Prisma AIRS tenant quota before load testing.

**`text_source` trade-off.** The supplied configuration uses `concatenate_all_content`, which re-scans the entire conversation on every turn. This catches multi-turn prompt injection that `last_message` would miss, at the cost of scanning more text per call — cost, added latency, and the risk of hitting the [2 MB maximum payload size per synchronous scan request](https://pan.dev/prisma-airs/api/airuntimesecurity/airuntimesecurityapi/) on long conversations. If your conversations grow large, weigh switching to `last_message` against the coverage you would lose.

**Observability.** The client-facing message and the internal record are deliberately different: the client sees only "Blocked by Prisma AIRS" and, when present, the `scan_id`, while the category and the detection names stay internal. Rely on the **Prisma AIRS scan logs in Strata Cloud Manager**, correlated by `scan_id` — that channel is verified end to end. The configuration also routes the detail to `config.metrics.block_reason` and `config.metrics.block_detail`; those fields apply cleanly, but nothing guardrail-related was observed on the data plane's own metrics endpoint, including with the Prometheus policy and `ai_metrics` enabled, whose AI families cover LLM requests, cost and tokens rather than guardrail counters. Confirm in Konnect analytics before depending on them. Kong data plane logs remain the third place a block is visible.

**Scan correlation.** The supplied configuration sends no correlation identifier to Prisma AIRS. The scan API accepts three optional ones — `tr_id`, `session_id` and `transaction_id` — and when none is supplied, Prisma AIRS [generates one per atomic API call](https://docs.paloaltonetworks.com/ai-runtime-security/administration/api-intercept-create-configure-security-profile/use-the-ai-sessions-and-application-views). Two consequences in Strata Cloud Manager: under `airs-scan`, the prompt scan and the response scan of the same exchange appear as two unrelated entries, and the AI Sessions view groups nothing, since sessions are built from calls sharing a transaction ID. Each scan remains individually complete and correctly attributed to the profile and the application, so blocking and profile tuning are unaffected; what is unavailable is per-conversation and per-exchange grouping. Supplying an identifier is not a configuration change — a guardrail function has no access to any per-request value, so any identifier it produced would be either constant across all traffic or different in each of the two phases. Correlation requires the guardrail service to hold that state, which is the reference sidecar on the roadmap. Until then, correlate on `scan_id` from the Kong-side record.

---

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| Policy rejected at apply time on `guarding_mode` | A value other than `BOTH`, `INPUT` or `OUTPUT` | Use `airs-scan` (`BOTH`) for prompt and response, or `airs-prompt-scan` (`INPUT`) for streaming models |
| Policy rejected at apply time on `request.body` | Nested YAML under `request.body` | Body values must be strings. Build nested JSON with a function that returns a Lua table |
| Second guardrail instance rejected at apply time (deck) | Two `ai-custom-guardrail` instances declared on the same Service or the same Route | Kong keys a plugin instance uniquely per scope. Attach exactly one of `airs-scan` / `airs-prompt-scan` per scope |
| Two policies attached to one AI Model, and coverage is not what you expect (kongctl) | AI Gateway 2.x **accepts** two `ai-custom-guardrail` policies on one model, but only one executes, and not the one declaration order suggests — with both attached, the `INPUT` policy ran | Attach exactly one. Check with `GET /v1/ai-gateways/<id>/models` and read the `policies` array |
| The streaming route still gets response scanning | The route-level `airs-prompt-scan` instance is missing, disabled, or the route inherits the service-level `airs-scan` instead | Confirm a route-level `ai-custom-guardrail` instance is present and enabled on the streaming route — a route-level instance overrides the service-level one for that route only when it exists |
| Every request rejected, including test case 1 | Egress to the Prisma AIRS endpoint not permitted, or the guardrail call failing before a verdict | Check the data plane log for a guardrail connection error and `metrics.block_detail` for `verdict unavailable (fail-closed)`. Verify prerequisite 4 from inside a data plane container |
| `401` from Prisma AIRS in the data plane logs | The vault reference did not resolve, and the literal string was sent as the token | Confirm `AIRS_TOKEN` is set in the container and that the revision was applied. Fall back to a managed vault backend if needed |
| `401` from the LLM provider (deck variant) | `OPENAI_KEY` holds the bare key instead of the full header value | `ai-proxy-advanced`'s `auth.header_value` expects the complete value, for example `Bearer <key>`. Store the scheme in the secret, not just the key |
| `404` or profile error from Prisma AIRS | `params.profile` does not match the profile name in Strata Cloud Manager | Correct the value and re-apply |
| Policies applied but nothing is scanned | Policies not attached to the model, or no AI Proxy in the chain | Check the `policies` array on the AI Model, or set `global: true`. Confirm AI Proxy or AI Proxy Advanced is configured |
| A streamed response is never scanned, and nothing signals it | `stream: true` skips the `OUTPUT` phase entirely, whichever policy is attached | Refuse `stream: true` where response coverage is required, or attach `airs-prompt-scan` and record the model as prompt-only |
| Prompt and response scans of one exchange look unrelated in Strata Cloud Manager, and AI Sessions groups nothing | No correlation identifier is sent, so Prisma AIRS creates one per call | Expected with a configuration-only deployment. See "Scan correlation" above; correlate on `scan_id` in the meantime |
| Legitimate traffic blocked | Security profile too aggressive | Tune the profile in Strata Cloud Manager. No Kong change required |

---

## References

- Kong, AI Custom Guardrail plugin: https://developer.konghq.com/plugins/ai-custom-guardrail/
- Kong, AI Custom Guardrail configuration reference: https://developer.konghq.com/plugins/ai-custom-guardrail/reference/
- Kong, AI Gateway Policies: https://developer.konghq.com/ai-gateway/policies/
- Kong, AI Policy entity: https://developer.konghq.com/ai-gateway/entities/ai-policy/
- Kong, Plugin entity (precedence, one instance per request): https://developer.konghq.com/gateway/entities/plugin/
- Kong, declarative configuration with kongctl: https://developer.konghq.com/kongctl/declarative/
- Kong, kongctl README (`--pat`, `KONGCTL_DEFAULT_KONNECT_PAT`): https://github.com/Kong/kongctl
- Kong, deck gateway sync: https://developer.konghq.com/deck/gateway/sync/
- Kong, deck tags and `--select-tag`: https://developer.konghq.com/deck/gateway/tags/
- Kong, AI Proxy Advanced configuration reference (`auth.header_value`): https://developer.konghq.com/plugins/ai-proxy-advanced/reference/
- Kong, Vault entity and backends: https://developer.konghq.com/gateway/entities/vault/
- Palo Alto Networks, Prisma AIRS AI Runtime API Intercept: https://pan.dev/prisma-airs/api/airuntimesecurity/airuntimesecurityapi/
- Palo Alto Networks, Kong integration assets: https://github.com/PaloAltoNetworks/prisma-airs-integrations

---

*Validate this configuration in a non-production environment before applying it to production traffic.*
