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
an identical `config` block per guardrail instance. Any change to guardrail
logic lands in both, in the same commit. `scripts/run-lua-tests.sh` fails the
build if the `airs_verdict` or `airs_contents` copies drift apart, between the
two files or between the copies inside one file; `scripts/check-plugin-schema.py
--parity` fails the build if the surrounding `config` blocks themselves drift.

## Before you open a pull request

`check-plugin-schema.py` needs PyYAML: `python3 -m pip install --user -r requirements-dev.txt`.

```bash
./scripts/run-lua-tests.sh                        # 63 assertions, no gateway needed
python3 scripts/check-plugin-schema.py --parity   # kongctl/deck config blocks match
python3 scripts/check-plugin-schema.py --schema   # every key/enum exists in the live schema
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
  decode, attempted when `$(resp)` arrives as a string, which must fail closed.
  Only `action == "allow"` lets a request through; any other action, a missing
  or malformed verdict, or a degraded scan category (`error` / `timeout`) blocks.
  `airs_verdict` returns `{ block, block_message, detail }`: `block_message` is
  always the fixed, generic client-facing text, never the category or a
  detection name; those go in `detail`, which callers wire to
  `metrics.block_reason` / `metrics.block_detail`, never to `response.block_message`.
- Every copy of `airs_verdict` and every copy of `airs_contents` must be
  byte-identical, across both config files and across every guardrail instance
  within a file. `scripts/run-lua-tests.sh` enforces this.
- Shell: `set -u`, `shellcheck` clean. No `set -e` in `test-airs.sh` — a non-zero
  curl must not abort the remaining cases.
- Documentation: English, and every external claim carries a link.

## Commits

Conventional Commits: `fix:`, `feat:`, `docs:`, `security:`, `chore:`, `test:`.
