# Prisma AIRS on Kong AI Gateway

Enforce **Prisma AIRS AI Runtime (API Intercept)** as an inline guardrail on
**Kong AI Gateway**, where a custom Lua plugin can no longer be loaded.

**Configuration only** — no Lua plugin, no data plane image rebuild. Enforcement
runs on your own data planes; only the text to be scanned leaves them, straight
to your Prisma AIRS tenant.

Fails closed by default, scans both legs, attributes every turn so ordinary
conversation is not read as an injection, and correlates each scan to its
conversation and its round.

*Community assets from an individual contributor. Not an official Palo Alto
Networks or Kong product, no support commitment from either vendor. MIT
licence — see [Disclaimer](#disclaimer).*

```
   Client app ──► Kong AI Gateway data plane ──► your LLM provider
                        │           ▲
                        │  prompt   │  response
                        ▼           │
                  Prisma AIRS  /v1/scan/sync/request
                     allow → through     block → HTTP 400
```

## Coverage

| Scanning phase | | |
|---|:--:|---|
| Prompt | ✅ | Before the model is called, on every path |
| Response | ✅ | Not streamed: one scan of the whole body, before the client sees it |
| Streaming | ⚠️ | Segments of ~100 bytes. An answer shorter than one segment is **not scanned** |
| Pre-tool call | ⚠️ | Generated tool arguments, via `params.tool_scan`. Ships off |
| Post-tool call | ✅ | Tool results scanned on return |
| MCP, prompt leg | ⚠️ | No guardrail extension point, but `request-callout` reaches the scope and can enforce a block on the request |
| MCP, tool results and catalogues | ❌ | `request-callout`'s hooks all run before the call to the upstream MCP server |
| Any upstream LLM provider | ✅ | No provider list to maintain: Kong normalises the exchange before the guardrail runs |
| Non-OpenAI client formats | ⚠️ | Scanned either way. Turn attribution needs a string `messages[].content`, which `anthropic` provides and a block array does not |

Full matrix — capabilities, control planes, request formats:
**[docs/coverage.md](docs/coverage.md)**.

## Install

Four things, all four required:

1. put the Prisma AIRS key on the data planes as `AIRS_TOKEN`,
2. export your deployment values where `kongctl` runs — the file itself is
   never edited:
   ```bash
   export AIRS_PROFILE="<your security profile name>"
   export AIRS_APP_NAME="kong-ai-gateway"
   export AIRS_SESSION_HEADER="x-airs-session-id"
   export AIRS_TRANSACTION_HEADER="x-airs-transaction-id"
   export AIRS_USER_HEADER="x-airs-user"
   export AIRS_SCAN_URL="https://service.api.aisecurity.paloaltonetworks.com/v1/scan/sync/request"
   ```
3. `kongctl apply -f config/kongctl/airs-guardrail.yaml`,
4. **attach one policy to your AI Model** — `airs-scan`, or `airs-prompt-scan`
   for a model that must stream. Never both.

Then `./scripts/test-airs.sh`: one allowed case, three blocked, one streaming
probe.

Step 4 is the one that gets missed: a policy that is not attached passes
everything unscanned. A missing variable in step 2 cannot slip through — the
apply stops before anything is sent.

### Updating an existing deployment

Replace the file, apply it with the same variables. Nothing to merge.

```bash
# 1. Download the current policy file
curl -fsSLo airs-guardrail.yaml \
  https://raw.githubusercontent.com/tbortolossi/prisma-airs-kong-ai-gateway/main/config/kongctl/airs-guardrail.yaml

# 2. Konnect access
export KONGCTL_DEFAULT_KONNECT_PAT="<konnect pat>"
export AI_GATEWAY_ID="<ai gateway id>"

# 3. First update from a file that carried the values: read them off the live policy
kongctl get ai-gateway policies --gateway-id "$AI_GATEWAY_ID" airs-scan -o json
#   config.params.profile            -> AIRS_PROFILE
#   config.params.app_name           -> AIRS_APP_NAME
#   config.params.session_header     -> AIRS_SESSION_HEADER
#   config.params.transaction_header -> AIRS_TRANSACTION_HEADER
#   config.params.user_header        -> AIRS_USER_HEADER
#   config.request.url               -> AIRS_SCAN_URL

# 4. Export them (the same six variables as step 2 above)
export AIRS_PROFILE="<value of config.params.profile>"
export AIRS_APP_NAME="<value of config.params.app_name>"
export AIRS_SESSION_HEADER="<value of config.params.session_header>"
export AIRS_TRANSACTION_HEADER="<value of config.params.transaction_header>"
export AIRS_USER_HEADER="<value of config.params.user_header>"
export AIRS_SCAN_URL="<value of config.request.url>"

# 5. Apply (add --base-url https://eu.api.konghq.com for an EU organisation)
kongctl apply -f airs-guardrail.yaml

# 6. Read back, then validate
kongctl get ai-gateway policies --gateway-id "$AI_GATEWAY_ID" airs-scan -o json
./scripts/test-airs.sh
```

With the same values exported, the apply changes only what the new version
changed. `kongctl apply` does not remove a key that is on the live policy but
absent from the file: an optional key added by hand stays until it is set back
explicitly or removed in the Konnect UI.

Commands, prerequisites and every optional setting:
**[docs/install.md](docs/install.md)**.

## Limitations

| | |
|---|---|
| MCP tool results and catalogues are not covered | `request-callout` reaches the MCP scope, but its hooks run only before the call to the upstream server |
| A streamed answer shorter than ~100 bytes is never scanned | which is most chat answers |
| A block on a stream arrives after the flagged segment reached the client | streamed response coverage is best effort |
| Prisma AIRS refuses a scan above about 2 MB | cap the history with `params.context_messages` |

**Prompt and response scanning on the chat completion path are never affected
by any of this** — the streaming and payload-size rows are on the response
leg, and the MCP row is a separate traffic path that this configuration does
not touch at all.

Detail and measurements: **[docs/limitations.md](docs/limitations.md)**.

## Documentation

| To | Read |
|---|---|
| install it | [install.md](docs/install.md) |
| deploy it for real, with rollout and troubleshooting | [deployment-guide.md](docs/deployment-guide.md) |
| see what is covered | [coverage.md](docs/coverage.md) |
| know what is not | [limitations.md](docs/limitations.md) |
| understand why it is built this way | [design-decisions.md](docs/design-decisions.md) |
| check a claim before repeating it | [verification-status.md](docs/verification-status.md) |
| find the upstream reference behind a field | [sources.md](docs/sources.md) |
| know why this repository exists | [why-this-exists.md](docs/why-this-exists.md) |

Lab procedures: [tool calls](docs/lab-tool-calls.md),
[streaming](docs/lab-streaming.md),
[classic control plane](docs/lab-classic-control-plane.md).

## Repository layout

```
config/kongctl/airs-guardrail.yaml    AI Gateway 2.x
config/deck/airs-guardrail.yaml       classic Gateway control plane
config/*/airs-diagnostics-log.yaml    optional: diagnostics log, on/off switch
config/*/airs-error-sanitizer.yaml    optional: generic body on a scan failure
scripts/test-airs.sh                  five-case validation, needs a live gateway
scripts/run-lua-tests.sh              111 offline assertions on the verdict functions
scripts/check-plugin-schema.py        config parity and schema validation, used in CI
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
