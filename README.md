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
| MCP | ❌ | Kong exposes no guardrail on MCP traffic |
| Any upstream LLM provider | ✅ | No provider list to maintain: Kong normalises the exchange before the guardrail runs |
| Non-OpenAI client formats | ⚠️ | Scanned either way. Turn attribution needs a string `messages[].content`, which `anthropic` provides and a block array does not |

Full matrix — capabilities, control planes, request formats:
**[docs/coverage.md](docs/coverage.md)**.

## Install

Four things, all four required:

1. put the Prisma AIRS key on the data planes as `AIRS_TOKEN`,
2. set your security profile name in
   [`config/kongctl/airs-guardrail.yaml`](config/kongctl/airs-guardrail.yaml),
3. `kongctl apply -f config/kongctl/airs-guardrail.yaml`,
4. **attach one policy to your AI Model** — `airs-scan`, or `airs-prompt-scan`
   for a model that must stream. Never both.

Then `./scripts/test-airs.sh`: one allowed case, three blocked, one streaming
probe.

Steps 2 and 4 are the ones that get missed, and they fail in opposite
directions — the placeholder profile blocks everything, a policy that is not
attached passes everything unscanned.

Commands, prerequisites and every optional setting:
**[docs/install.md](docs/install.md)**.

## Limitations

| | |
|---|---|
| MCP traffic is not covered at all | the restriction is Kong's, not Prisma AIRS's |
| A streamed answer shorter than ~100 bytes is never scanned | which is most chat answers |
| A block on a stream arrives after the flagged segment reached the client | streamed response coverage is best effort |
| Prisma AIRS refuses a scan above about 2 MB | cap the history with `params.context_messages` |

**Prompt scanning is never affected by any of this** — every row is on the
response leg.

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
