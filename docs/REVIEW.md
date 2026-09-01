# Code Review Guidelines

Authoritative review checklist for automated (and human) code review. Copy this
file to a repo's root as `REVIEW.md` to have the Claude PR review treat it as
the review criteria; tailor the "Repo-specific" section per repo.

## Review priorities, in order

1. **Correctness** — does the code do what the PR claims, for all inputs it
   will actually receive?
2. **Security** — can this change be abused, leak data, or widen an attack
   surface?
3. **Reliability** — how does it behave when dependencies fail, inputs are
   malformed, or it runs concurrently?
4. **Performance** — will it hold up at production data volumes and request
   rates?
5. **Maintainability** — will the next engineer understand and safely change
   this code?

Report findings in this order. A subtle correctness bug outranks any number of
style observations.

## Severity levels

Tag every finding:

- **P0 (Blocker)** — data loss/corruption, security vulnerability, crash on
  the main path, breaking API change without versioning. Must not merge.
- **P1 (High)** — incorrect behavior on realistic inputs, unhandled failure
  of a dependency the code relies on, race condition, resource leak.
- **P2 (Moderate)** — wrong behavior on edge cases, misleading errors or logs,
  missing test coverage for changed behavior, N+1 queries or unbounded work.
- **P3 (Low)** — naming, dead code, simplification opportunities, doc drift.

## Correctness checklist

- Verify the change matches the stated intent (PR title/description); flag
  intent-vs-implementation mismatches explicitly.
- Boundary conditions: empty collections, `None`/null, zero, negative numbers,
  maximum sizes, first/last iteration, off-by-one in ranges and slicing.
- Datetimes: timezone-aware vs naive mixing, UTC vs local assumptions, DST
  transitions, ambiguity of `now()` in server context.
- Types: implicit conversions (float vs int in formatting/division), string vs
  bytes, ID passed where a different string is expected (compiles fine, wrong
  at runtime).
- Error paths: exceptions swallowed silently, `except Exception` hiding bugs,
  fallbacks that mask the real failure, error branches that log-and-continue
  when they should abort.
- State: mutation of shared/default arguments, ordering assumptions, idempotency
  of retried operations.

## Security checklist

- No secrets, tokens, or credentials in code, config, logs, or test fixtures.
- All external input validated at the boundary (API payloads, headers, file
  uploads, webhook bodies); injection risks (SQL/NoSQL, shell, path traversal,
  SSRF) checked at every sink.
- AuthN/AuthZ: every new endpoint or action enforces authentication and the
  correct authorization scope (user-owns-resource, tenant isolation, role checks).
- Sensitive data (PII, tokens) not written to logs or error messages.
- New dependencies: prefer widely used, maintained packages; flag anything
  obscure or unpinned.

## Reliability checklist

- Network/database calls have timeouts and defined failure behavior; retries
  are bounded and idempotent.
- Resources (connections, file handles, subscriptions, temp files) are released
  on all paths, including exceptions.
- Concurrency: shared state guarded; no check-then-act races; background tasks
  have error handling so failures aren't silent.
- Backwards compatibility: rolling deploys mean old and new code run together —
  schema changes, message formats, and API contracts must tolerate both.
- Migrations are reversible or have an explicit, stated rollback plan.

## Performance checklist

- No unbounded queries or loops over user-controlled data sizes; pagination on
  list endpoints.
- No N+1 database/API call patterns introduced.
- Hot paths avoid needless allocation, serialization, or repeated computation
  that a local variable would cache.
- Blocking calls not introduced into async contexts.

## Maintainability checklist

- Changes are minimal for the stated goal — flag speculative abstractions,
  unused parameters, and features nobody asked for (YAGNI).
- New code follows the conventions of the surrounding code and of the repo's
  `CLAUDE.md` where present.
- Public functions have accurate docstrings/types; the docstring matches what
  the code actually does (stale docs are a finding).
- Tests: changed behavior has test coverage; tests assert outcomes, not
  implementation details; no tests that can't fail.

## What NOT to flag

- Pure formatting or import ordering (linters/formatters own this).
- Personal style preferences with no correctness or readability consequence.
- Pre-existing issues in untouched code, unless the PR makes them worse or
  they directly interact with the change (mention at most briefly, clearly
  labeled as pre-existing).
- Speculative "what if requirements change" concerns with no current impact.

## Reporting format

For each finding: **severity, file:line, one-sentence defect statement, the
concrete failure scenario (inputs/state → wrong outcome), and a suggested fix.**
Uncertain findings are worth reporting — say so and let a human decide; silence
is worse than a labeled maybe. End with a verdict: ready to merge, ready with
nits, or not ready (with the blocking items listed).

## Repo-specific

Pure-Dart package (`neo_connection_health`) — monitors device internet AND a
server's reachability, streaming `ConnectionHealthState`. The conventions in
`CLAUDE.md` and the vocabulary in `CONCEPTS.md` are review criteria; in
particular:

