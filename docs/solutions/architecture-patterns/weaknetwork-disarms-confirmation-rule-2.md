---
title: weakNetwork on screen disarms the confirmation gate's generic-failure rule
date: 2026-07-19
category: architecture-patterns
module: connection_health_monitor
problem_type: bug
component: service_object
severity: high
applies_when:
  - Changing `_isConfirmed`, `downConfirmationCount`, or the `reportingDegraded` predicate
  - Adding a new route into `ConnectionHealthState.weakNetwork`
  - Debugging a banner that reports a working-but-slow connection while the device is offline
tags: [confirmation-gate, hysteresis, weak-network, never-confirms, downConfirmationCount, state-machine]
---

# weakNetwork on screen disarms the confirmation gate's generic-failure rule

## Status

**Fixed 2026-07-20** on `feat/weak-network-state`, in the unreleased 0.2.0 section. Both halves shipped, with a third regression guard the original write-up did not anticipate — see Fix below.

## Symptom

The user sees **"Weak Network — Neo 1 is still capturing. Your memory will sync once the connection improves"** while the device is in fact fully offline and every request is failing. The banner never corrects itself. It reads as reassuring, so it is worse than showing nothing.

Only reproduces at `downConfirmationCount >= 2`. The consumer app ships `2`.

## Mechanism

`_isConfirmed` gates a degraded state behind two rules:

- **Rule 1** — the same state observed `downConfirmationCount` times in a row.
- **Rule 2** — `downConfirmationCount` consecutive failures of *any* kind, but only while nothing degraded is being reported yet.

Rule 2 exists precisely to stop a link alternating between two failure modes from reporting nothing forever (see CHANGELOG 0.2.0). Its guard is:

```dart
final reportingDegraded = _currentState != ConnectionHealthState.healthy &&
    _currentState != ConnectionHealthState.initial;
```

`weakNetwork` is neither `healthy` nor `initial`, so it counts as "degraded on screen" and **disarms rule 2**.

Now the trap. Reach `weakNetwork` — today that happens whenever a probe succeeds but exceeds `slowThreshold` — and then let the link degrade into *alternating* failure modes (`internetDisconnected` one tick, `serverUnreachable` the next, which is what an unstable link on a corporate or tier-2 network produces):

- Rule 1 never fires — no state manages two in a row.
- Rule 2 never fires — it is disarmed because `weakNetwork` is on screen.

Nothing ever confirms. `_currentState` stays `weakNetwork` indefinitely.

This is the exact never-confirms trap rule 2 was written to close, re-entered through a state rule 2 does not recognise as an empty banner.

## Why it is easy to miss

`weakNetwork` is a *successful* probe — the server answered, just slowly. It sits in the enum among failure states but semantically belongs with `healthy`. The `reportingDegraded` predicate was written as "not healthy and not initial", which reads correct and is not.

No test covers it: the existing suite reaches `weakNetwork` only from a stable slow link, never from one that subsequently degrades into mixed failures.

## Fix

Two halves. Applying only the first creates a different bug.

**1. Exclude `weakNetwork` from `reportingDegraded`.** It is a working connection, so escalating out of it should be allowed generically:

```dart
final reportingDegraded = _currentState != ConnectionHealthState.healthy &&
    _currentState != ConnectionHealthState.initial &&
    _currentState != ConnectionHealthState.weakNetwork;
```

**2. Reset `_degradedRun` on every `weakNetwork` OBSERVATION — not on confirmation.** Without this, half 1 opens a false-confirm path. `_degradedRun` is only ever cleared by a `healthy` observation, and confirming `weakNetwork` requires it to have already reached `downConfirmationCount` — so the moment `weakNetwork` is displayed, the counter is already at threshold. Rearming rule 2 then lets the very next failure of any kind confirm on a **single** observation, defeating the blip protection `downConfirmationCount` exists to provide.

**Gating the reset on confirmation is not enough, and this is the subtle part.** An *unconfirmed* `weakNetwork` still incremented `_degradedRun` on the way in. Since nothing is on screen yet, `_currentState` is `healthy` and rule 2 is armed — so one slow probe followed by a single failure confirms that failure on one failing observation. Verified: at `downConfirmationCount: 2`, a 4-second 200 followed by one 500 emitted `serverUnreachable`. The reset must be unconditional on the state, placed after both rules:

```dart
if (state == ConnectionHealthState.weakNetwork) {
  _degradedRun = 0;
}
```

This was caught in code review, not by the original test set — see the third regression test below for why.

With both halves: leaving `weakNetwork` requires a fresh run of `downConfirmationCount` observations, which rule 2 supplies for mixed failures and rule 1 supplies for a steady one.

## Regression tests

Three, not two. The third is the one that matters most, and it was missing from the first attempt at this fix.

1. **Escalation guard (test 41).** From an established `weakNetwork` at `downConfirmationCount: 2`, alternate `internetDisconnected` and `serverUnreachable` for several probes and assert a failure state is eventually emitted. Fails before the predicate change, passes after.
2. **Blip guard, rule-1 route (test 42).** From a `weakNetwork` established by two consecutive slow probes, a **single** failure must still not confirm. Fails if half 2 is omitted.
3. **Blip guard, unconfirmed route (test 44).** One slow probe that does NOT emit, then a single failure — assert nothing is emitted.

**Why 3 is load-bearing.** Tests 1 and 2 both drive `weakNetwork` all the way to confirmation before failing, so both enter the failure step with `_degradedRun` already cleared. The unconfirmed path — where the counter is still primed — is invisible to them. A reset gated on `confirmed` passes both and still ships the bug. Any guard written for this class must reach the failure step from an *unconfirmed* `weakNetwork`, or it is testing the already-safe path.

A fourth (test 43) covers `weakNetwork` reached via rule 2 rather than rule 1 — from `healthy`, one failure then one slow success — since the existing suite only ever reached it by the rule-1 route.

## Related

- `CHANGELOG.md` 0.2.0 — the rule-2 fix this extends, and its scoping to "two failure modes"
- `docs/plans/2026-07-19-001-feat-connectivity-trigger-and-damping-plan.md` — Open Questions; any mechanism that adds a second route into `weakNetwork` makes this bug common rather than rare
- `lib/src/connection_health_monitor.dart` — `_isConfirmed`, and the `_streakState` / `_streakCount` / `_degradedRun` counters
