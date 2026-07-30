---
title: A latency verdict must measure the axis it names, not a proxy for it
date: 2026-07-30
category: design-patterns
module: connection_health_monitor
problem_type: design_pattern
component: service_object
severity: medium
applies_when:
  - Deriving a user-facing verdict ("weak network", "slow", "degraded") from a single measurement
  - A signal is named after one cause but measured from a quantity that has several causes
  - Reviewing a state that attributes fault ("your wifi", "our servers") to the user
  - Tempted to infer the user's condition from a round-trip that also includes your own
tags: [latency, fault-attribution, weaknetwork, two-signal, measure-what-you-name, connectivity-monitor]
---

# A latency verdict must measure the axis it names, not a proxy for it

## Context

`ConnectionHealthState.weakNetwork` is defined — in CONCEPTS.md and its own
dartdoc — as *"your link is slow, the server is fine."* It is a claim about the
**user's internet**. But the 0.2.0 implementation reported it from the
**backend** round trip alone: a `2xx` slower than `slowThreshold` became
`weakNetwork`, full stop.

The backend round trip is not the user's link. It is `user-link + our-server
think-time`. So a slow *backend* on a perfectly healthy link surfaced as "Weak
Network", telling the user to check wifi that was fine. The verdict named one
axis (the user's link) and measured another (a round trip that bundles the
user's link with our latency).

This never fired in the field — `/healthz` is a liveness literal built to be
fast, so the backend contribution is ~0 in practice, and the mislabel was
first filed as a low-value known-limit. But it was surfaced by review, and the
fix (0.3.0) is cheap and makes the code honest, so it shipped.

## Guidance

**A verdict that names a cause must measure that cause — not a proxy that
happens to correlate with it.** When a single measurement (here: one round
trip) has more than one cause, deriving a fault-attributing verdict from it
mislabels whenever the *other* cause dominates.

The repair is a **two-signal** check: use the cheap proxy as a *trigger*, then
measure the named axis directly before committing to the verdict.

```
slow round trip to our server   → TRIGGER only (could be us or them)
  measure the USER's link directly (neutral-CDN probe, timed)
    link also slow  → weakNetwork   (positive evidence — the named axis)
    link fast/blocked/error/timeout → healthy (no proof; never blame the link)
```

Two principles fall out:

- **Positive evidence only.** Never attribute fault to the user's side without
  a direct measurement of it. Absence of proof resolves to the benign state
  (`healthy`), not the accusing one. This also disposes of adjacent edge cases
  for free: a firewall that reaches our host but blocks the CDN probes yields
  no positive evidence → `healthy`, not a false "weak link".
- **Trigger cheap, verify only when triggered.** The direct measurement is the
  expensive part (a second probe). Gate it behind the cheap proxy so the happy
  path stays one request; the second probe runs only on the rare slow trigger.

## Why This Matters

A mislabelled fault sends the user to fix the wrong thing. "Weak Network" tells
them to move rooms or toggle wifi; if the lag was actually the backend, none of
that helps and the banner lied. The cost is not a crash — it is a confident,
actionable, *wrong* instruction, which is worse than silence.

The trap is seductive because the proxy usually works: when the user's link
really is slow, the round trip is slow too, so the naive measurement is right
*most* of the time. The bug only shows when the other cause dominates — which
is exactly when a monitoring signal most needs to be correct.

Note what the fix did NOT do: it did not add smoothing (EWMA/windows are the
wrong tool at a 1–5 min probe cadence — see the 0.2.0 audit), and it did not
add a new state for "backend slow" (that is the reserved `serverDegraded`,
which measures a *different* axis — the backend's self-report). It measured the
axis already named. The smallest honest change is the one that makes the
measurement match the claim.

## When to Apply

- A signal's NAME asserts a specific cause ("weak network", "server slow"),
  but its MEASUREMENT is a quantity with several causes.
- A verdict attributes fault to the user ("check your wifi") — audit whether
  you actually measured the user's side, or inferred it.
- You are about to derive a state from a round trip, a timer, or a rate that
  silently bundles your own contribution with the thing you mean to report.

## Examples

**Before (0.2.0) — names the link, measures the round trip:**

```dart
if (serverOk) {
  return clock.now().difference(startedAt) > slowThreshold
      ? ConnectionHealthState.weakNetwork   // could be OUR latency
      : ConnectionHealthState.healthy;
}
```

**After (0.3.0) — trigger on the proxy, then measure the named axis:**

```dart
if (serverOk) {
  if (clock.now().difference(startedAt) <= slowThreshold) {
    return ConnectionHealthState.healthy;            // fast path to us → link fine
  }
  // Slow 2xx is only a trigger. Measure the user's real internet.
  return await _userInternetIsSlow()                 // positive evidence
      ? ConnectionHealthState.weakNetwork
      : ConnectionHealthState.healthy;               // no proof → don't blame the link
}
```

## Related

- `docs/plans/2026-07-30-001-feat-weak-internet-two-signal-plan.md` — the change.
- `CONCEPTS.md` — the `weakNetwork` vs `serverDegraded` axis distinction ("your
  link is slow, the server is fine" vs "the link is fine, the backend is sick").
- `CLAUDE.md` §4 "Known limits" #3 — where this was first recorded as a
  reserved edge, now marked RESOLVED.
- `docs/solutions/architecture-patterns/health-endpoint-liveness-vs-readiness.md`
  — why the backend contribution to the round trip is ~0 (liveness), which is
  what made the mislabel rare rather than constant.
