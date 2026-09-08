# Canonical sources

Every configuration assertion in this repository must trace back to one of these
references, or carry the `SYNTHESIZED` tag. Do not introduce a Kong or Prisma
AIRS configuration field that is not backed by a page listed here.

## Kong — the guardrail extension point

| Reference | Used for |
|---|---|
| [AI Custom Guardrail plugin](https://developer.konghq.com/plugins/ai-custom-guardrail/) | Plugin existence, 3.14+ requirement, AI licence, dependency on `ai-proxy` / `ai-proxy-advanced`. Also the definition of the built-in expression variables `$(source)`, `$(conf)`, `$(content)` and `$(resp)`, and the statement that they may be used as arguments to functions but not inside a function body |
| [AI Custom Guardrail reference](https://developer.konghq.com/plugins/ai-custom-guardrail/reference/) | Full config schema. **Source of truth for field names and allowed values.** `guarding_mode` is an enum of `BOTH` / `INPUT` / `OUTPUT`; `text_source` of `last_message` / `concatenate_user_content` / `concatenate_all_content`; `request.body`, `request.headers`, `request.queries` and `params` are flat maps of strings and are referenceable; `timeout`, `ssl_verify`, `stop_on_error`, `response_buffer_size`, `allow_masking`, `metrics` and `custom_metrics` exist; there are no retry or cache fields. The schema is published inline on that page as `window.schema`. Prefer it over narrative docs, and prefer a live data plane over both: `GET /schemas/plugins/ai-custom-guardrail` |
| [Example: AI Custom Guardrail with Azure Content Safety](https://developer.konghq.com/plugins/ai-custom-guardrail/examples/azure-content-safety/) | The pattern this repository follows for nested JSON: a function returning a Lua table, referenced from a flat `request.body` value. Also shows complex `params` values passed as JSON strings, and the `function(resp, conf)` signature |
| [Example: AI Custom Guardrail with Mistral Moderation](https://developer.konghq.com/plugins/ai-custom-guardrail/examples/mistral-moderation/) | Working example of `guarding_mode: BOTH`, `text_source: concatenate_all_content`, `params`, `request.*`, `response.block`, `response.block_message`, `functions`, and the `$(conf.params.*)` / `$(content)` interpolation |
| [How-to: AI Custom Guardrail with Mistral](https://developer.konghq.com/how-to/use-ai-custom-guardrail-with-mistral/) | The same example in tutorial form, with the block response body shape |

## Kong — AI Gateway 2.x

| Reference | Used for |
|---|---|
| [AI Gateway 2.x concepts](https://developer.konghq.com/ai-gateway/ai-gateway-v2-concepts/) | Entity model, AI Policies replacing plugins, v1 to v2 mapping |
| [AI Gateway Policies](https://developer.konghq.com/ai-gateway/policies/) | Catalogue of available policy types |
| [AI Policy entity](https://developer.konghq.com/ai-gateway/entities/ai-policy/) | `type`, `config`, scoping, global vs entity-attached |
| [AI Gateway architecture](https://developer.konghq.com/ai-gateway/architecture/) | Konnect control plane, self-managed data planes, mTLS registration |
| [Migrate to AI Gateway 2.x](https://developer.konghq.com/ai-gateway/v2-migration-guide/) | How v1 plugins become v2 policies |
| [kongctl declarative configuration](https://developer.konghq.com/kongctl/declarative/) | `ai_gateway_policies`, `ai_gateway_models`, `!lookup`, `!ref`, `!env` |
| [Get started with AI Gateway](https://developer.konghq.com/ai-gateway/get-started/) | Working `kongctl apply` invocations and entity shapes |
| [AI Proxy Advanced reference](https://developer.konghq.com/plugins/ai-proxy-advanced/reference/) | `targets[].route_type`, `targets[].auth`, `targets[].model` used in the deck variant |

## Kong — MCP, and why it is out of scope

| Reference | Used for |
|---|---|
| [AI MCP Proxy plugin](https://developer.konghq.com/plugins/ai-mcp-proxy/) | The scope boundary stated in the README. Kong Gateway 3.12+. Lists "applying guardrails to MCP AI plugin requests and responses" among the unsupported features, and instructs that the plugin must not be configured together with other AI plugins on the same Service or Route — which is what rules out chaining `ai-custom-guardrail` onto MCP traffic. Also the source for the four listener modes and the per-tool ACLs |
| [AI MCP Server entity](https://developer.konghq.com/ai-gateway/entities/ai-mcp-server/) | The AI Policies attachable to an MCP Server in AI Gateway 2.x: rate limiting, request and response transformation, logging, OAuth-based ACL gating. No guardrail among them |

## Kong — secrets

| Reference | Used for |
|---|---|
| [Vault entity and backends](https://developer.konghq.com/gateway/entities/vault/) | `{vault://backend/name}` syntax, env backend mapping, referenceable fields, available backends |

## Kong — fallbacks

| Reference | Used for |
|---|---|
| [Request Callout plugin](https://developer.konghq.com/plugins/request-callout/) | Fallback path for data planes below 3.14 |
| [Custom plugins in Konnect hybrid mode](https://developer.konghq.com/custom-plugins/konnect-hybrid-mode/) | Why the Lua plugin path is not available on an AI Gateway 2.x control plane |

## Palo Alto Networks

| Reference | Used for |
|---|---|
| [Prisma AIRS AI Runtime API, developer docs](https://pan.dev/prisma-airs/api/airuntimesecurity/airuntimesecurityapi/) | Scan API endpoint, request and response schema |
| [aisecurity-python-sdk](https://github.com/PaloAltoNetworks/aisecurity-python-sdk) | **Source of truth for the AIRS payload.** The generated OpenAPI client under `aisecurity/generated_openapi_client/docs/` documents `ScanRequest` (`tr_id`, `ai_profile`, `metadata`, `contents`), `ScanResponse` (`scan_id`, `report_id`, `category`, `action`, `prompt_detected`, `response_detected`, `error`, `timeout`), `PromptDetected`, `ResponseDetected`, `Metadata` and `AiProfile` field by field |
| [API Intercept overview](https://docs.paloaltonetworks.com/ai-runtime-security/activation-and-onboarding/ai-runtime-security-api-intercept-overview) | Onboarding, API application creation, security profiles |
| [Detect MCP Threats, API Intercept](https://docs.paloaltonetworks.com/ai-runtime-security/administration/api-intercept-create-configure-security-profile/detect-mcp-threats) | Evidence that the MCP gap is Kong-side, not AIRS-side. API Intercept accepts a `contents[].tool_event` object (`metadata.ecosystem`, `method`, `server_name`, `tool_invoked`, `input`, `output`) on `/v1/scan/sync/request` and reports findings under `tool_detected`, covering tool definition poisoning and credential leakage |
| [Prisma AIRS MCP Server](https://docs.paloaltonetworks.com/ai-runtime-security/activation-and-onboarding/prisma-airs-mcp-server-for-centralized-ai-agent-security/understanding-the-prisma-airs-mcp-server) | The path available today for MCP coverage, outside the gateway: the agent invokes the scan itself |
| [prisma-airs-integrations](https://github.com/PaloAltoNetworks/prisma-airs-integrations) | Official Kong assets: custom Lua plugin v1 and v2, `request-callout` variant. `Kong/custom-plugin-v2/handler.lua` and `Kong/request-callout/request-callout-prisma-airs-config.json` confirm the wire payload, the `x-pan-token` header, and the fail-closed verdict mapping |
| [Prisma AIRS Intercept plugin on Kong hub](https://developer.konghq.com/plugins/prisma-airs-intercept/) | Third-party plugin, Kong Gateway 3.4+, custom image required |

## Context

| Reference | Used for |
|---|---|
| [Kong blog: Prisma AIRS and Kong AI Gateway](https://konghq.com/blog/engineering/prisma-airs-kong-ai-gateway) | The two officially described integration methods, both v1 era |
| [Kong AI Gateway 3.14 release](https://konghq.com/blog/product-releases/kong-ai-gateway-3-14) | When `ai-custom-guardrail` shipped |

## Verification note

Narrative documentation pages describe behaviour. The **plugin schema** describes
what will actually apply. When the two disagree, the schema wins — the plugin
overview page, for instance, does not mention `guarding_mode` at all, while the
schema pins its three allowed values. Retrieve the schema from a running data
plane rather than trusting a documentation page or a previous session's memory.
