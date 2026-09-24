# voxtral-gate

Lazy-wake reverse proxy in front of the Voxtral vLLM Omni engine.

The engine holds **~19 GB of VRAM** on the RTX 3090 for a route the iOS app
hits in short bursts. The gate keeps that VRAM free between sessions:

```
idle > VOXTRAL_IDLE_SECONDS   →  POST /sleep?level=1   weights → host RAM
synthesis request arrives     →  POST /wake_up         ~1-2 s
                                 then proxy as normal
```

`webapp` is unchanged — the gate owns the `voxtral:8001` address it already
talks to, and forwards to `voxtral-engine:8001`.

## Measured on the 3090

| State | GPU 1 usage |
|---|---|
| Engine awake | 20 773 MiB |
| Engine asleep | 1 429 MiB |
| Wake latency | 1.14 s |
| Wake + a short DE synthesis, end to end | 2.25 s |

The 1 429 MiB residual is the Omni **Stage 1** acoustic transformer plus the
CUDA context. `AsyncOmni.sleep()` is documented as best-effort and Stage 1
doesn't implement the RPC, so it stays resident. Stage 0 — the ~7.8 GB model
and its KV cache, i.e. the part that actually matters — offloads fine.

## Two things it deliberately does not do

**It never wakes the engine for a liveness probe.** `webapp`'s `/health`
probes Voxtral with `GET /v1/models`, and iOS polls that before onboarding.
Those paths (`NO_WAKE_PATHS` in `gate.py`) are answered by the still-alive
vLLM API-server process while the weights are offloaded, so reachability
checks cost nothing.

**It never returns 503-while-warming.** A request arriving during a wake, or
during the engine's ~60 s initial boot, is held open until the engine can
serve. `voxtral_client`'s existing error branches keep meaning exactly what
they meant before the gate existed, and the iOS app needs no retry logic.

## Requirements on the engine

The `/sleep`, `/wake_up` and `/is_sleeping` routes only exist when the engine
runs with both of these (already set in `docker-compose.yml`):

- `VLLM_SERVER_DEV_MODE=1` — registers the routes
- `--enable-sleep-mode` — without it `/sleep` errors and the VRAM stays put

If the routes are missing the gate logs a warning once and degrades to a
plain pass-through proxy: correct behaviour, just no VRAM reclaim.

vLLM calls these "development endpoints". That's acceptable here because the
engine has no host port and is reachable only by the gate on the compose
network, and the stack as a whole is Tailscale-only (SPEC.md §6).

## Configuration

| Env var | Default | Meaning |
|---|---|---|
| `VOXTRAL_ENGINE_URL` | `http://voxtral-engine:8001` | Real vLLM address |
| `VOXTRAL_IDLE_SECONDS` | `300` | Idle window before sleeping |
| `VOXTRAL_SLEEP_LEVEL` | `1` | 1 = weights to host RAM, 2 = discard |
| `VOXTRAL_SLEEP_ON_START` | `true` | Sleep once the engine finishes booting |
| `VOXTRAL_WAKE_TIMEOUT_SECONDS` | `180` | Cap on a single wake/sleep RPC |
| `VOXTRAL_PROXY_TIMEOUT_SECONDS` | `300` | Cap on a proxied request |
| `VOXTRAL_BOOT_TIMEOUT_SECONDS` | `600` | How long to poll for a booting engine |
| `VOXTRAL_IDLE_POLL_SECONDS` | `10` | Idle-loop tick |

## Operating

```bash
# Gate's own state — never touches the engine, safe to poll
curl -s http://voxtral:8001/gate/status

# Watch the transitions
docker compose logs -f voxtral | grep -E "woke|slept"

# Tests (no live vLLM needed — the engine is an httpx.MockTransport)
docker compose run --rm --no-deps --entrypoint pytest voxtral -q tests/test_gate.py
```

`/gate/status` reports `asleep`, `inflight`, `idle_seconds`, and cumulative
`wakes`/`sleeps`.

## Keeping it awake

For a long dogfooding session where the wake latency is unwanted, raise the
idle window for the session:

```bash
VOXTRAL_IDLE_SECONDS=3600 docker compose up -d voxtral
```

To drop the gate entirely, point `VOXTRAL_BASE_URL` at `voxtral-engine:8001`
and the stack behaves exactly as it did before.
