# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- README: a **Scope and limits** section. MCP traffic is out of scope, with the
  reason sourced from Kong — `ai-mcp-proxy` lists guardrails on MCP requests and
  responses as unsupported and forbids chaining with other AI plugins on the same
  Service or Route, and the AI MCP Server entity accepts no guardrail policy. The
  same section records that the limit is Kong-side only: Prisma AIRS API
  Intercept already scans MCP through `contents[].tool_event`.
- README: tool calls on the LLM path are declared unconfirmed rather than
  implied. Whether `$(content)` carries `tools[]`, `tool_calls[].function.arguments`
  and `role: "tool"` results is now a third item under Verification status.
- `docs/sources.md`: the AI MCP Proxy plugin and AI MCP Server entity pages as
  the source of the scope boundary, and the Prisma AIRS MCP threat detection and
  MCP Server pages.

## [0.1.0] — 2026-09-08

First public release. Configuration-only enforcement of Prisma AIRS AI Runtime
(API Intercept) as an inline guardrail on Kong AI Gateway, for both an AI Gateway
2.x control plane and a classic Gateway control plane.

Everything below was fixed during the pre-publication audit, against the
published `ai-custom-guardrail` schema and the Prisma AIRS OpenAPI client. None of
it had run before, because all three defects fail at apply time.

### Fixed

- `guarding_mode` used `REQUEST` and `RESPONSE`, which are not valid values. The
  enum is `BOTH` / `INPUT` / `OUTPUT`. The prompt policy is now `INPUT` and the
  response policy `OUTPUT`.
- `request.body` used nested YAML. The schema accepts a flat map of strings only.
  The nested Prisma AIRS payload is now built by Lua functions returning a table,
  following Kong's Azure Content Safety example.
- `timeout`, `ssl_verify`, `stop_on_error` and `response_buffer_size` were
  documented as non-existent and deliberately omitted. All four are in the
  schema. `stop_on_error: true` is the mechanism that actually enforces
  fail-closed when the call to Prisma AIRS itself fails, which the Lua verdict
  function cannot cover.

### Added

- `scripts/run-lua-tests.sh` and `scripts/test-verdict-functions.lua`: 17
  offline assertions covering the verdict functions against the documented
  Prisma AIRS response shapes, plus a parity check that fails if the kongctl and
  deck configs carry different Lua.
- Verdict handling for `category: "error"` and `category: "timeout"`, which
  Prisma AIRS returns alongside `action: "allow"` when its own scan degrades.
  These previously passed through as allowed.
- `Accept: application/json` on the Prisma AIRS request, matching the reference
  integration published by Palo Alto Networks.
- CI: YAML parse, config parity, offline Lua suite, `shellcheck`, and a Gitleaks
  secret scan.
- `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `.editorconfig`.

### Changed

- `scripts/test-airs.sh` now asserts an expected verdict per case and exits
  non-zero on a mismatch, instead of only printing status codes. It asserts
  "not 200" rather than a specific status, because the status returned on a block
  has not been observed yet.
- `docs/sources.md` records the plugin schema, both published guardrail examples,
  and the Prisma AIRS OpenAPI client as the sources of truth.
- README lists the actual Prisma AIRS detection names, and notes that
  `db_security` and `ungrounded` are response-only.