- **Pure-Dart constraint (load-bearing):** the package MUST NOT depend on
  Flutter. Any new `import 'package:flutter/...'`, or a transitive dep that
  pulls Flutter (e.g. the original `internet_connection_checker` /
  `connectivity_plus`), is a **P0** — it defeats reuse in CLI / server-side
  Dart. `internet_connection_checker_plus` is the sanctioned choice for exactly
  this reason.
- **`Error` vs `Exception` catches are deliberate, not interchangeable.** The
  internet-check sites catch `on Object` on purpose — the plugin can throw a
  non-`Exception` `Error` (a null-deref on some platforms) that `on Exception`
  would miss, wedging the poller. The server-probe site catches `on Exception`
  on purpose — a programmer-bug `Error` must propagate, not be misclassified as
  a probe failure. `_loop`'s last-resort guard asserts `e is Exception` so our
  own `Error`s stay loud in debug and are swallowed only in release. Flipping
  either catch, or removing the assert, is a **P1**.
- **Inconclusive internet check returns `null` → skip the tick.** A thrown
  failure-path internet check is neither proof of offline nor proof of health:
  `_runCheck` returns `null`, and `_loop`/`checkNow` skip the tick (no emit, no
  confirmation-gate reset, last banner preserved). A change that makes a thrown
  check emit `healthy` (or `internetDisconnected`) instead is a **P1** — it
  either fakes an all-clear over a real outage or blames the user's link
  without proof.
- **Confirmation gate — the `weakNetwork`/Rule-2 exemption is the most-repeated
  bug in this package (twice).** `weakNetwork` is a SUCCESS; it must not count
  as "degraded is on screen" for Rule 2 and must clear `_degradedRun` on
  observation, but it DOES confirm through the same `_isConfirmed` gate and CAN
  confirm via Rule 2's generic-failure shortcut (test 43 pins this). Adding a
  `state != weakNetwork` guard to Rule 2 itself breaks test 43 and re-opens the
  never-confirms trap — **P1**. Read
  `docs/solutions/architecture-patterns/weaknetwork-disarms-confirmation-rule-2.md`
  and the `_isConfirmed` dartdoc before touching anything near
  `downConfirmationCount`.
- **`serverUnreachable` is retired (0.4.0), not deleted.** It is no longer
  emitted — a server probe that fails while the internet is up returns
  `healthy`; server-down moved to the app's firebase channel. The enum value
  and its producing `return` are kept commented for source compat / Approach-C
  re-enablement. Removing the enum value is a breaking change (**P1** without a
  version bump + CHANGELOG); re-emitting it in production is a scope change that
  needs a decision, not a silent PR.
- **HTTP probe: `GET`, not `HEAD`; `followRedirects = false`.** The real
  backend declares `@app.get`, so `HEAD` returns `405` and any 3xx/4xx is
  treated as a failure. Switching to `HEAD` or enabling redirect-following is a
  **P1**. Consumers pass `healthPath: '/healthz'` (the package default stays
  `/health`); don't "fix" the default.
- **Timing uses `clock.now()`, never `Stopwatch`.** `fake_async` fakes the
  `Clock` but leaves `Stopwatch` on the real wall clock, so a stopwatch reads
  ~0 in every test. A new `Stopwatch` on a timed path is a **P2** (silently
  untestable).
- **Scheduling is a recursive `Timer`/`Future.delayed` loop with a
  `_generation` counter and ±jitter — NOT `Timer.periodic`.** Watch for
  double-scheduling, leaked `_pendingTimer`, or emits after `stop()`/`dispose()`
  (the loop must re-check `_running`/`_disposed`/`gen` after `await`). Removing
  jitter reintroduces the thundering-herd risk. These are **P1**.
- **Lifecycle: `stop()` pauses (controller stays open), `dispose()` is
  terminal.** `dispose()` closes the broadcast controller and the HTTP client
  **only if package-owned** (`_ownsClient`) — never close an injected client.
  Any method on a disposed instance throws `StateError`. Closing the controller
  in `stop()`, or closing an injected client, is a **P1**.
- **Stream de-dupe + `initial` sentinel:** only emit on actual state change;
  `initial` is a valid previous-state baseline and is never itself emitted /
  replayed. `checkNow()` is a pure probe — it must NOT emit or move
  `currentState`.
- **The barrel `lib/neo_connection_health.dart` must export BOTH
  `ConnectionHealthMonitor` AND `ConnectionHealthState`.** Dropping the enum
  export is a finding (consumers can't pattern-match without importing `src/`).
- **Tests:** `package:test` + `package:fake_async` + `http.MockClient`, with
  `http.Client` / `InternetConnection` / `Random` injected — no real network,
  no wall-clock, no real `Future.delayed`. Changed behavior needs coverage
  (**P2** if absent); a test that can't fail is a finding.
- **CI gate:** `tool/check.sh` runs `dart format --set-exit-if-changed .`,
  `dart analyze --fatal-infos`, and `dart test`. A PR that doesn't pass it is
  not ready. Keep `CHANGELOG.md` updated per semver on any public-API or
  behavior change.
