# Canonical sources

Every configuration assertion in this repository must trace back to one of these
references, or carry the `SYNTHESIZED` tag. Do not introduce a Kong or Prisma
AIRS configuration field that is not backed by a page listed here.

## Kong — the guardrail extension point

| Reference | Used for |
|---|---|
| [AI Custom Guardrail plugin](https://developer.konghq.com/plugins/ai-custom-guardrail/) | Plugin existence, 3.14+ requirement, AI licence, dependency on `ai-proxy` / `ai-proxy-advanced`. Also the definition of the built-in expression variables `$(source)`, `$(conf)`, `$(content)` and `$(resp)`, and the statement that they may be used as arguments to functions but not inside a function body. `$(source)` takes the values `INPUT` while inspecting the request and `OUTPUT` while inspecting the response — `airs_contents` switches on it. `$(resp)` is documented as a Lua table in the `INPUT` phase and a string in the `OUTPUT` phase; `airs_verdict` handles both |
| [AI Custom Guardrail reference](https://developer.konghq.com/plugins/ai-custom-guardrail/reference/) | Full config schema. **Source of truth for field names and allowed values.** `guarding_mode` is an enum of `BOTH` / `INPUT` / `OUTPUT`; `text_source` of `last_message` / `concatenate_user_content` / `concatenate_all_content`; `request.body`, `request.headers`, `request.queries` and `params` are flat maps of strings and are referenceable; `request.auth` (location `body` \| `header` \| `query`, `name`, `value`, `value` referenceable and encrypted) is a dedicated slot for the credential, documented but unused here; `timeout`, `ssl_verify`, `stop_on_error`, `response_buffer_size`, `allow_masking`, `metrics` and `custom_metrics` exist; `allow_masking`'s description notes that streaming is disabled when it is enabled; there are no retry or cache fields. The schema is published inline on that page as `window.schema`. Prefer it over narrative docs, and prefer a live data plane over both: `GET /schemas/plugins/ai-custom-guardrail` |
| [Example: AI Custom Guardrail with Azure Content Safety](https://developer.konghq.com/plugins/ai-custom-guardrail/examples/azure-content-safety/) | The pattern this repository follows for nested JSON: a function returning a Lua table, referenced from a flat `request.body` value. Also shows complex `params` values passed as JSON strings, the `function(resp, conf)` signature, and dotted access to a function's result field, `$(fn.field)` (`$(check_response.block)`, `$(check_response.block_message)`) — the pattern `airs_verdict.block` / `.block_message` / `.detail` follows here |
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
| [kongctl declarative configuration](https://developer.konghq.com/kongctl/declarative/) | `ai_gateway_policies`, `ai_gateway_models`, `!lookup`, `!ref`, `!env`. `!lookup` documents both a `{name: ...}` selector and an `id:<uuid>` selector; this repository uses `!lookup { id: !env AI_GATEWAY_ID }`, to be confirmed at first apply |
| [Get started with AI Gateway](https://developer.konghq.com/ai-gateway/get-started/) | Working `kongctl apply` invocations and entity shapes |
| [kongctl README](https://github.com/Kong/kongctl) | The `--pat` flag ("You can also pass an API token directly using the --pat flag") and the `KONGCTL_DEFAULT_KONNECT_PAT` environment variable |
| [AI Proxy Advanced reference](https://developer.konghq.com/plugins/ai-proxy-advanced/reference/) | `targets[].route_type`, `targets[].auth`, `targets[].model` used in the deck variant. `auth.header_value` is documented as "the full auth header value for 'header_name', for example 'Bearer key' or just 'key'" — the deck file's `OPENAI_KEY` must therefore carry the `Bearer ` prefix itself |

## Kong — plugin instances, precedence and sync

| Reference | Used for |
|---|---|
| [Plugin entity](https://developer.konghq.com/gateway/entities/plugin/) | Plugin precedence: Kong runs a single instance of a given plugin per request, and a route-level instance overrides the service-level instance of the same plugin for that route. This is what the deck variant relies on to give the streaming route the `INPUT`-only policy while the rest of the service keeps `BOTH` |
| [`kong/db/schema/entities/plugins.lua`](https://github.com/Kong/kong/blob/master/kong/db/schema/entities/plugins.lua) | A plugin instance is keyed on `{name, route, service, consumer}` (`cache_key`) |
| [`kong/db/migrations/core/000_base.lua`](https://github.com/Kong/kong/blob/master/kong/db/migrations/core/000_base.lua) | The `cache_key` column carries a `UNIQUE` constraint, so a second `ai-custom-guardrail` instance on the same scope is rejected at apply time. Together with the plugin entity page, this is why the design attaches one policy per scope rather than two |
| [deck gateway sync](https://developer.konghq.com/deck/gateway/sync/) | "Any configuration in Kong Gateway that isn't present in the provided declarative configuration file will be deleted" — the reason the deployment guide requires a `deck gateway diff` before every `sync` |
| [deck tags](https://developer.konghq.com/deck/gateway/tags/) | `--select-tag`, used to scope a `sync` to entities this repository owns rather than the whole control plane |

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
| [Request Callout plugin](https://developer.konghq.com/plugins/request-callout/) | Fallback path for data planes below 3.14. The page states `min_version: gateway: '3.10'`, the source for the "Kong Gateway 3.10+" note in the deployment guide |
| [Custom plugins in Konnect hybrid mode](https://developer.konghq.com/custom-plugins/konnect-hybrid-mode/) | Why the Lua plugin path is not available on an AI Gateway 2.x control plane |

## Palo Alto Networks

| Reference | Used for |
|---|---|
| [Prisma AIRS AI Runtime API, developer docs](https://pan.dev/prisma-airs/api/airuntimesecurity/airuntimesecurityapi/) | Scan API endpoint, request and response schema. Also documents the 2 MB maximum payload size per synchronous scan request, relevant to `text_source: concatenate_all_content` on long conversations |
| [aisecurity-python-sdk](https://github.com/PaloAltoNetworks/aisecurity-python-sdk) | **Source of truth for the AIRS payload.** The generated OpenAPI client under `aisecurity/generated_openapi_client/docs/` documents `ScanRequest` (`tr_id`, `session_id`, `transaction_id`, `ai_profile`, `metadata`, `contents`), `ScanResponse` (`source`, `scan_id`, `report_id`, `tr_id`, `session_id`, `transaction_id`, `profile_id`, `profile_name`, `category`, `action`, `prompt_detected`, `response_detected`, `tool_detected`, `error`, `timeout`, `errors`), `PromptDetected`, `ResponseDetected`, `Metadata` and `AiProfile` field by field. The three correlation identifiers are all optional and none is deprecated: `tr_id` is "unique identifier for the transaction correlating prompt and response", `transaction_id` "unique identifier for the transaction", `session_id` "unique identifier for tracking Sessions". This repository sends none of them — see the AI Sessions page below for what that costs |
| [API Intercept overview](https://docs.paloaltonetworks.com/ai-runtime-security/activation-and-onboarding/ai-runtime-security-api-intercept-overview) | Onboarding, API application creation, security profiles |
| [Detect MCP Threats, API Intercept](https://docs.paloaltonetworks.com/ai-runtime-security/administration/api-intercept-create-configure-security-profile/detect-mcp-threats) | Evidence that the MCP gap is Kong-side, not AIRS-side. API Intercept accepts a `contents[].tool_event` object (`metadata.ecosystem`, `method`, `server_name`, `tool_invoked`, `input`, `output`) on `/v1/scan/sync/request` and reports findings under `tool_detected`, covering tool definition poisoning and credential leakage |
| [Use the AI Sessions and API Application Views](https://docs.paloaltonetworks.com/ai-runtime-security/administration/api-intercept-create-configure-security-profile/use-the-ai-sessions-and-application-views) | What the correlation identifiers buy. AI sessions are "logical groupings of related API calls sharing the same transaction ID", and "if no transaction ID is provided, the system automatically creates one for each atomic API call". Since this repository sends no identifier, every scan is its own single-call session, and the `INPUT` and `OUTPUT` scans of one exchange are never correlated. Supplying one is a v0.5 sidecar item, not a configuration change: Q7 established that no guardrail function can reach a per-request value |
| [Prisma AIRS MCP Server](https://docs.paloaltonetworks.com/ai-runtime-security/activation-and-onboarding/prisma-airs-mcp-server-for-centralized-ai-agent-security/understanding-the-prisma-airs-mcp-server) | The path available today for MCP coverage, outside the gateway: the agent invokes the scan itself |
| [prisma-airs-integrations](https://github.com/PaloAltoNetworks/prisma-airs-integrations) | Official Kong assets: custom Lua plugin v1 and v2, `request-callout` variant. `Kong/custom-plugin-v2/handler.lua` and `Kong/request-callout/request-callout-prisma-airs-config.json` confirm the wire payload, the `x-pan-token` header, and the fail-closed verdict mapping. The `request-callout` config is also the source for this repository's generic client-facing block body: it returns HTTP 403 with a generic "Blocked by AI security scan" rather than naming the detection to the caller |
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
