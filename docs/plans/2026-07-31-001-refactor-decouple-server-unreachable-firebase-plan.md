---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-brainstorm
---

# Decouple `serverUnreachable` — firebase owns server-down - Plan

**Status:** Implementation-ready (enriched 2026-07-31 from the 2026-07-31
requirements-only brainstorm). Decision locked; the code, tests, and CHANGELOG
become the source of truth once it lands.

**Product Contract preservation:** Product Contract unchanged — the WHAT
(firebase owns server-down; package stops emitting `serverUnreachable`, comment
out, keep the enum) is carried verbatim from the brainstorm. This enrichment
adds only the HOW: the exact seam, the full test blast radius, and the
verification contract.

---

## Goal Capsule

- **Objective:** Stop the package from deciding "our backend is down." That
  fact moves to the app's existing firebase `system_banners` channel. The
  package keeps owning client-link quality only.
- **Product authority:** Vaibhav (this repo). App-side wiring is the Neosapien
  app team's follow-up.
- **Open blocker:** None for the package change. Two accepted trade-offs
  (server-down is ops-manual; server faults now fail silent-`healthy` — see
  Known limits).

---

## Problem

Two things currently claim "our backend is down," and they will fight:

1. **Package** — `ConnectionHealthMonitor._runCheck` HTTP-probes `/healthz`; on
   failure-with-internet-up it emits `serverUnreachable`
   (`lib/src/connection_health_monitor.dart:501-503`). The app maps that to the
   `serverDown` banner.
2. **App / firebase** — the dashboard already renders admin-published banners
   from the Firestore `system_banners` collection (`SystemBannerCubit` →
   `SystemBannerStack`, `system_banner_repository_v1.dart`), live via
   `.snapshots()`. Ops can publish a critical "Server Down" banner from there.

A client HTTP probe is a poor server-down oracle — CLAUDE.md §4 "Known limits"
lists its false-positive class (whitelisting networks that block our host,
`404` from a wrong `healthPath`, iOS-MDM TLS interception). An ops-published
firebase flag does not guess. Having both, and having the app *override* one
with the other, reintroduces the dual-source-of-truth bugs the
`ConnectionHealthCubit` already fights (`_isRecovered`, stale-verdict guards,
false `Back Online`).

---

## Decision — one owner per concern (Approach A)

Do **not** override; decouple by ownership.

| Concern | Owner after |
|---|---|
| Our backend is down | **firebase `system_banners`** (ops-manual) |
| Internet down (`internetDisconnected`) | package — unchanged |
| Weak link (`weakNetwork`) | package — unchanged |

Rejected: **B (app-side override)** — keeps two owners and the merge bugs;
**C (injectable `serverDown` stream into the package)** — most code, YAGNI now;
recorded as the future path if the package must be the single authority again.

---

## Key Technical Decisions

- **KTD1 — server-fail + internet-up now returns `healthy`, not a new state and
  not `internetDisconnected`.** The package no longer judges the backend. With
  the internet probe passing, the device's *link* is fine, and `healthy` is the
  package's honest verdict about the only thing it still owns (link quality).
  No fifth enum value: the user's action in the retired case was always
  identical to a real outage (wait / switch networks), and firebase now carries
  the message.
- **KTD2 — comment out, keep the enum value AND the retired return line.** The
  `serverUnreachable` enum value stays (deleting it is a source break —
  CLAUDE.md §1). The `return serverUnreachable` line is commented, not removed,
  with a pointer to this plan, so re-enabling (Approach C) is a diff, not an
  archaeology dig.
