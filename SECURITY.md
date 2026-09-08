# Security policy

## Reporting a vulnerability

Report security issues privately through GitHub's
[private vulnerability reporting](https://github.com/tbortolossi/prisma-airs-kong-ai-gateway/security/advisories/new)
rather than opening a public issue.

This repository ships configuration, not a running service. The realistic issue
classes are:

- a configuration that fails open where it claims to fail closed;
- a secret handling pattern that exposes the Prisma AIRS API key;
- a documented procedure that weakens the security posture of a gateway;
- a block message that leaks Prisma AIRS detection detail (category, detection
  name) to the calling client. The client is meant to see only a fixed, generic
  message and, when present, `scan_id` — naming the detection to the caller is
  an evasion oracle, letting an attacker use the block response itself to map
  which inputs trip which detector;
- a template or function change that could ship plugin configuration — the API
  key included, after vault resolution — to the guardrail service as scanned
  text, for example if a Lua function accepts a table where it should only
  accept a string and serialises it into the Prisma AIRS payload.

All five are in scope. Please include the file and the concrete failure path.

## What this repository is not

These are community assets, not an official Palo Alto Networks or Kong product,
and carry no support commitment from either vendor. For a vulnerability in Kong
Gateway itself, report to Kong. For one in Prisma AIRS, report to Palo Alto
Networks through the usual channel.

## Secrets

No credential belongs in this repository, in any form, including in an example.
The Prisma AIRS API key is always a vault reference (`{vault://env/airs-token}`)
or an obvious placeholder. Every push is scanned by Gitleaks in CI, and GitHub
secret scanning with push protection is enabled on the repository.

If you believe a real credential has been committed, treat it as compromised:
rotate it first, then report.

## Fail-closed

The shipped configuration blocks traffic when Prisma AIRS cannot deliver a
verdict. Two mechanisms enforce this — `stop_on_error: true` and the
`airs_verdict` Lua function — and both must be changed together to fail open.
A change that silently weakens either one will not be accepted.
