---
title: A fleet-polled /health endpoint should be liveness, not readiness
date: 2026-07-13
category: architecture-patterns
module: connection_health_monitor
problem_type: architecture_pattern
component: service_object
severity: medium
applies_when:
  - Designing a /health endpoint that a large client fleet polls on a timer
  - Deciding between liveness and readiness semantics for a health route
  - Building a connectivity or uptime UI banner driven by a health probe
tags: [health-endpoint, liveness, readiness, connectivity-monitor, fastapi, fleet-polling, banner-flapping]
---

# A fleet-polled /health endpoint should be liveness, not readiness

## Context

`neo_connection_health` polls `GET {baseUrl}/healthz` from every
Neosapien device on an adaptive timer (5 min healthy, 1 min retry). Any
non-2xx response is classified as `serverUnreachable` and drives a
user-facing banner ("Our servers are down"). When this was written the
backend route did not exist yet, so the question arose: what should the
endpoint actually do when we build it?

**Outcome (2026-07-16): built as recommended.** The backend shipped
`/healthz` (not `/health`) in `neo-backend-v2/main.py:245`, and it is a
liveness check exactly as argued below:

```python
@app.get("/healthz", include_in_schema=False)
async def healthz():
    return {"status": "ok"}
```

Verified live on dev (`https://neo-backend-v2.dev-api.neosapien.xyz/healthz`
→ `200 {"status":"ok"}`, ~240 ms, no dependency touched). The guidance
below is therefore settled, not speculative — treat a future PR that adds
Mongo/Redis pings to this route as a regression.

Two candidate implementations, and they are NOT interchangeable:

- **Liveness** — return 200 as long as the process is up and its event
  loop is responsive. Touches no dependencies.
- **Readiness** — additionally ping Mongo/Redis and return 503 if a
  critical dependency is down.

The instinct is "readiness is more honest — it proves the server actually
works." For a fleet-polled, banner-driving endpoint that instinct is wrong.

## Guidance

**Make the client-facing health route a liveness check.** A live process
answering 200 is exactly the signal the monitor needs — "can I reach our
server right now?"

```python
# FastAPI — what neo-backend-v2 actually ships (main.py:245)
@app.get("/healthz", include_in_schema=False)
async def healthz():
    return {"status": "ok"}
```

FastAPI returns 200 by default → the package reads 2xx → `healthy`. No
dependency is touched.

Reserve readiness/503 semantics for **infrastructure probes** (k8s
liveness/readiness, load-balancer target checks) — a handful of callers
whose job is to pull a pod out of rotation. Do not point a client fleet at
a readiness endpoint.

## Why This Matters

Two failure modes make readiness actively harmful for this use case:

1. **Banner flapping.** A readiness endpoint returns 503 on any transient
   Redis/Mongo blip. The monitor immediately flips to `serverUnreachable`
   and the "servers are down" banner pops — usually a lie (the server is
   fine; one dependency coughed for two seconds). The user sees alarm
   noise on every hiccup.

2. **Load amplification.** This route is hit by *every device every
   5 minutes*. A readiness check runs a Mongo + Redis query on each of
   those requests, so thousands of client phones become a self-inflicted,
   continuous load stream against the very datastores you are trying to
   protect. Liveness touches nothing and cannot amplify.

The rule of thumb: **liveness for client-facing "are you up?" banners,
readiness for infra probes.** The two audiences have opposite needs — a
banner wants a stable, cheap signal; an orchestrator wants an aggressive,
dependency-aware one.

## When to Apply

- A health/uptime endpoint is polled by many clients on a timer.
- The endpoint's result drives user-visible UI (a banner, a status dot).
- You are tempted to add dependency checks "to be thorough."
- You need to distinguish this endpoint from a k8s/LB probe that legitimately
  wants readiness semantics (give those a *separate* route, e.g. `/readyz`).

## Examples

**Readiness (do NOT use for the fleet-polled route):**

```python
# Anti-pattern for a client-fleet endpoint: flaps + amplifies DB load.
@app.get("/healthz", include_in_schema=False)
async def healthz():
    checks, ok = {}, True
    try:
        await r.ping()                                    # Redis
        checks["redis"] = "ok"
    except Exception:
        checks["redis"] = "down"; ok = False
    try:
        await mongodb_service.client.admin.command("ping")  # Mongo
        checks["mongo"] = "ok"
    except Exception:
        checks["mongo"] = "down"; ok = False
    return JSONResponse(
        status_code=200 if ok else 503,
        content={"status": "ok" if ok else "degraded", "checks": checks},
    )
```

**Future-proofing without 503.** If a `serverDegraded` UI state is ever wanted,
do NOT reach for readiness. The package uses `GET` (not `HEAD`) specifically
so the response body can carry richer signal later. Return **200 with a
degraded body** and let the client decide how to render it — this keeps the
banner honest (still "reachable") without flapping the whole thing to
"down":

```python
@app.get("/healthz", include_in_schema=False)
async def healthz():
    return {"status": "degraded", "env": ENV, "timestamp": int(time.time() * 1000)}
    # still 2xx → package stays `healthy`; a future client parses status
```

## The accepted trade-off

Liveness is the right call here, but it is not free, and the cost should be
named rather than discovered during an incident: **backend process up +
database down → `/healthz` still returns 200 → the package emits `healthy`
→ no banner, while the app is in fact broken.** That is the deliberate
price of a stable, cheap, non-amplifying signal. The fix is *not* to flip
this route to readiness (that reintroduces both failure modes above) — it
is the future `serverDegraded` state, which returns **200 with a degraded
body** per the snippet above. (The client-side state name carries the
`server` prefix deliberately — see `CLAUDE.md` §Out of scope; the bare
`degraded` here is the *backend's* response-body literal, which is a
different thing and stays as written.)

## Related

- `CLAUDE.md` §Tech — mandates `GET` over `HEAD`. Now confirmed live:
  `HEAD /healthz` returns `405` because the route is declared `@app.get`.
- `CLAUDE.md` §Project → Backend endpoint — verified hosts, per-env deploy
  status, and the `healthPath: '/healthz'` override consumers must pass.
- `lib/src/connection_health_monitor.dart` — `_runCheck` server-first probe
  that classifies any non-2xx as `serverUnreachable`.
- Backend `../neo-backend-v2/main.py:245` — the shipped liveness route.
  Rate-limit exempt (`core/api_rate_limit.py:105`) and filtered out of
  access logs (`main.py:117`), both of which matter at fleet polling rates.
