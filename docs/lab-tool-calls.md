# Lab: are tool calls scanned?

The README states, under **Scope and limits**, that tool calls on the LLM path
are unconfirmed. No published Kong documentation says whether `$(content)`
carries `tools[]`, an assistant message's `tool_calls[].function.arguments`, or
`role: "tool"` results. This procedure settles it on a live gateway, in one
session, and produces the evidence needed to change that statement.

It uses two files:

| File | Role |
|---|---|
| `scripts/lab-echo-server.py` | Stands in for the Prisma AIRS endpoint. Logs the payload the policy emits and reports which marker reached the scanned text |
| `scripts/lab-tool-call-probe.sh` | Sends one completion carrying a marker in each of the five positions |

---

## Before you start

> **This is a lab procedure.** While the policy points at the echo server,
> Prisma AIRS is not scanning anything. Run it on a non-production gateway, and
> restore the configuration when you are done — step 5.

> **Set `params.api_key` to a dummy value first.** The policy sends it as
> `x-pan-token` to whatever `request.url` names. The echo server redacts it from
> its output, but the right control is not to send a real token to a lab
> listener at all.

The data plane must be able to reach the echo server. Run it on a host on the
same private network as the data plane — a bastion, the container host, or a
pod in the same namespace. Do not expose it through a public tunnel: the payload
contains the prompts under test.

You need what `scripts/test-airs.sh` needs: `KONG_PROXY_URL`, `CLIENT_KEY`, and
optionally `MODEL_NAME`.

---

## Step 1 — Start the echo server

```bash
./scripts/lab-echo-server.py --port 8099 --log payloads.jsonl
```

Standard library only, nothing to install. `--log` is optional and appends each
payload as a JSON line, which is what you attach to the lab record.

It answers `action: allow, category: benign` by default. `--verdict block`,
`--verdict error` and `--verdict timeout` exercise the other branches of
`airs_verdict`, including the fail-closed path.

## Step 2 — Point the policy at it

In `config/kongctl/airs-guardrail.yaml`, in the **prompt scan** policy only:

```yaml
      params:
        api_key: "dummy-lab-token"          # was {vault://env/airs-token}

      request:
        url: http://<echo-host>:8099/v1/scan/sync/request
```

Apply it as usual. The classic control plane variant is the same two lines in
`config/deck/airs-guardrail.yaml`.

Only the `INPUT` policy needs to change. The response scan is a separate
question and is not part of this procedure.

## Step 3 — Run the probe

```bash
export KONG_PROXY_URL="https://<proxy>"
export CLIENT_KEY="<client credential>"
./scripts/lab-tool-call-probe.sh
```

Run it three times, once per `text_source` value, re-applying the configuration
between runs:

- `last_message`
- `concatenate_user_content`
- `concatenate_all_content` — the value this repository ships

## Step 4 — Read the echo server output

Each request prints the full payload, then a table:

```
  phase: INPUT    contents[0] keys: ['prompt']
  scanned text: 96 chars
  position                                    marker reached
    system message                            SCANNED
    user message                              SCANNED
    tools[].function.description              absent — NOT scanned
    assistant tool_calls[].function.arguments absent — NOT scanned
    role: tool result message                 absent — NOT scanned
```

`SCANNED` means the marker reached the text sent to Prisma AIRS, so that
position is covered. `absent` means it never appeared in the payload at all. The
distinction matters: absence is the answer, not a missing observation.

## Step 5 — Restore, then record

Put `request.url` and `params.api_key` back, and re-apply. Confirm with
`scripts/test-airs.sh` that real scanning has resumed.

Then:

- record the three tables in `CLAUDE.local.md`, under Q3;
- state the outcome in the README under **Scope and limits**, replacing "not
  confirmed" with what was observed, and move the item out of **Verification
  status**;
- if tool positions are not scanned, say so plainly. That is a real limit of the
  configuration-only approach, and it belongs in the same section as the MCP
  boundary.

---

## What else this run gives you for free

The payload printed at step 4 is the whole emitted request, so a single session
also answers three of the other open questions:

- **the explicit-argument call form.** `contents: "$(airs_contents(content))"` is
  the one construct in the shipped configuration that appears in no published
  Kong example. If `contents` is present and well formed in the payload, the form
  works. If it is absent or malformed, it does not, and the fallback is a bare
  `$(airs_contents)` reference.
- **the block status code.** Run the probe with `--verdict block` and read the
  HTTP code the gateway returns. `scripts/test-airs.sh` currently asserts "not
  200" because that code has never been observed.
- **added latency.** Time the probe with the policy enabled and disabled. The
  echo server answers immediately, so the delta is the plugin's own overhead,
  not the network path to Prisma AIRS.

Whether `$(resp)` is a table or a string in the `OUTPUT` phase needs the same
setup pointed at the response scan policy instead, which is outside the scope of
this procedure.
