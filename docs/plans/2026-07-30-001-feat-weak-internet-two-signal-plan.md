# Plan: two-signal `weakNetwork` (weak-internet, not slow-backend)

**Status:** Implemented 2026-07-30, shipped as `0.3.0`. This document is the
record of intent for the change; the code, tests, and CHANGELOG are the source
of truth if they ever diverge.

## Problem

`weakNetwork` is defined (CONCEPTS.md, enum dartdoc) as *"your link is slow,
the server is fine"* — a verdict about the **user's** internet. The 0.2.0
implementation did not deliver that: `_runCheck` reported `weakNetwork` from
the **backend** round trip alone (`2xx` slower than `slowThreshold`). So a slow
*backend* on a perfectly healthy link surfaced as "Weak Network", blaming the
user's wifi for lag that was ours.

Recorded first as CLAUDE.md §4 "Known limits" #3, a reserved low-value edge.
The user asked for it to actually mean weak *internet*. It never fired in the
field (git history: every real `weakNetwork` bug was the opposite — the
gate-lock-open stale-banner bug), and `/healthz` is a liveness literal built to
be fast, so the mislabel is rare — but the fix makes the code match its own
long-standing definition and is cheap, so it ships.

## The change — `_runCheck` only

Fast `2xx` → `healthy` (unchanged, still ONE request; a fast path to us means
the link is fine). Slow `2xx` is now a **trigger, not a verdict**: time the
user's real internet (the injected neutral-CDN checker, in the new
`_userInternetIsSlow`) and report `weakNetwork` only on **positive evidence**
that link is slow. Fast / blocked / unreachable / errored / timed-out internet
check → `healthy`. Failure path unchanged.

```
fast 2xx           → healthy
slow 2xx           → time the neutral CDN probe:
                       internet also slow (> slowThreshold) → weakNetwork
                       else (fast / blocked / error / timeout) → healthy
probe failed       → existing internetDisconnected / serverUnreachable split
```

**Genuine weak internet still fires:** a truly slow link makes the backend
probe slow too (same link) → trigger → neutral also slow → `weakNetwork`. Only
the backend-slow-but-link-fine case flips to `healthy`.

## Decisions

- **Measure by timing `hasInternetAccess`.** Reuse the injected checker (no new
  dependency). It is non-strict, so its duration is the *fastest* reachable
  CDN = best-case link latency; if even that exceeds `slowThreshold` the link
  genuinely is slow.
- **Positive-evidence-only.** Never blame the user's network without proof.
  This also handles the §4 whitelisting-network case for free: backend `2xx` +
  CDNs blocked (`false`) → `healthy`, not a false weak-link.
- **Reuse `slowThreshold`** for both the trigger and the verdict. One knob.
- **Bound the neutral check** with `.timeout(requestTimeout)`; a timeout counts
  as no-evidence → `healthy`.
- **No new state, no API change.** Behaviour change only → `0.3.0`, consumer
  `switch`es still compile.

## What did NOT change

Enum, public API, the confirmation gate + rule-2 exemption, `weakNetwork`'s
slow-cadence reschedule, the failure path, and the happy-path cost (fast `2xx`
= one request; the second probe runs only on the rare slow `2xx`).

## Tests

- `_FakeInternetConnection` gained an injectable `responseDelay` (awaits a
  `Future.delayed` under `fake_async`) so a test can simulate a slow user link.
- `gateHarness` couples its internet-probe latency to its HTTP latency, so a
  slow-success step gets a slow internet probe (→ `weakNetwork`) while a fast
  failure step keeps the failure-path internet check instant.
- Existing `weakNetwork` cases (26, 28, 35, 41–44) retimed: each slow check now
  takes backend + internet time.
- New: **28b** (slow `2xx` + fast internet → `healthy`) and **28c** (slow `2xx`
  + CDNs blocked → `healthy`) pin the two `healthy` branches — the whole point.

## Out of scope (unchanged from prior plans)

A backend-slow signal of its own (that is the reserved `serverDegraded`,
body-reported), an adaptive/relative `slowThreshold` (follow-up measurement #4
in `2026-07-19-001-…-plan.md`), and any EWMA/windowed smoothing (wrong tool at
this probe cadence — see that plan's §Sources and the 5-agent audit).
