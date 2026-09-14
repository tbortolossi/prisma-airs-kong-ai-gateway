# Lab: the deck variant on a classic control plane

`config/deck/airs-guardrail.yaml` targets a classic Gateway control plane,
which the AI Gateway 2.x lab cannot exercise. This procedure stands up a
classic control plane in Konnect with one self-managed data plane, applies the
deck file with only the model target changed, and runs the same validation
suite. It was run on 2026-09-14 with `kong/kong-gateway:3.14.0.14`.

It needs a Konnect personal access token with rights to create control
planes, `deck`, `docker`, `openssl` and `jq`, an OpenAI-compatible model the
data plane can reach (the lab uses a local Ollama on the same Docker network),
and the same Prisma AIRS key and profile as the rest of the repository.

> **Lab only.** The control plane is throwaway. Delete it at the end (step 6):
> a classic control plane counts against the organisation's limits, and its
> data plane certificate should not outlive the lab.

## Step 1 - Create the control plane

```bash
export KONNECT_TOKEN="<pat>"
export KONNECT_ADDR="https://eu.api.konghq.com"      # your Konnect geo
cp=$(curl -s -X POST -H "Authorization: Bearer $KONNECT_TOKEN" -H 'Content-Type: application/json' \
  "$KONNECT_ADDR/v2/control-planes" \
  -d '{"name":"airs-lab-classic","cluster_type":"CLUSTER_TYPE_CONTROL_PLANE","auth_type":"pinned_client_certs"}')
CP_ID=$(echo "$cp" | jq -r .id)
CP_EP=$(echo "$cp" | jq -r .config.control_plane_endpoint | sed 's|https://||')
TP_EP=$(echo "$cp" | jq -r .config.telemetry_endpoint | sed 's|https://||')
```

## Step 2 - Pin a data plane certificate

```bash
openssl req -new -x509 -nodes -newkey ec:<(openssl ecparam -name secp384r1) \
  -keyout tls.key -out tls.crt -days 30 -subj "/CN=airs-lab-classic-dp"
curl -s -X POST -H "Authorization: Bearer $KONNECT_TOKEN" -H 'Content-Type: application/json' \
  "$KONNECT_ADDR/v2/control-planes/$CP_ID/dp-client-certificates" \
  -d "{\"cert\":\"$(awk 'BEGIN{ORS="\\n"} {print}' tls.crt)\"}"
```

## Step 3 - Run the data plane

The Prisma AIRS key and the model credential are given to the container as
environment variables, which is what the two `{vault://env/...}` references
in the deck file resolve to. Konnect pushes the licence after the node
connects; the "No license found" notice at start-up is expected.

```bash
docker run -d --name airs-lab-classic-dp --network <network of your model> -p 127.0.0.1:28000:8000 \
  -e KONG_ROLE=data_plane -e KONG_DATABASE=off -e KONG_VITALS=off -e KONG_KONNECT_MODE=on \
  -e KONG_CLUSTER_MTLS=pki \
  -e "KONG_CLUSTER_CONTROL_PLANE=${CP_EP}:443" -e "KONG_CLUSTER_SERVER_NAME=${CP_EP}" \
  -e "KONG_CLUSTER_TELEMETRY_ENDPOINT=${TP_EP}:443" -e "KONG_CLUSTER_TELEMETRY_SERVER_NAME=${TP_EP}" \
  -e "KONG_CLUSTER_CERT=$(cat tls.crt)" -e "KONG_CLUSTER_CERT_KEY=$(cat tls.key)" \
  -e KONG_LUA_SSL_TRUSTED_CERTIFICATE=system -e KONG_PROXY_LISTEN='0.0.0.0:8000' -e KONG_ADMIN_LISTEN=off \
  -e "AIRS_TOKEN=<prisma airs key>" -e "OPENAI_KEY=Bearer <model credential, or a dummy for a local model>" \
  kong/kong-gateway:3.14.0.14
curl -s -H "Authorization: Bearer $KONNECT_TOKEN" "$KONNECT_ADDR/v2/control-planes/$CP_ID/nodes" | jq '.items[] | {hostname, version}'
```

## Step 4 - Apply the deck file

Copy `config/deck/airs-guardrail.yaml`, set `params.profile` to your profile,
and point the two `ai-proxy-advanced` targets at your model. For a local
OpenAI-compatible model, replace `name: gpt-4o` with the model name and add,
under each `model:` block, `options.upstream_url` set to the full
`.../v1/chat/completions` endpoint. Nothing else changes.

```bash
deck gateway diff deck-lab.yaml --konnect-token "$KONNECT_TOKEN" \
  --konnect-control-plane-name airs-lab-classic --konnect-addr "$KONNECT_ADDR"
deck gateway sync deck-lab.yaml --konnect-token "$KONNECT_TOKEN" \
  --konnect-control-plane-name airs-lab-classic --konnect-addr "$KONNECT_ADDR"
```

## Step 5 - Validate

```bash
KONG_PROXY_URL=http://localhost:28000 CLIENT_KEY=unused MODEL_NAME=<model name> ./scripts/test-airs.sh
```

Then the two routes by hand: `stream: true` on `/v1/chat/completions` must
answer HTTP 400 `{"error":{"message":"response streaming is not enabled for
this LLM"}}`; the same request on `/stream/v1/chat/completions` must stream,
and a malicious prompt on that route must be refused with the generic Prisma
AIRS message. To see the `OUTPUT` phase block, point `airs-scan` at
`scripts/lab-echo-server.py --verdict block` with `guarding_mode: OUTPUT` and
a dummy token, as in `docs/lab-streaming.md`; to see the sanitizer, merge
`config/deck/airs-error-sanitizer.yaml` into the service's plugin list and
point the guardrail at a closed port.

## Step 6 - Tear down

```bash
docker rm -f airs-lab-classic-dp
curl -s -X DELETE -H "Authorization: Bearer $KONNECT_TOKEN" "$KONNECT_ADDR/v2/control-planes/$CP_ID"
rm -f tls.key
```

## Result of the run of 2026-09-14

Konnect classic control plane (EU), `kong/kong-gateway:3.14.0.14`, local
model. `scripts/test-airs.sh`: 5 of 5, twice. Service route: `stream: true`
refused with HTTP 400. Streaming route: streams; a malicious prompt refused
with HTTP 400 and the generic message. `OUTPUT` phase: a flagged response
refused with HTTP 400, one `contents[].response` call seen by the echo
server. Sanitizer: guardrail unreachable answered HTTP 500
`{"error":{"message":"Guardrail unavailable"}}`; without it, the
connection-refused text. deck created seven entities on the first sync and
updated two on each variant.