- **KTD3 — the confirmation-gate tests that need a *second* failure mode are
  skipped-and-kept, not deleted.** Retiring `serverUnreachable` leaves
  `internetDisconnected` as the ONLY probe-reachable failure state, so the
  gate's **Rule 2** (alternation between two distinct failure modes) can no
  longer be exercised through the public surface. Five tests that rely on it
  (#32, #32b, #33, #36, #41 — #41 is the load-bearing weakNetwork/Rule-2
  regression guard CLAUDE.md calls "the single most-repeated bug in this
  package's history") are marked `skip:` with a pointer here. This mirrors the
  source change's "comment out, keep" ethos — un-skipping restores the coverage
  the moment `serverUnreachable` returns. Chosen over deleting them (loses the
  guard from the file) and over reworking #41 onto a `weakNetwork` alternation
  (more surgery for a state that is retired anyway).
- **KTD4 — version → `0.4.0` (minor bump).** Behavior change with no *source*
  break: the enum and public API are unchanged, so consumer `switch`es still
  compile — a `serverUnreachable` arm simply goes dead. Under semver's `0.x`
  rule this repo already uses (minor is the breaking/behavior slot; see
  `pubspec.yaml` and the `0.3.0` precedent, itself a pure behavior change), a
  state ceasing to be emitted is a `0.4.0`.

---

## Product Contract

### In scope (this repo)

- Retire `serverUnreachable` **production** in `_runCheck`. The
  `server-fail + internet-up` branch returns `healthy`. The `!hasInternet`
  branch is unchanged. Exact seam
  (`lib/src/connection_health_monitor.dart:501-503`):

  ```dart
  if (!hasInternet) return ConnectionHealthState.internetDisconnected;
  // serverUnreachable is now owned by firebase `system_banners` (app side) —
  // see docs/plans/2026-07-31-001-…-firebase-plan.md. Package no longer
  // reports backend-down; with internet up, its own link is fine.
  // return ConnectionHealthState.serverUnreachable;
  return ConnectionHealthState.healthy;
  ```

- **Comment out, do not delete** the enum value and the return line (KTD2).
- Update the `serverUnreachable` enum dartdoc and the `_runCheck` /
  `_nextDelay` dartdoc that describe it as emitted — mark it reserved / not
  emitted in production since `0.4.0`, pointing here.
- Retarget the tests that assert emitted `serverUnreachable` (see the Test
  blast radius below — 14 tests across three buckets, not the 3 the brainstorm
  estimated), plus one new test (#13c) pinning `followRedirects = false`.
- CHANGELOG `0.4.0` entry + `pubspec.yaml` version bump.

### Out of scope

- Deleting the `serverUnreachable` enum value (breaking change — CLAUDE.md §1).
- Any firebase / Firestore dependency in the package (load-bearing pure-Dart
  constraint — CLAUDE.md §Tech). All firebase work is app-side.
- Building/automating the firebase writer — server-down is ops-manual for now.
- The `serverDegraded` reserved state — untouched.
- A diagnostic callback surfacing the retired failure kind — deferred to the
  trigger-seam plan (KTD13); see Known limits.

### Deferred to Follow-Up Work

- **README + CLAUDE.md quick-reference sync.** Both show a `serverUnreachable`
  switch arm and "Server down" copy that go dead (still compile). Stale, not
  broken — a light follow-up, kept out of this PR to hold the diff to the
  behavior change. CHANGELOG is the source-of-truth record per the doc
  convention.

### Downstream (app, follow-up PR — not this repo)

- `ConnectionHealthCubit`'s `case serverUnreachable → serverDown` becomes dead
  (never emitted). Comment it out, leave the enum arm.
- The `NetworkFailureTicker → checkNow` trigger existed **only** to catch
  `serverUnreachable` faster. With that state retired it has no job — comment
  out the ticker wiring (`http_shared.dart` tick + cubit `_onFailureTick`).
- Ops runbook: publishing a `system_banners` critical doc is now the way
  "Server Down" reaches users.
- **Banner priority — package internet signals override the firebase
  server-down banner (app-side, "for now" rule).** The app consumes two
  streams (the package's `ConnectionHealthState` and the firebase
  `system_banners` snapshot) and must decide which banner wins when both fire.
  This is presentation logic in the app layer that renders both banners
  (`SystemBannerStack` / `NetworkStatusBanner`); the **package cannot and must
  not** do it (pure-Dart, never sees firebase). Highest wins:

  | Priority | Source | Banner |
  |---|---|---|
  | 1 (wins) | package `internetDisconnected` | "Check your WiFi" |
  | 2 | package `weakNetwork` | "Weak Network" |
  | 3 | firebase `system_banners` | "Server Down" (ops-published) |
  | 4 | package `healthy` | none (firebase banner shows if present) |

  `internetDisconnected` over "Server Down" is correct — a user with no
  internet cannot act on "our servers are down," but can act on "check your
  WiFi." **Design flag on priority 2:** `weakNetwork` outranking a genuine
  ops-published "Server Down" shows the falsely-reassuring "will sync once the
  connection improves" while the backend is actually down — the same
  false-reassurance shape that bit the package's `weakNetwork` gate twice
  (CLAUDE.md §1). Accepted as a "for now" simplification; revisit before it
  outlives "for now" (e.g. let a `critical`-severity `system_banners` doc
  outrank `weakNetwork`).

### Known limits (accepted)

1. **Server-down is ops-manual.** If nobody publishes a `system_banners` doc, a
   real outage shows **no banner** — automatic client detection is gone. The
   deliberate trade: no false positives, at the cost of no auto-detection.
   Revisit with Approach C or an automatic firebase uptime writer if the manual
   gap bites.
2. **Server faults now fail silent-`healthy`.** With internet up, a `404` from
   a wrong `healthPath`, a `5xx`, a `3xx`, or a timeout all resolve to
   `healthy` instead of `serverUnreachable`. Test #13b's "misconfig canary"
   flips from red to green. This is the decision working as designed (the
   package no longer claims backend faults), but a wrong probe URL now fails
   silently rather than surfacing. The diagnostic-callback remedy is deferred
   (KTD13, trigger-seam plan); documented here so it is a decision, not a
   surprise.

### Success criteria

- Package never emits `serverUnreachable`; `server-fail + internet-up` yields
  `healthy`; `internetDisconnected` and `weakNetwork` behavior unchanged.
- `tool/check.sh` green (format + analyze --fatal-infos + test).
- No firebase/Flutter dependency added to the package.

---

## Test blast radius

`serverUnreachable` is the suite's only "second failure mode," so retiring it
reaches further than the brainstorm's `#2/#3/#13b` estimate. All edits are in
`test/connection_health_monitor_test.dart`. Three buckets:

| Bucket | Tests | New expectation |
|---|---|---|
| **A — retarget → `healthy`** (server-fail + internet-up IS the new healthy; these become the positive pins for KTD1) | #2, #3, #13, #13b | server 500 / timeout / 3xx / 404, internet up → `healthy` |
| **B — swap failure trigger → `internetDisconnected`** (tests that only need "a failure"; make the trigger internet-down so a real transition survives) | #5, #7b, #23, #43, #44 | same assertions, failure driven by `online: false` instead of a 5xx |
| **C — skip + keep** (need two *distinct* failure modes; unreachable once only `internetDisconnected` survives — KTD3) | #32, #32b, #33, #36, #41 | `skip: 'serverUnreachable retired 0.4.0 — see …-firebase-plan.md; un-skip with Approach C'` |

---

## Implementation Units

### U1. Retire `serverUnreachable` at the `_runCheck` seam

- **Goal:** The package stops emitting `serverUnreachable`; server-fail +
  internet-up returns `healthy`; the enum value and return line are preserved
  as commented, reversible artifacts.
- **Requirements:** KTD1, KTD2; Product Contract "In scope" #1–#3.
- **Dependencies:** none.
- **Files:**
  - `lib/src/connection_health_monitor.dart` — the seam at `:501-503`; the
    `_runCheck` dartdoc (`:436-453`) and `_nextDelay` dartdoc (`:652-663`) that
    describe `serverUnreachable` as emitted.
  - `lib/src/connection_health_state.dart` — the `serverUnreachable` dartdoc
    (`:72-79`), currently "Emitted when…".
- **Approach:** Replace the ternary return with an early `internetDisconnected`
  guard, a commented `serverUnreachable` return carrying a pointer to this
  plan, and `return ConnectionHealthState.healthy;` (see the seam snippet in
  Product Contract). Reword the enum dartdoc to "Reserved; not emitted in
  production since `0.4.0` — firebase `system_banners` owns server-down. Kept
  for re-enablement (Approach C) and consumer source compatibility." Touch the
  two method dartdocs so they no longer claim the failure branch reports
  `serverUnreachable`. Do NOT touch `_isConfirmed` / Rule 2 logic — it stays
  intact and generic (dead-reachable only, restored when the state returns).
- **Patterns to follow:** the existing commented-with-rationale style already
  in this file (e.g. the `ponytail:` drain comment at `:534`).
- **Test scenarios:** covered by U2 (the positive pins). No new production
  branch is added here — an existing branch is repointed — so the proof lives
  in the retargeted `healthy` assertions.
- **Verification:** `grep -n serverUnreachable lib/` shows only the commented
  return line and the reworded dartdocs — no live code path returns it.

### U2. Retarget the flippable tests to `healthy` (positive pins for KTD1)

- **Goal:** Prove the new behavior: server 500 / timeout / 3xx / 404 with
  internet up all resolve to `healthy`.
- **Requirements:** KTD1; Test blast radius bucket A.
- **Dependencies:** U1.
- **Files:** `test/connection_health_monitor_test.dart`.
- **Approach:** Retarget bucket A in place — rename each test and flip the
  expected emission to `healthy`. These four were the strongest existing
  `serverUnreachable` assertions, so they convert cleanly into the canonical
  proof that the package no longer reports server faults.
- **Test scenarios:**
  - #2: server `500`, internet up → emits `[healthy]` (was `serverUnreachable`).
  - #3: server timeout (`requestTimeout` fires), internet up → `[healthy]`.
  - #13: server `301` (redirects disabled), internet up → `[healthy]`. Note in
    the test comment that this no longer *proves* `followRedirects = false` at
    the state level (3xx and 2xx now both → `healthy` on internet-up); the flag
    is still set in `_probeServer`, just not observable via the emitted state.
  - #13b: server `404`, internet up → `[healthy]`. Update the comment: this is
    now the Known-limit #2 canary — a misconfigured `healthPath` fails
    silent-`healthy`, no longer indistinguishable-from-outage-`serverUnreachable`.
- **Verification:** these four tests pass and collectively assert no server
  fault (5xx / timeout / 3xx / 4xx) surfaces while internet is up.

### U3. Repair the multi-step and gate tests (swap-trigger + skip-keep)

- **Goal:** Keep the rest of the suite honest — the tests that used
  `serverUnreachable` as a generic "failure" get an internet-down trigger; the
  tests that genuinely need two distinct failure modes are skipped-and-kept.
- **Requirements:** KTD3; Test blast radius buckets B and C.
- **Dependencies:** U1.
- **Files:** `test/connection_health_monitor_test.dart`.
- **Approach:**
  - **Bucket B (swap trigger → `internetDisconnected`):** #5, #7b, #23, #43,
    #44. Drive the failure leg with `online: false` (or the harness
    `setOnline(online: false)`) instead of a 5xx, so a real degraded transition
    still occurs. Update expected states from `serverUnreachable` to
    `internetDisconnected` and adjust inline comments. #43/#44 use `gateHarness`
    — change the first-failure setup from `setStatus(500)` (now `healthy`) to
    `setOnline(online: false)` so the "two degraded observations of any kind"
    path still holds via `internetDisconnected` + slow-`200`.
  - **Bucket C (skip + keep):** #32, #32b, #33, #36, #41. Add
    `skip: 'serverUnreachable retired in 0.4.0 — see
    docs/plans/2026-07-31-001-…-firebase-plan.md; un-skip when the state
    returns (Approach C)'` to each `test(...)`. Leave the bodies intact.
- **Execution note:** run the suite after the swaps to confirm buckets A+B are
  green and bucket C reports as skipped (not failed) before moving on.
- **Test scenarios:**
  - #5: `healthy → internetDisconnected → healthy` still emits exactly 3 events
    (de-dupe across a surviving transition).
  - #7b: a state-changing `checkNow()` (→ `internetDisconnected`) still does NOT
    emit and does NOT move `currentState` past the stream.
  - #23: `checkNow()` (→ `internetDisconnected`) cannot move `currentState`
    ahead of the stream; the next scheduled tick emits it once to everyone.
  - #43, #44: the `_degradedRun` blip-protection guarantees hold with
    `internetDisconnected` as the failure.
  - #32, #32b, #33, #36, #41: present but skipped — `dart test` reports them
    skipped, suite stays green.
- **Verification:** `dart test` green with exactly 5 tests reported skipped;
  buckets A+B assert the new verdicts.

### U4. CHANGELOG `0.4.0` + version bump

- **Goal:** Record the behavior change and bump the version.
- **Requirements:** KTD4; Product Contract "In scope" #5.
- **Dependencies:** U1–U3 (describe the shipped behavior).
- **Files:** `CHANGELOG.md`, `pubspec.yaml`.
- **Approach:** Add a `## [0.4.0]` section above `0.3.0`. Lead with the
  behavior change (no source break; `serverUnreachable` no longer emitted;
  server-fail + internet-up → `healthy`; firebase owns server-down). Record:
  the retained-but-retired enum/return (Approach C reversibility), the two
  accepted Known limits, the test buckets (4 retargeted to `healthy`, 5
  trigger-swapped, 5 skipped-and-kept), and the downstream app follow-up.
  Bump `version: 0.3.0` → `0.4.0` in `pubspec.yaml`.
- **Test scenarios:** `Test expectation: none — CHANGELOG/metadata only.`
- **Verification:** `pubspec.yaml` reads `0.4.0`; CHANGELOG top section is
  `[0.4.0]` and matches the shipped behavior.

---

## Verification Contract

- **`tool/check.sh` green**, i.e. all three gates:
  - `dart format --set-exit-if-changed .`
  - `dart analyze --fatal-infos` (no new infos; the retired enum value stays
    "used" via the commented reference, skipped-test bodies, and dartdoc, so no
    unused-symbol regression).
  - `dart test` — buckets A+B pass; bucket C (5 tests) reported skipped, not
    failed.
- **No live `serverUnreachable` emission:** `grep -n serverUnreachable lib/`
  returns only the commented return and reworded dartdocs.
- **Pure-Dart intact:** no new dependency in `pubspec.yaml`; no `firebase`,
  `cloud_firestore`, or `flutter` import anywhere under `lib/`.
- **`internetDisconnected` / `weakNetwork` unchanged:** their existing tests
  (#1, #12, #20, #26–#29, #40, #42) pass untouched.

## Definition of Done

- [ ] Seam returns `healthy` on server-fail + internet-up, `internetDisconnected`
      on server-fail + internet-down; enum value and commented return preserved
      with a pointer here (U1).
- [ ] Enum + `_runCheck` + `_nextDelay` dartdocs no longer claim
      `serverUnreachable` is emitted (U1).
- [ ] Bucket A (#2, #3, #13, #13b) retargeted to `healthy` and passing (U2).
- [ ] Bucket B (#5, #7b, #23, #43, #44) trigger-swapped to `internetDisconnected`
      and passing (U3).
- [ ] Bucket C (#32, #32b, #33, #36, #41) `skip:`'d with pointer; reported
      skipped, not failed (U3).
- [ ] `CHANGELOG.md` `[0.4.0]` section + `pubspec.yaml` bumped to `0.4.0` (U4).
- [ ] `tool/check.sh` green; no firebase/Flutter dep added.

---

## Outstanding questions

- Does an automatic firebase uptime writer land later, or does ops-manual stay?
  (Decides whether Approach C is ever needed.)
- App-side: does the `serverDown` **banner copy / Figma 5838-19485** stay as-is
  when driven by an arbitrary `system_banners` message, or does ops author copy
  per-incident?

## Not re-litigating

- Pure-Dart constraint (CLAUDE.md §Decisions). No firebase in the package.
- Keep the four-plus-one-state enum shape; retire production, keep the value.
