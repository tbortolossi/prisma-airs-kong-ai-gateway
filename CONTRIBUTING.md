# Contributing

## Ground rule

Every field name and every enum value in the YAML must come from the published
Kong plugin schema, and every Prisma AIRS field from the published API schema.
Not from a narrative documentation page, and not from memory.

The plugin overview page does not mention `guarding_mode` at all. The schema is
published inline on the configuration reference page, and is authoritative on a
live data plane:

```bash
# From a data plane Admin API
curl -s localhost:8001/schemas/plugins/ai-custom-guardrail | jq .
```

If a capability is needed and the field does not exist, leave it out and say so.
A YAML that looks right and fails to apply is worse than a documented gap.

## Verification tags

Configuration blocks and documentation claims carry one of three states:

- `DOCUMENTED` — published, with the URL in `docs/sources.md`
- `SYNTHESIZED` — a transposition or inference, published nowhere
- `LAB-VERIFIED` — applied and exercised against a live gateway

Do not promote `SYNTHESIZED` to `LAB-VERIFIED` without a recorded test run. The
offline Lua suite does not count: it proves the verdict logic against the Prisma
AIRS schema, not that Kong accepts the configuration.

## Both config files, always

`config/kongctl/airs-guardrail.yaml` and `config/deck/airs-guardrail.yaml` carry
an identical `config` block. Any change to guardrail logic lands in both, in the
same commit. `scripts/run-lua-tests.sh` fails the build if the verdict functions
drift apart.

## Before you open a pull request

```bash
./scripts/run-lua-tests.sh          # 17 assertions, no gateway needed
shellcheck scripts/*.sh
```

Then check:

- both config files updated in step;
- `docs/sources.md` updated if a new upstream reference was used;
- `CHANGELOG.md` updated for anything user-visible;
- verification tags reviewed, and anything downgraded flagged in the PR body;
- no secret, no customer identifier, no internal hostname.

## Conventions

- YAML: two-space indent, no tabs, comments in English.
- Lua verdict functions: guard clause first, then detection extraction, then
  verdict. Under 40 lines. No external requires, except the guarded `cjson.safe`
  decode in the `OUTPUT` verdict function, which must fail closed.
- Shell: `set -u`, `shellcheck` clean. No `set -e` in `test-airs.sh` — a non-zero
  curl must not abort the remaining cases.
- Documentation: English, and every external claim carries a link.

## Commits

Conventional Commits: `fix:`, `feat:`, `docs:`, `security:`, `chore:`, `test:`.
