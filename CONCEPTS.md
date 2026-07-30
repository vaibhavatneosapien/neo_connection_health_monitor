# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Relationships

A Probe produces one Observation. Observations are not shown to anyone — they reach the user only by passing the Confirmation gate, at which point they become the Reported state. Nearly every subtle defect in this package has lived in the gap between those two.

## Probing

### Probe
A single round-trip request to the configured server's health route, plus the timing of that round trip. One probe yields exactly one Observation. Probes are issued on an adaptive schedule and, on failure, are disambiguated by a second check against the wider internet to decide whether the fault is the device's or the server's.

### Observation
The raw verdict of one Probe — what was actually seen, before any smoothing. An Observation is never directly visible to a consumer.
*Avoid:* raw state, probe result

An Observation advances the gate's counters even when it changes nothing the user sees. That asymmetry is deliberate and is the most common source of surprise: code that reads "this state cleared the counter" is usually wrong unless it says *which* — observed or confirmed.

### Reported state
The value a consumer actually receives: the most recent Observation that passed the Confirmation gate. Distinct from the latest Observation, which may be newer and different.

Late subscribers are replayed the Reported state, so it must only ever hold a value that was genuinely delivered — a probe that bypasses the gate must not move it, or the two disagree.

### Weak network
An Observation that the **user's own internet** is slow enough that uploads will visibly lag — measured as a two-signal verdict, not from the backend round trip alone. A slow server response is only the *trigger*; the monitor then times the user's real internet (the neutral-CDN probe) and the Observation is `weakNetwork` only on positive evidence that link is slow (a slow *backend* on a fast link is a `healthy` Observation, not a weak one — see the plan `2026-07-30-001`). It is a **success**, not a failure — the connection works. It sits among the failure values by enum position only, and treating it as a failure is the recurring mistake this package has made twice.

Because the probe succeeded, it does not count toward a run of failures and does not suppress escalation to a real failure.

## The gate

### Confirmation gate
The rule set deciding whether a degraded Observation is allowed to become the Reported state. It exists so one bad probe — a lift, a tunnel, a single overloaded response — does not put an alarm in front of the user.

Recovery is deliberately asymmetric: a healthy Observation always passes immediately. This is the inverse of the circuit-breaker convention, because a breaker exists to shield a fragile dependency from a retry storm, which is not what a single polling client does.

### Same-state rule
The gate's first route: the same degraded state observed a configured number of times consecutively. It decides *which* label to show and keeps that label steady once shown.

### Generic-failure rule
The gate's second route: that many consecutive failures of **any** kind, but only while nothing degraded is on screen yet. It exists because the same-state rule alone has a hole — a link alternating between two different failure modes never builds a matching run, so nothing would ever be reported while every request fails.

The "while nothing is on screen yet" condition is what stops an established banner from flapping its advice on alternating probes. Which states count as "on screen" is the subtlest predicate in the package.

### Blip protection
The invariant that a single failing Observation can never change the Reported state, by either gate route. Every change to the gate must be checked against it; two separate defects have been failures of exactly this invariant.

## Flagged ambiguities

- *Weak network* (measured client-side from round-trip time — your link is slow, the server is fine) and the reserved *server-degraded* state (reported by the backend in its response body — the link is fine, the backend is sick) mean opposite things about who is at fault. The reserved name deliberately carries a `server` prefix so the two cannot collapse into one during a refactor.
- *Observation* and *Reported state* were both loosely called "state" in early work. They are distinct, and the distinction is load-bearing.
