---
title: A regression guard that establishes the state cannot see the path into it
date: 2026-07-20
category: design-patterns
module: connection_health_monitor
problem_type: design_pattern
component: testing_framework
severity: high
applies_when:
  - Writing a regression guard for a bug whose repro requires the system to already be in a particular state
  - Adding a counter reset, guard, or exemption keyed on a state
  - Reviewing a fix whose tests all pass but whose reasoning has an unexercised branch
  - Trusting mutation testing as proof that a guard set is complete
tags: [regression-testing, test-design, state-machine, mutation-testing, false-confidence, confirmation-gate]
---

# A regression guard that establishes the state cannot see the path into it

## Context

A bug was found where reaching a working-but-slow connection state and then degrading further left the user on a reassuring banner forever. The fix had two halves, and a write-up warned that applying only the first half creates a *different* bug. Three regression guards were written, and a three-way mutation check confirmed each half was load-bearing: revert half one, exactly one guard fails; revert half two, exactly three fail; apply half two to only one of the two confirming paths, exactly one specific guard fails.

All three claims were verified by actually running the mutations. The suite was green. The fix still shipped a defect that three independent code reviewers found within minutes, two of them reproducing it in isolated checkouts.

The defect: the counter reset was gated on the state being *confirmed*. An **unconfirmed** observation of that state had already incremented the counter on its way in and never cleared it, so a single subsequent failure satisfied the gate alone — destroying exactly the blip protection the feature exists to provide.

Every guard missed it for the same structural reason: each one **drove the state to confirmation before exercising the transition out of it**. Confirmation was what cleared the counter. So all three entered the interesting step with the precondition already neutralised, testing the path that was never at risk.

## Guidance

When a bug lives in a transition *out of* some state, the obvious test shape is "get into the state, then do the thing." That shape is a trap whenever **arriving at the state also runs the code you are about to test**.

Before trusting a guard, ask one question:

> Does establishing the precondition also execute the logic under test?

If yes, the guard is blind to the case where the system reached that state *quietly* — observed but not committed, entered but not emitted, computed but not confirmed. Most state machines have both a loud arrival and a quiet one, and only the loud one is convenient to write a test for.

The rule that follows: **for any state with an entry condition, write one guard that arrives the quiet way.** Not as extra coverage — as the primary guard. The loud path usually has the safety property by construction; the quiet path is where the bug lives.

## Why This Matters

The failure mode is not a missing test. It is a guard set that is *systematically* aimed away from the defect, so adding more tests of the same shape increases confidence without increasing coverage. Green stays green while the bug ships.

It also defeats mutation testing, which is the tool you would normally reach for to check a guard set. Mutation testing proves your tests can detect changes to the code **as written**. It cannot reveal a branch the code never had. Here all three mutations perturbed whether the reset line was *present* or *where* it sat; none questioned the reset's *condition*. A guard set can be provably sensitive to every mutation of the shipped code and still be blind to the shipped code being wrong.

The cost compounds: the write-up for the original bug prescribed exactly two regression tests, both of the establishing shape. Following that prescription faithfully reproduced the blind spot one level up. A documented fix can encode its own blind spot and hand it to the next person.

## When to Apply

- The repro requires the system to already be in a particular state
- The fix adds a reset, clear, exemption, or guard keyed on a state or a status flag
- The state has both a "committed" and an "in-flight / provisional / unconfirmed" form
- A counter, streak, or accumulator is cleared at one point in a lifecycle and read at another
- Mutation testing passes and you are about to treat that as proof of completeness

## Examples

The gate accumulated a run of consecutive failures. A slow-but-successful probe counted toward that run, and the fix cleared the run when that state was **confirmed**:

```dart
// Blind spot: an unconfirmed observation already incremented the run above,
// and nothing clears it.
if (confirmed && state == ConnectionHealthState.weakNetwork) {
  _degradedRun = 0;
}
```

```dart
// Corrected: the reset keys on the OBSERVATION, not on confirmation.
if (state == ConnectionHealthState.weakNetwork) {
  _degradedRun = 0;
}
```

The two original guards, in shape:

```
guard A:  slow, slow            -> state confirmed -> then fail  -> assert no alarm
guard B:  fail, slow            -> state confirmed -> then fail  -> assert no alarm
```

Both reach `confirmed`, which is the reset. Neither can observe a primed counter. The guard that finds the bug never confirms at all:

```
guard C:  slow (does NOT emit)  -> then fail                     -> assert no alarm
```

One probe, no confirmation, one failure. It fails before the fix and passes after — and it is the only one of the three that does.

A useful way to name the shapes when writing them: guards A and B test *leaving* the state; guard C tests *approaching* it. A guard set with no approach test is incomplete regardless of how many departure tests it has.

## Related

- `docs/solutions/architecture-patterns/weaknetwork-disarms-confirmation-rule-2.md` — the underlying gate bug, its two-half fix, and the unconfirmed-path trap this pattern generalises from
- `CONCEPTS.md` — *Observation*, *Reported state*, *Confirmation gate*, *Blip protection*
