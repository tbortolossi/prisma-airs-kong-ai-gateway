# Why this exists

Kong AI Gateway 2.x replaced the plugin-centric model with AI entities and
[AI Policies](https://developer.konghq.com/ai-gateway/policies/). Two
consequences follow, and together they are the reason this repository exists.

**Custom Lua plugins have no place on an AI Gateway 2.x control plane.** The
Prisma AIRS plugin published by Palo Alto Networks
([prisma-airs-integrations, `custom-plugin-v3`](https://github.com/PaloAltoNetworks/prisma-airs-integrations/tree/main/Kong/custom-plugin-v3))
remains fully valid where a custom plugin can still be loaded — self-hosted Kong
Gateway, and Konnect hybrid with a
[custom data plane image](https://developer.konghq.com/custom-plugins/konnect-hybrid-mode/).
It cannot be deployed on an AI Gateway 2.x control plane. Teams moving to v2
lose the integration they had.

This is a control-plane restriction, not a runtime one. The AI Gateway 2.x data
plane is itself a Kong Gateway 3.14 runtime carrying an AI Gateway version
label. What refuses the custom Lua plugin path on 2.x is the Konnect API:
applying an `ai_gateway_policies` entry of `type: prisma-airs-intercept` is
rejected outright, HTTP 400, "policy type 'prisma-airs-intercept' is not
supported". The catalogue is closed at the control plane, independently of what
the data plane underneath could otherwise run.

**The v2 policy catalogue has no Prisma AIRS type.** It ships vendor-specific
guardrail policies for `ai-aws-guardrails`, `ai-azure-content-safety`,
`ai-gcp-model-armor` and `ai-lakera-guard`, joined by NVIDIA NeMo Guardrails
since AI Gateway 2.0.1. Prisma AIRS is not among them. There is nothing to
select in the catalogue.

What v2 does provide is `ai-custom-guardrail`, Kong's supported extension point
for calling an external guardrail service over HTTP. This repository uses it to
carry the same enforcement as declarative configuration, applied through
`kongctl` on an AI Gateway 2.x control plane or through `deck` on a classic
Gateway control plane.
