---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
plan_type: feat
depth: lightweight
created: 2026-07-18
---

# feat: Confirm-before-alarm hysteresis for connection health

**Target repo:** `neo_connection_health` (branch `feat/weak-network-state`)

## Summary

`ConnectionHealthMonitor` flips its reported state on a **single** probe result. One
blip — a lift, a tunnel, a momentarily overloaded backend — is enough to emit
`internetDisconnected` and put a "No Network" banner in front of the user while
nothing is actually wrong.

Add an opt-in `downConfirmationCount`: a degraded state must be observed on N
**consecutive, identical** probes before it is emitted. Recovery to `healthy` stays
immediate. Default `1` reproduces today's behaviour exactly, so no existing consumer
changes.

## Problem Frame

`_emitIfChanged` is the only gate between a probe result and the broadcast stream, and
it gates on *difference*, not *confidence*:

```
_currentState = state;
if (state == _lastState) return;   // de-dupe only
_lastState = state;
_controller.add(state);
```

There is no consecutive-observation requirement anywhere in the monitor. The adaptive
5min/1min schedule is sometimes mistaken for natural hysteresis — it is not. A long
interval reduces how *often* a blip can land on a check; it does nothing to protect the
consumer once one does.

This is the same problem health-checking systems solve with an unhealthy threshold. AWS
ALB runs a comparably infrequent 30s interval and *still* requires
`UnhealthyThresholdCount=2` before marking a target unhealthy — infrequent polling and
multi-sample confirmation are complementary, not alternatives.

## Requirements

- **R1** — A degraded state is emitted only after `downConfirmationCount` consecutive
  probes report that **same** state.
- **R2** — Two different degraded results in a row do not confirm either one. The streak
  is per-state, not a generic "bad" counter; an inconsistent story keeps the previous
  reported state in place.
- **R3** — `healthy` is emitted immediately, always. Recovery is never delayed.
- **R4** — Default `downConfirmationCount: 1` is byte-for-byte today's behaviour. No
  existing consumer sees a change without opting in.
- **R5** — `currentState` never reports an unconfirmed state, so a late stream subscriber
  is never replayed something the stream itself never emitted.
- **R6** — An unconfirmed degraded probe still reschedules at `retryInterval`, so
  confirmation arrives on the fast cadence rather than the 5-minute healthy one.

## Key Technical Decisions

**KTD1 — Per-state streak, not a generic bad counter.** Product decision, taken
explicitly: `internetDisconnected` followed by `serverUnreachable` confirms neither. A
generic counter would announce a state it had only observed once. Cost is one extra
field (`_streakState`).

**KTD2 — Gate inside `_emitIfChanged`, before `_currentState` is assigned.** Placing the
gate here — rather than in `_loop` or `_runCheck` — keeps `currentState` and the stream
consistent by construction (R5), and leaves the scheduling path untouched so R6 falls out
for free.

**KTD3 — Asymmetric: confirm down, trust up.** Matches the product's stated "slow to
alarm, fast to reassure" posture. Note this is deliberately the *inverse* of the
circuit-breaker convention (fast-fail, slow-recover) — circuit breakers protect a fragile
downstream from retry storms, a motive that does not apply to one phone polling once a
minute. Different goal, different asymmetry.

**KTD4 — `checkNow()` is left alone.** It is documented as a pure probe that does not
emit; making it mutate the streak counter would break that contract. It has no callers in
the consuming app today. Documented, not changed.

## Implementation Units

### U1. Confirm-before-alarm gate in the monitor

**Goal:** A degraded state reaches the stream only after N consecutive identical
observations.

**Requirements:** R1, R2, R3, R4, R5, R6

**Dependencies:** none

**Files:**
- `lib/src/connection_health_monitor.dart` (modify)
- `test/connection_health_monitor_test.dart` (modify)

**Approach:**
Add `final int downConfirmationCount` to the constructor, defaulting to `1`, asserted
`>= 1`. Add two private fields: the state currently being counted, and its run length.
Insert a confirmation check at the top of `_emitIfChanged` that returns early — touching
neither `_currentState` nor `_lastState` — while a degraded state is still unconfirmed.
`healthy` resets the streak and always passes.

Do not touch `_loop`'s scheduling call: it passes the raw probe result to `_nextDelay`,
which is what gives R6.

**Patterns to follow:** the existing `assert` style in the constructor initializer list
(see `jitterRatio`, `slowThreshold`); the existing private-field doc-comment convention
in the "Private state" section.

**Execution note:** Behaviour change in a de-dupe path with existing coverage — run the
full existing suite before adding new cases to prove `downConfirmationCount: 1` really is
a no-op.

**Test scenarios:**
- Default (`1`): a single `internetDisconnected` emits immediately — existing suite passes unchanged.
- `2`: one bad probe emits nothing; a second identical bad probe emits once.
- `2`: bad → healthy → bad emits only `healthy`; the streak resets, so the second bad is unconfirmed.
- `2`: `internetDisconnected` → `serverUnreachable` emits neither (R2).
- `2`: `internetDisconnected` ×2 → `serverUnreachable` ×2 emits both, in order.
- `2`: recovery from a confirmed degraded state emits `healthy` on the first healthy probe (R3).
- `2`: `weakNetwork` ×2 confirms and emits.
- `2`: while a bad probe is unconfirmed, `currentState` still reports the last confirmed value (R5).
- `2`: an unconfirmed bad probe schedules the next check at `retryInterval`, not `healthyInterval` (R6).
- `downConfirmationCount: 0` throws `AssertionError`.

**Verification:** full package suite green; the pre-existing 32 tests pass without
modification.

### U2. Document the new behaviour

**Goal:** A consumer can tell what the knob does and what it deliberately does not cover.

**Requirements:** R3, R4, KTD4

**Dependencies:** U1

**Files:**
- `README.md` (modify)
- `lib/src/connection_health_monitor.dart` (doc comments only)

**Approach:** Add `downConfirmationCount` to the constructor doc list and the README API
table. State the asymmetry (confirm down, trust up) and that `checkNow()` does not
participate in the streak.

**Test expectation: none — documentation only.**

**Verification:** `dart analyze` clean; README describes the default as behaviour-preserving.

## Scope Boundaries

**In scope:** the confirmation gate and its documentation, in the package.

**Out of scope (decided upstream, not deferred):**
- Any OS-connectivity-event nudge. Investigated and explicitly rejected — the app already
  runs a 5-second app-wide offline check, and a `checkNow()`-based nudge would cancel the
  pending 1-minute retry and reschedule at 5 minutes, making recovery *worse*.
- Changing the 5min/1min cadence or `slowThreshold`.

### Deferred to Follow-Up Work
- Picking the app-side value (`2` vs `3`) and passing it from `ConnectionHealthCubit`.
- Product decision on the duplicate offline warnings (`InternetConnectionCheckingService`
  toast vs. this banner).

## Risks

**Existing tests silently depend on single-probe flips.** Default `1` should make this
inert; the U1 execution note requires proving it by running the suite unchanged before
adding cases.

**`currentState` divergence.** Gating before the `_currentState` assignment is what
prevents a late subscriber being replayed an unconfirmed state — a subtle ordering
dependency worth preserving if this code is refactored.

## Definition of Done

- `downConfirmationCount` exists, defaults to `1`, asserts `>= 1`.
- Pre-existing 32 tests pass unmodified.
- New tests cover R1, R2, R3, R5, R6 and the assert.
- `dart analyze` clean.
- README and constructor docs updated.
