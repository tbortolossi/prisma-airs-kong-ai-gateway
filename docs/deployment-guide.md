# Deploying Prisma AIRS AI Runtime on Kong AI Gateway 2.x

**Scope:** Konnect AI Gateway 2.x control plane (SaaS), self-managed data planes running in containers.
**Outcome:** every prompt transiting the gateway is scanned by Prisma AIRS AI Runtime (API Intercept) and blocked on policy violation, and so is every LLM response. Models attached to the prompt-and-response policy have response streaming denied at the gateway, so their responses always arrive whole and get scanned in a single call. Models that must stream attach a prompt-only policy instead, so their responses are not covered by response scanning. See Operational considerations for the streaming trade-offs.
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

Use [`config/kongctl/airs-guardrail.yaml`](../config/kongctl/airs-guardrail.yaml) from this repository. The optional [`config/kongctl/airs-error-sanitizer.yaml`](../config/kongctl/airs-error-sanitizer.yaml) can be applied the same way; see "Guardrail failure responses" under Operational considerations for what it changes. Adjust `params.profile` to your Prisma AIRS profile name and `params.app_name` to a label that will identify this gateway in your Prisma AIRS scan logs.

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

That file declares `airs-scan` at the Service level and `airs-prompt-scan` at the Route level, on a dedicated streaming route. The same two levels carry a matching pair of `ai-proxy-advanced` instances: `config.response_streaming: deny` at the Service level, and `config.response_streaming: allow` on the streaming Route ([AI Proxy Advanced reference](https://developer.konghq.com/plugins/ai-proxy-advanced/reference/)). This relies on Kong plugin precedence: a route-level instance of a plugin overrides the service-level instance of the same plugin for requests on that route, so the streaming route allows `stream: true` and gets the `INPUT`-only guardrail coverage, while every other route on the service cannot stream and keeps prompt-and-response coverage. Route it accordingly if you change the paths.

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

Two postures exist, one line apart. **Simple mode:** attach `airs-scan` to every model and leave `response_streaming` at its default, `allow`. Non-streamed responses are scanned whole before delivery; streamed responses get prompt scanning before the model and best-effort, per-segment response scanning that does not slow the stream but cannot stop the segment already delivered. **Strict mode:** attach `airs-scan` together with `config.response_streaming: deny` on models where no unscanned character may reach the client, and `airs-prompt-scan` on models that must stream, with prompt-only coverage stated plainly. See Operational considerations for the measured difference.

```yaml
ai_gateway_models:
  - ref: my-gpt-4o
    ai_gateway: !lookup { id: !env AI_GATEWAY_ID }
    name: my-gpt-4o
    type: model
    formats:
      - type: openai
    config:
      response_streaming: deny   # strict mode; omit the line for simple mode
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

`config.response_streaming: deny` stops the client from setting `stream: true` on this model at all ([AI Gateway streaming](https://developer.konghq.com/ai-gateway/streaming/)), so a model carrying `airs-scan` always returns a complete response for the `OUTPUT` phase to scan. Drop this field, or set it to `allow`, only on a model that attaches `airs-prompt-scan` instead. See Operational considerations for what streamed response scanning looks like if you allow it anyway.

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

**Resilience test:** temporarily block egress to `service.api.aisecurity.paloaltonetworks.com:443` and replay case 1. With the configuration as supplied, expect `HTTP 500` with `{"error":{"message":"failed to sanitize request: failed to invoke custom guardrail service: request failed: connection refused"}}`, not an allowed request. This confirms fail-closed behaviour is genuinely active. See "Guardrail failure responses" under Operational considerations for the other failure shapes.

**Offline check:** `./scripts/run-lua-tests.sh` exercises the verdict functions against the documented Prisma AIRS response shapes without a gateway or network access. Run it after any change to the Lua.

---

## Step 6 — Progressive rollout

1. Attach `airs-prompt-scan` to a single non-production model, with the Prisma AIRS profile in **alert-only**.
2. Run real traffic for several days. Review the scan logs in Strata Cloud Manager and tune the profile there. Profile changes take effect without any Kong redeployment.
3. Switch the Prisma AIRS profile to **block** once the false positive rate is acceptable.
4. Extend `airs-prompt-scan` to the remaining models.
5. On models that do not need to stream, switch from `airs-prompt-scan` to `airs-scan`, and set `config.response_streaming: deny` on the model, to add response scanning. Detach the old policy reference when you attach the new one; do not attach both.

Attach [`config/kongctl/airs-diagnostics-log.yaml`](../config/kongctl/airs-diagnostics-log.yaml) from step 1 and leave it on for the whole rollout. It is what makes the pilot answerable: without a logging policy, a blocked or slow request leaves no trace on the gateway, and the only record is the Prisma AIRS scan log. See "Collecting diagnostics" below.

**Gateway-side monitor mode.** The Prisma AIRS profile's alert-only mode, in step 1, is not the only way to run without enforcing. Setting `continue_on_detection: true` on the guardrail policy does the equivalent at the gateway: a block verdict still calls Prisma AIRS and the scan is still logged in Strata Cloud Manager, but the request is no longer rejected. It passes through with `HTTP 200`. Remove the field, or set it to `false`, to start enforcing. It has no effect on a failed call to Prisma AIRS itself, which `stop_on_error` governs independently. This field, together with `rejection_mode` and `log_blocked_content`, exists on Kong AI Gateway 2.0.1 and later data planes ([AI Gateway changelog](https://developer.konghq.com/ai-gateway/changelog/)) but is not yet in the published plugin schema page, so all three ship commented out in the configuration files.

---

## Operational considerations

**Streaming.** A streamed response is scanned, not skipped, but the coverage is different from a normal response. Under `airs-scan`, the `OUTPUT` phase runs on a `stream: true` response in segments of about `config.response_buffer_size` bytes (schema default 100), and each segment is its own synchronous call to Prisma AIRS. A long stream therefore carries many sequential scans, and each one is scanned without the content that came before it in the same response. Content still below the buffer threshold when the stream ends is never scanned at all, so a short streamed answer can complete having triggered zero scan calls. For example, a 419-character streamed answer was scanned in four segments summing 408 characters; the last 11 characters, holding the answer's final word, were never sent to the guardrail, and the stream completed normally with `HTTP 200`. What happens next depends on the model provider driver. On the `ollama` driver, the stream is cut: no further chunks and no `finish_reason` chunk, on top of an HTTP 200 already sent. On the `openai` driver, the stream ends cleanly: a last chunk carries `finish_reason: "blocked_by_guard"` with the generic block message as its `delta.content`, followed by `data: [DONE]`; under `rejection_mode: verbose` that chunk also carries a `guardrail_result` object (`code: GUARDRAIL_BLOCKED`, reason "response blocked by guardrails"), no category or detection. The flagged segment itself has already reached the client, and the HTTP status is already `200`. A non-streamed response is always scanned in one call carrying the whole body, whatever `response_buffer_size` is set to; the field only matters when the response streams.

The supplied configuration no longer sets `response_buffer_size`, so the schema default of 100 applies. A large value is worse for a streamed response, not safer: a typical short answer stays under a large threshold for its entire duration and is never scanned, which looks like coverage but delivers none. The default gives visible, partial coverage instead of silent, complete gaps.

How much a stream leaks before a block depends on the model's output rate and on the scan latency, because the per-segment scans are asynchronous: they do not slow the stream, so they cannot hold it back either. Measured with a guardrail blocking every segment on a local model producing about 450 characters per second: with a 3 s verdict latency the whole 1005-character answer reached the client and the stream ended normally, every block verdict arriving after the end; with 0.5 s, the order of a Prisma AIRS round trip, about 320 characters reached the client before the cut; with 0.05 s, about 120. Read it as roughly output rate times scan latency, plus one segment.

That gives two postures, one line apart on the AI Model. **Simple mode** leaves `response_streaming` at its default, `allow`: one policy, `airs-scan`, on every model; non-streamed responses are scanned whole before delivery, streamed responses get prompt scanning before the model and best-effort response scanning, every segment logged in Strata Cloud Manager and the stream cut once a verdict says block. **Strict mode** adds `config.response_streaming: deny` ([AI Gateway streaming](https://developer.konghq.com/ai-gateway/streaming/)) on models where no unscanned character may reach the client: a `stream: true` request then gets `HTTP 400` with `{"error":{"message":"response streaming is not enabled for this LLM"}}`, before any guardrail call, and every response that does reach the client has been scanned whole. Under strict mode, models that must stream take `airs-prompt-scan`, prompt-only coverage stated plainly. Prompt scanning itself is unaffected by streaming either way, since it runs before the model is called.

**Block response format.** The supplied configuration leaves `config.rejection_mode` at its default, `none`: a block is `HTTP 400` with `{"error":{"message":"<block_message>"}}`, the contract this guide assumes throughout. Two other values exist on Kong AI Gateway 2.0.1 and later data planes. `verbose` returns `HTTP 403` with a structured body carrying `code: GUARDRAIL_BLOCKED` and the message under `reason`, useful if your client parses a machine-readable code rather than free text. `stealth` returns a generic `HTTP 403` `{"error":{"message":"request forbidden"}}` and drops both the block message and the `scan_id`, which also removes your ability to correlate the block with the Prisma AIRS scan log. `rejection_mode` is not yet in the published plugin schema page, so it ships commented out in both configuration files; read the comment next to it before enabling it.

**Forward proxy.** If your data planes reach the internet through an HTTP forward proxy, `config.proxy_config` exists for that: host and port for HTTP and for HTTPS, optional proxy credentials, and a `no_proxy` list. Both pairs are verified: `http_proxy_host` / `http_proxy_port` relayed both scan calls to a plain-HTTP guardrail, and `https_proxy_host` / `https_proxy_port` carried the supplied configuration to the real Prisma AIRS endpoint through a proxy speaking HTTP CONNECT, with the validation suite passing. Prisma AIRS is reached over HTTPS, so the https pair is the one to set. Proxy credentials (`auth_username` / `auth_password`) and `no_proxy` were not exercised. The field ships commented out for the same reason as `rejection_mode`, above.

**Fail-closed behaviour.** As supplied, a Prisma AIRS outage blocks LLM traffic. This is the appropriate default for a regulated environment, but it is an availability dependency that must be accepted explicitly. Two separate mechanisms cover two separate failures.

`stop_on_error` governs a call to Prisma AIRS that fails outright: the endpoint is unreachable, times out, answers with a non-2xx status, or returns a body Kong cannot decode. As supplied (`true`), any of these returns `HTTP 500` to the client and the request is blocked. Set it to `false` and the same failures pass the traffic through unscanned instead, measured against a live outage.

The `airs_verdict` function governs a call that succeeds but returns a verdict Kong cannot act on: a missing or non-string `action`, or `category: "error"` / `category: "timeout"` arriving alongside `action: "allow"`. These branches currently `return { block = true, ... }`.

As supplied, both mechanisms fail closed, and together they cover both failure modes. A pilot that wants to stay open through a Prisma AIRS outage changes `stop_on_error` to `false` alone. A pilot that also wants to pass through AIRS-degraded verdicts (Prisma AIRS itself reporting `category: "error"` or `"timeout"`) additionally changes the `airs_verdict` branches to `block = false`, in **both** `config/kongctl/airs-guardrail.yaml` and `config/deck/airs-guardrail.yaml`. Treat either as a pilot-only posture, not a shipped default.

**Guardrail failure responses.** Every failure to consult Prisma AIRS reaches the client as `HTTP 500`, whatever `config.rejection_mode` is set to: `rejection_mode` only shapes the response to a *block* verdict, not a failure to obtain one.

| Failure | Client body (`error.message`) |
|---|---|
| Endpoint unreachable | `failed to sanitize request: failed to invoke custom guardrail service: request failed: connection refused` |
| Endpoint does not answer within `config.timeout` | `... request failed: timeout`, honoured to the configured value (measured: 5.0 s at `timeout: 5000`) |
| Endpoint answers with a non-2xx status | `... bad status from guardrail service: <code>, response: <body>`. The guardrail service's own response body is relayed to the client verbatim |
| Endpoint answers `200` with a body that is not valid JSON | `... failed to decode response body: ...` |

The client contract is: `HTTP 400` means the request was blocked by policy. `HTTP 500` means Prisma AIRS could not be consulted and `stop_on_error: true` refused the request rather than let it through unscanned. The `500` body names the guardrail step and the underlying failure to the caller; the optional policy below replaces it with a generic one.

**Returning a generic failure body (optional).** The `500` body above can be replaced with a fixed one by attaching the supplied [`config/kongctl/airs-error-sanitizer.yaml`](../config/kongctl/airs-error-sanitizer.yaml) to the same AI Model as `airs-scan` (`policies: [!ref airs-scan, !ref airs-error-sanitizer]`). It is a [`post-function`](https://developer.konghq.com/plugins/post-function/) policy whose `header_filter` and `body_filter` chunks act only on an `HTTP 500` whose body names the guardrail call; the client then receives `{"error":{"message":"Guardrail unavailable"}}`, while blocks (`HTTP 400`), allowed responses and streamed responses are untouched, and the data plane error log keeps the original text. Two limits: it matches Kong's own wording, so a Kong release that rewords the error makes the policy a no-op rather than a block; and `post-function` is a Kong Gateway Enterprise plugin, present on the AI Gateway data plane image. The classic control plane counterpart, [`config/deck/airs-error-sanitizer.yaml`](../config/deck/airs-error-sanitizer.yaml), is the same plugin on the Service, verified on a classic control plane with a Kong Gateway 3.14.0.14 data plane.

**Latency.** Each scan is a synchronous HTTPS call to Prisma AIRS, bounded by `config.timeout` (5000 ms in the supplied configuration; the plugin default is 10000 ms). `airs-prompt-scan` makes one call per request; `airs-scan` makes two, sequentially — the prompt before the model is called, the complete response after. Measured once, from a data plane in France against the **global** Prisma AIRS endpoint, with an upstream model answering in about 30 ms: median 73 ms with no policy, 577 ms with `airs-prompt-scan`, 876 ms with `airs-scan`. The guardrail plugin itself accounts for about 3 ms; the rest is the call to Prisma AIRS. Treat this as one data point rather than a specification — the TCP connection to that endpoint completes in about 25 ms, so the delay is dominated by the scan and its backhaul, not by the first network hop, and it will differ on your path. Measure your own before fixing a latency budget, and if your tenant offers a regional endpoint, measure it against the global one rather than assuming which is faster.

**Capacity.** Every data plane replica opens its own connections to Prisma AIRS, so scan volume scales with your autoscaling. Size this against your Prisma AIRS tenant quota before load testing.

**Conversation size.** The whole conversation is sent on every turn, as the context the last element is judged against. That is what catches multi-turn prompt injection, and it costs scanned text per call: money, latency, and eventually the [2 MB maximum payload size per synchronous scan request](https://pan.dev/prisma-airs/api/airuntimesecurity/airuntimesecurityapi/). Switching `text_source` to `last_message` narrows the scan to the final message alone. With `params.tool_scan` enabled, `params.context_messages` caps how many of the most recent conversation parts are assembled; leave it out to send everything, which is what the configuration ships with. What happens at the limit is measured: Kong forwards the whole text without truncating it, a prompt just above 2 MB was still scanned, and a 3.5 MB one received HTTP 413 from Prisma AIRS, \"The request body is too large\", which `stop_on_error: true` turns into an `HTTP 500` for the client, the 413 body relayed. A conversation that outgrows the limit is therefore refused, not passed unscanned.

**Observability.** The client-facing message and the internal record are deliberately different: the client sees only "Blocked by Prisma AIRS" and, when present, the `scan_id`, while the category and the detection names stay internal. Rely on the **Prisma AIRS scan logs in Strata Cloud Manager**, correlated by `scan_id`; that channel is verified end to end and remains the primary record.

On the Kong side, attach a logging policy to the AI Model alongside `airs-scan`. The supplied [`config/kongctl/airs-diagnostics-log.yaml`](../config/kongctl/airs-diagnostics-log.yaml) does this with `file-log` writing to the data plane's standard output, so the record lands in `docker logs` / `kubectl logs` with no volume to mount and no collector to stand up; see "Collecting diagnostics" below. Each request's log record then carries an `ai.proxy.custom-guardrail` entry with `input_block_reason` / `output_block_reason` (the generic client-facing message, with `scan_id` when present), `input_block_detail` / `output_block_detail` (category, reason, detections), the block source, and processing latencies, together with an `ai.proxy.guardrail_triggered` entry naming the block direction. Both are documented in the [AI Gateway audit log reference](https://developer.konghq.com/ai-gateway/ai-audit-log-reference/). A blocked request's log record looks like this:

```json
"custom-guardrail": {
  "mode": "BOTH",
  "input_block_reason": "Blocked by Prisma AIRS [scan_id=<scan_id>]",
  "input_block_detail": {"category": "malicious", "reason": "malicious: injection", "detections": ["injection"]},
  "input_block_source": "ai-custom-guardrail",
  "input_block_consumer_id": "unknown",
  "output_block_reason": "", "output_block_source": "", "output_block_consumer_id": "",
  "input_processing_latency": 595, "output_processing_latency": 0
},
"guardrail_triggered": {
  "blocked_content": "",
  "block_source": "ai-custom-guardrail",
  "block_direction": "AI_GUARDRAIL_BLOCK_INPUT"
}
```

The two latency fields are the ones that matter on an allowed request. `input_processing_latency` and `output_processing_latency` carry the real cost of each scan in milliseconds on every request, blocked or not — measured at 632 ms and 454 ms from a data plane in France against the global Prisma AIRS endpoint — so this record is where a complaint about slowness is answered. The rest of the guardrail fields are populated only on a block: an allowed request has no `scan_id` here, because Prisma AIRS returns one per scan and nothing carries it back into the log when there is nothing to block.

The Konnect Requests analytics view does not carry this detail: its records hold only the AI Proxy entry (tokens, latency, model), not the guardrail fields above. The data plane's own access log is a third place a request is visible, but it shows only the status and `kong_request_id` — enough to find the matching log record, not to explain a block.

### Collecting diagnostics

Attach [`config/kongctl/airs-diagnostics-log.yaml`](../config/kongctl/airs-diagnostics-log.yaml) (classic control plane: [`config/deck/airs-diagnostics-log.yaml`](../config/deck/airs-diagnostics-log.yaml)) to the same AI Model or Service as `airs-scan`:

```bash
kongctl apply -f config/kongctl/airs-guardrail.yaml \
              -f config/kongctl/airs-diagnostics-log.yaml \
              -f <your-model>.yaml
```

Repeated `-f` flags share one reference namespace, so the model's `policies: [!ref airs-scan, !ref airs-diagnostics-log]` resolves across the files. The policy carries its own on/off switch: set `enabled: false` and re-apply to silence it without detaching it, `true` to restore it. It ships enabled, because a log that is off cannot explain an incident that has already happened.

From then on, one JSON record per request goes to the data plane's standard output, and reporting a problem is one command:

```bash
docker logs --since 30m <data-plane-container>     # or
kubectl logs --since=30m <data-plane-pod>
```

When opening a case, send:

| Item | Where |
|---|---|
| The data plane log over the window of the problem | `docker logs` / `kubectl logs` as above — it carries both the JSON records and the guardrail call failures |
| The `X-Kong-Request-Id` of an affected request | Returned to the client on every response, and present as `request.id` in the log record. This is the handle that ties a user's complaint to a record |
| The `scan_id`, if the request was blocked | In the client's `HTTP 400` body, and in `input_block_reason` / `output_block_reason`. Looks up the full detection detail in Strata Cloud Manager |
| The applied configuration | `kongctl get ai-gateway policies --gateway-id <id>` — it also prints an `ENABLED` column, which is how you check the switch took effect. On a classic control plane, `deck gateway dump`. Redact nothing by hand: the API key is a vault reference, not a value |
| The data plane version | `kong version` inside the container |
| The output of `scripts/test-airs.sh` | Establishes whether the gateway is broken for all traffic or only for the reported case |

**Before handing this procedure to an operator, read one captured record.** Kong's log serializer includes request and response headers, so a credential your clients send to the gateway would be written to the node's log. The supplied policy removes `Authorization`, `x-api-key`, `apikey`, `Cookie` and `Set-Cookie` — verified on a request carrying all of them, none of which reached the record — but if your clients authenticate with a header of another name, add it to `config.custom_fields_by_lua` as `request.headers.<name>: "return nil"`. The record carries no prompt and no model output: the serializer logs no bodies, and `blocked_content` stays empty as long as the guardrail's own `log_blocked_content` is left `false`, as shipped.

For permanent collection rather than incident capture, use `http-log` against your own collector with the same `custom_fields_by_lua` block; the record is identical.

**Composition with other policies.** Kong's AI Gateway catalogue also offers `ai-sanitizer`, for PII redaction, and `ai-prompt-guard`. Placing `ai-sanitizer` ahead of the guardrail in the chain would send Prisma AIRS redacted text instead of the original: less PII leaves your environment, but Prisma AIRS's own data-loss-prevention detections then have nothing left to inspect. This is a deployment choice to weigh, not a recommendation made here. See the [AI Gateway Policies catalogue](https://developer.konghq.com/ai-gateway/policies/) for the policy names; this guide does not state an execution order between them, since plugin priority for `ai-custom-guardrail` is not published.

**What is sent to Prisma AIRS.** Each scan carries one `contents[]` element, holding the text `text_source` selected. That single element is deliberate. The [scan API](https://pan.dev/prisma-airs/api/airuntimesecurity/scan/scan-sync-request/) describes `contents` as a list in which "the last element is the one that needs to be scanned, and the previous elements are the context for the scan", and measurement against a live tenant shows that literally: an injection placed anywhere but in the last element comes back `allow` / `benign`. Splitting a conversation into one element per message therefore reads like the schema's intent and silently stops scanning every turn but the newest. Everything that must be scanned goes in the element that is sent last.

**Each turn is attributed.** `text_source` joins the conversation's message content with no indication of who said what, and that alone gets ordinary conversation blocked. Measured on a live tenant: the two-turn exchange "What is the capital of France? / The capital of France is Paris. / And Italy?" was blocked as prompt injection, three times out of three — the assistant's own answer, arriving unattributed inside the prompt, reads as an assertion planted there. The threat report's snippet showed exactly that text. The supplied configuration therefore rebuilds the scanned text from the request body with each turn prefixed `user:` or `assistant:`; the same exchange is then benign, and an injection still blocks whether it is the newest turn or an earlier one.

The system message is deliberately **not** prefixed. Writing `system:` into scanned text is the shape of a system-prompt spoof, and doing so gets the whole conversation blocked as injection, while the same content unlabelled is benign. Tool results and any unrecognised role go in unlabelled for the same reason.

Where the request body cannot be read — a streamed response's `OUTPUT` segments have no request context, and a provider whose body is not OpenAI-shaped has no `messages[]` — the text falls back to what `text_source` selected, unattributed, as before.

**Scanning tool calls (optional).** Tool definitions and the arguments a model generates for a tool call never appear in `$(content)`, under any `text_source` — so by default a tool call is scanned only on its way back in, as the text of its result. Set `params.tool_scan` to bring them in:

| Value | What is scanned |
|---|---|
| absent, or any other value | the `text_source` selection alone. This is the default |
| `calls` | the conversation rebuilt from the request body in chronological order, with the arguments of each tool call appended |
| `catalogue` | the above, plus the `tools[]` declaration the caller sent — the tool-poisoning surface |

Measured on a live tenant, with the guardrail in `INPUT` mode so only the prompt leg could act: a conversation whose injection sat solely inside a tool call's arguments was allowed 5 times out of 5 with `tool_scan` unset, and blocked 5 times out of 5 with `tool_scan: "calls"`. The full test suite passes either way.

Two cautions before enabling `catalogue`. A JSON parameter schema reads as source code to a profile with that detector on, and a tool declaration is a JSON parameter schema — expect it to be flagged until the profile is tuned. And tool text counts against the 2 MB payload limit like any other text.

**How a scan is labelled.****How a scan is labelled.** `metadata` carries four fields, all optional and all omitted when they cannot be built:

| Field | Value |
|---|---|
| `app_name` | `params.app_name`, the label identifying this gateway |
| `ai_model` | the AI Model serving the request |
| `user_ip` | the client address as Kong sees it |
| `app_user` | the authenticated Kong consumer, or the `params.user_header` request header when no consumer is authenticated |

Two cautions. **`user_ip` is the address Kong considers the client's**, which is the `X-Forwarded-For` value only when the peer is listed in the data plane's `trusted_ips`; behind a load balancer that is not trusted, the record shows the balancer rather than the end user. And **the user header is caller-controlled**: it labels a scan, it never authenticates one, which is why an authenticated consumer always wins over it. Set `params.user_header` to the header your application already sends, or leave it unused.

**Scan correlation.** The supplied configuration sends the correlation identifiers the [scan API](https://pan.dev/prisma-airs/api/airuntimesecurity/scan/scan-sync-request/) accepts, so that Strata Cloud Manager can reassemble what the gateway saw. They nest, and they are not interchangeable:

| Identifier | What it identifies | Value sent |
|---|---|---|
| `transaction_id` | **one round** — a prompt and the response it produced | Kong's own request id, the same value the client receives as `X-Kong-Request-Id`, or the `x-airs-transaction-id` request header when the caller names the round itself |
| `session_id` | **the conversation** grouping several rounds | the `x-airs-session-id` request header, falling back to the round when the caller names no conversation |

The consequence that matters: under `airs-scan` the prompt scan and the response scan of one exchange now carry the same round identifier and the same session, so they appear as one exchange rather than as two unrelated single-scan sessions. Grouping several exchanges into one conversation needs the caller's help, because nothing in the gateway knows where a conversation starts or ends — an application that sends one `x-airs-session-id` per conversation gets its whole conversation in the AI Sessions view.

`tr_id` is deliberately not sent. Measured against a live tenant: `tr_id` is the older name of `session_id`, not of `transaction_id` — a request carrying only `tr_id` comes back with `session_id` set to that value, and when both are supplied `session_id` wins. Sending the round under it would place the round identifier in the session slot and give one session per exchange.

Both header names are `config.params` values (`transaction_header`, `session_header`) — point them at whatever your application already sends rather than changing the application. A header that is absent, empty, longer than 256 characters, or not a string is ignored, and the identifier falls back as described above.

Two limits worth stating to the application team. **Segments of a streamed response carry no identifier at all**: on the `OUTPUT` phase of a stream the guardrail function has no request context, so those scans appear unattached, as every scan did before. And **`session_id` is only as good as what the caller sends**: an application that reuses one value for all its traffic collapses every scan into a single conversation, which is less useful than no grouping at all. One value per conversation is the intent.

---

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| Policy rejected at apply time on `guarding_mode` | A value other than `BOTH`, `INPUT` or `OUTPUT` | Use `airs-scan` (`BOTH`) for prompt and response, or `airs-prompt-scan` (`INPUT`) for streaming models |
| Policy rejected at apply time on `request.body` | Nested YAML under `request.body` | Body values must be strings. Build nested JSON with a function that returns a Lua table |
| Second guardrail instance rejected at apply time (deck) | Two `ai-custom-guardrail` instances declared on the same Service or the same Route | Kong keys a plugin instance uniquely per scope. Attach exactly one of `airs-scan` / `airs-prompt-scan` per scope |
| Two policies attached to one AI Model, and coverage is not what you expect (kongctl) | AI Gateway 2.x **accepts** two `ai-custom-guardrail` policies on one model, but only one executes, and not the one declaration order suggests — with both attached, the `INPUT` policy ran | Attach exactly one. Check with `GET /v1/ai-gateways/<id>/models` and read the `policies` array |
| The streaming route still gets response scanning | The route-level `airs-prompt-scan` instance is missing, disabled, or the route inherits the service-level `airs-scan` instead | Confirm a route-level `ai-custom-guardrail` instance is present and enabled on the streaming route — a route-level instance overrides the service-level one for that route only when it exists |
| Every request rejected, including test case 1, with `HTTP 500` and `failed to invoke custom guardrail service: ...` | Egress to the Prisma AIRS endpoint not permitted, or the endpoint answering an error, before any verdict is reached | Check the data plane log for the exact guardrail connection error. Verify prerequisite 4 from inside a data plane container |
| `HTTP 500` `failed to invoke custom guardrail service: request failed: connection refused` / `timeout` / `bad status from guardrail service` | Prisma AIRS unreachable, slower than `config.timeout`, or answering an error status. `stop_on_error: true` refuses the request rather than let it through unscanned | Check egress, the endpoint URL, the regional endpoint, and Prisma AIRS tenant status |
| Traffic passes through during a Prisma AIRS outage | `stop_on_error: false` | Fail-open by design. See "Fail-closed behaviour" above. Revert to `true` to restore enforcement |
| `401` from Prisma AIRS in the data plane logs | The vault reference did not resolve, and the literal string was sent as the token | Confirm `AIRS_TOKEN` is set in the container and that the revision was applied. Fall back to a managed vault backend if needed |
| `401` from the LLM provider (deck variant) | `OPENAI_KEY` holds the bare key instead of the full header value | `ai-proxy-advanced`'s `auth.header_value` expects the complete value, for example `Bearer <key>`. Store the scheme in the secret, not just the key |
| `404` or profile error from Prisma AIRS | `params.profile` does not match the profile name in Strata Cloud Manager | Correct the value and re-apply |
| Policies applied but nothing is scanned | Policies not attached to the model, or no AI Proxy in the chain | Check the `policies` array on the AI Model, or set `global: true`. Confirm AI Proxy or AI Proxy Advanced is configured |
| A streamed response gets only partial scanning, or none at all | Streamed content still below `config.response_buffer_size` when the stream ends is never scanned; a large buffer value hides this over an entire short answer | Deny streaming on `airs-scan` models (`config.response_streaming: deny`), or attach `airs-prompt-scan` to models that must stream. See Operational considerations |
| Data plane logs `metric ... block_detail has unexpected type string, expected table` | `config.metrics.block_detail` resolved to a string instead of a table | Return `detail` as a table from `airs_verdict` (`reason`, `category`, `detections`), as supplied |
| `stream: true` gets `HTTP 400` `{"error":{"message":"response streaming is not enabled for this LLM"}}` | Expected: the model has `config.response_streaming: deny` and the client asked to stream | Attach `airs-prompt-scan` to that model instead of `airs-scan`, or set `response_streaming: allow` if response coverage is not required |
| Prompt and response scans of one exchange look unrelated in Strata Cloud Manager | The scans came from a streamed response, where the `OUTPUT` segments carry no identifier | Expected. Non-streamed exchanges share a `tr_id`; see "Scan correlation" above |
| A streamed exchange shows a prompt scan and no response scan at all | The whole answer was shorter than `config.response_buffer_size` (schema default 100 bytes), so the `OUTPUT` phase never ran. Short chat answers are the common case, not an edge case | Expected under simple mode, and visible in the diagnostics log: a 32-character streamed answer records `output_processing_latency: 0`, a 1315-character one records 574 ms. Use strict mode on models where every response must be scanned |
| AI Sessions groups nothing, or shows one entry per round | The caller is not sending a session header, so no conversation is claimed | Set `params.session_header` to the header your application already sends, or have it send `x-airs-session-id`, one value per conversation |
| An ordinary multi-turn conversation is blocked as prompt injection | The scanned text reached Prisma AIRS unattributed — the streamed `OUTPUT` path, or a provider whose body is not OpenAI-shaped, so the fallback applied | Expected on those paths. On the normal path each turn is prefixed `user:` / `assistant:`, which is what keeps it benign. See "Each turn is attributed" above |
| A chat UI's own housekeeping calls are blocked | Many chat front-ends make extra completions per conversation — title, tags, follow-up suggestions — whose prompt templates end in a JSON output specification such as `JSON format: { "tags": ["tag1"] }`. A profile with the source-code detector on blocks all of them | Measured behaviour, not a gateway fault. Either tune the profile or turn those features off in the front-end. The user's own messages are unaffected |
| Legitimate traffic blocked | Security profile too aggressive for the traffic. A frequent case on the response leg: the model answers with a code snippet and the profile detects source code (category `source_code` in the scan log) | Tune the profile in Strata Cloud Manager. No Kong change required |
| No JSON record in `docker logs` / `kubectl logs` after attaching the diagnostics log | The policy is declared but `enabled: false`, or it was never added to the model's `policies` list | `kongctl get ai-gateway policies --gateway-id <id>` prints an `ENABLED` column. Check the model's `policies` array carries `!ref airs-diagnostics-log`, and that the apply used one `kongctl apply` invocation with a `-f` per file so the reference resolves |
| A client credential appears in the log record | The client authenticates with a header the supplied `custom_fields_by_lua` does not remove | Add `request.headers.<name>: "return nil"` to `config.custom_fields_by_lua` and re-apply. Read one record before handing the procedure to an operator |
| A scan record's prompt holds the whole conversation as one paragraph | Expected: one scan is one judged element, so the conversation is sent as one text. `text_source` joins it newest-first; `params.tool_scan` rebuilds it chronologically | See "What is sent to Prisma AIRS" above |
| Tool-call arguments do not appear in the scan record | `params.tool_scan` is unset, and no `text_source` exposes them | Set it to `calls`. The tool *result* is scanned either way, as the text of its message |
| `metadata.user_ip` shows a load balancer rather than the end user | The peer is not in the data plane's `trusted_ips`, so Kong does not honour `X-Forwarded-For` | Add the balancer to `trusted_ips` on the data plane |
| `metadata.app_user` is absent | No Kong consumer is authenticated and the caller sends no `params.user_header` header | Either is enough; the consumer wins when both are present |
| `HTTP 500` with `bad status from guardrail service: 413` | The concatenated conversation exceeds the Prisma AIRS payload limit per scan (about 2 MB) | Shorten the history the application sends, or switch `text_source` to `last_message` and accept the coverage loss |

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
- Kong, AI Proxy Advanced configuration reference (`auth.header_value`, `response_streaming`): https://developer.konghq.com/plugins/ai-proxy-advanced/reference/
- Kong, AI Gateway streaming (`config.response_streaming` on the AI Model): https://developer.konghq.com/ai-gateway/streaming/
- Kong, AI Gateway changelog (`rejection_mode`, `continue_on_detection`, `log_blocked_content`): https://developer.konghq.com/ai-gateway/changelog/
- Kong, Vault entity and backends: https://developer.konghq.com/gateway/entities/vault/
- Palo Alto Networks, Prisma AIRS AI Runtime API Intercept: https://pan.dev/prisma-airs/api/airuntimesecurity/airuntimesecurityapi/
- Palo Alto Networks, Kong integration assets: https://github.com/PaloAltoNetworks/prisma-airs-integrations

---

*Validate this configuration in a non-production environment before applying it to production traffic.*
