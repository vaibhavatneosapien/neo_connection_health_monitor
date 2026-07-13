# NEO-1651: Build `neo_connection_health` Dart package (end-to-end)

Parent branch: `feat/neo-1651-connection-health-monitor`
Parent ticket: https://linear.app/neosapien/issue/NEO-1651/build-neo-connection-health-monitor-dart-package-end-to-end

Source of truth: `CLAUDE.md` in the repo root (implementation spec, severity-tagged review findings folded in).

## Subtasks

### ST-1: Foundation — deps, enum, barrel, API skeleton

- **Scope:** Add deps in `pubspec.yaml` (`http`, `internet_connection_checker_plus: ^3.0.0`; dev: `test`, `fake_async`, `lints`). Create `lib/src/connection_health_state.dart` with the 4-state enum and full dartdoc. Create `lib/src/connection_health_monitor.dart` with the `ConnectionHealthMonitor` class — full constructor signature, public method signatures (`start`, `stop`, `dispose`, `checkNow`, `stream`, `currentState`), `_running`/`_disposed`/`_ownsClient` fields, URL normalization in the constructor, dartdoc on every public symbol per `CLAUDE.md` §Conventions. All method bodies throw `UnimplementedError` so the package compiles and the API surface is stable. Wire `lib/neo_connection_health.dart` barrel exporting BOTH `ConnectionHealthMonitor` AND `ConnectionHealthState`. Delete placeholder `lib/src/neo_connection_health_base.dart`.
- **Files likely touched:** `pubspec.yaml`, `lib/neo_connection_health.dart`, `lib/src/connection_health_state.dart`, `lib/src/connection_health_monitor.dart`, deletion of `lib/src/neo_connection_health_base.dart`.
- **Depends on:** none
- **Isolation:** worktree
- **Acceptance:**
  - `dart pub get` succeeds.
  - `dart analyze --fatal-infos` clean (UnimplementedError stubs are fine).
  - `dart format --set-exit-if-changed .` clean.
  - Barrel exports BOTH symbols (grep verifies two `export 'src/...'` lines).
  - `pub deps` does NOT contain `flutter`.
  - Dartdoc renders cleanly (`dart doc`) with no warnings.
  - Constructor URL normalization is implemented and unit-tested inline (one quick test, full coverage in ST-3).

### ST-2: Core implementation — loop, dual-tier check, lifecycle, jitter

- **Scope:** Implement the full logic of `ConnectionHealthMonitor` on top of ST-1's skeleton. Server-first dual-tier check (`_runCheck`), recursive `Future.delayed` loop with ±10% jitter from injected `Random`, `_emitIfChanged` honoring `initial` sentinel, `start`/`stop`/`dispose` per the lifecycle table in `CLAUDE.md` §7, in-flight request handling on stop/dispose, `checkNow()` as pure probe (no stream emit, resets schedule). `http.Request` with `followRedirects = false`. Close owned `http.Client` only.
- **Files likely touched:** `lib/src/connection_health_monitor.dart` (only).
- **Depends on:** ST-1
- **Isolation:** worktree
- **Acceptance:**
  - All `UnimplementedError` stubs replaced.
  - `dart analyze --fatal-infos` clean.
  - `dart format --set-exit-if-changed .` clean.
  - Manual smoke against `https://api.neosapien.xyz/health` returns `healthy` (one-off, not committed).
  - All §CLAUDE.md §4 rules enforced (server first, GET, `followRedirects = false`, 3xx → `serverUnreachable`).
  - All §CLAUDE.md §7 rules enforced (split `stop`/`dispose`, `_ownsClient`, in-flight guards).
  - `checkNow()` returns the state and does NOT emit on the stream (manual verification with a one-off listener).

### ST-3: Test suite — all 14 required cases

- **Scope:** Write `test/connection_health_monitor_test.dart` covering all 14 cases listed in `CLAUDE.md` §Testing + NEO-1651 description. Use `package:fake_async` for time determinism, `http.MockClient` for HTTP fakes, a fake `InternetConnection`, and a seeded `Random` for jitter. Tests must never hit the real network.
- **Files likely touched:** `test/connection_health_monitor_test.dart` (only).
- **Depends on:** ST-2
- **Isolation:** worktree
- **Acceptance:**
  - All 14 cases pass under `dart test`.
  - Test file uses no real `Future.delayed`, no real `http.Client`, no real `InternetConnection`.
  - Coverage of every public method plus the lifecycle table from `CLAUDE.md` §7.
  - `dart analyze --fatal-infos` clean.

### ST-4: Example, README, CHANGELOG

- **Scope:** Write `example/neo_connection_health_example.dart` (minimal usage demo with a printing stream listener). Write README.md covering: purpose, install, public API summary, quick-reference consumer snippet, and the copy-paste `WidgetsBindingObserver` snippet from `CLAUDE.md` §8 with the loud "caller MUST call `stop()` on background" rule. Add an initial CHANGELOG.md entry (semver, dated section).
- **Files likely touched:** `example/neo_connection_health_example.dart`, `README.md`, `CHANGELOG.md`.
- **Depends on:** ST-1
- **Isolation:** worktree
- **Acceptance:**
  - `dart run example/neo_connection_health_example.dart` runs without crashing (will likely emit `serverUnreachable` against a fake URL — that's fine).
  - README includes the full `WidgetsBindingObserver` snippet.
  - README explicitly states "caller MUST call `stop()` on background" and explains why.
  - CHANGELOG has a `0.1.0` (or chosen initial version) entry dated 2026-05-16.

### ST-5: CI / tool/check.sh

- **Scope:** Create `tool/check.sh` that runs `dart format --set-exit-if-changed .`, `dart analyze --fatal-infos`, `dart test`, exiting non-zero on any failure. Make it executable. Add a GitHub Actions workflow at `.github/workflows/dart.yml` that runs the script on every PR + push to `master`.
- **Files likely touched:** `tool/check.sh`, `.github/workflows/dart.yml`.
- **Depends on:** none
- **Isolation:** worktree
- **Acceptance:**
  - `bash tool/check.sh` exits 0 on a clean tree (after merging ST-1+ST-2+ST-3).
  - `bash tool/check.sh` exits non-zero on a deliberately broken format / analyzer / test.
  - GitHub Actions workflow YAML is valid (verified by `actionlint` if available, else by manual schema check).
  - Workflow uses `dart-lang/setup-dart@v1` and pins the SDK to `^3.11.1`.

## Merge order

Topological sort with ties broken by ST number:

1. **ST-1** (foundation, no deps) — must land first.
2. **ST-5** (CI tooling, no deps) — can merge in parallel with ST-1 or right after.
3. **ST-2** (depends on ST-1) — merges after ST-1.
4. **ST-4** (depends on ST-1) — can merge in parallel with ST-2.
5. **ST-3** (depends on ST-2) — merges last, since it validates ST-2's behavior.

## Parallelism waves

- Wave 1 (parallel): ST-1, ST-5
- Wave 2 (parallel, gated by ST-1 merged): ST-2, ST-4
- Wave 3 (gated by ST-2 merged): ST-3

## Reviewer notes

- `CLAUDE.md` is the source of truth — bounce any subtask that contradicts it without an explicit deviation note.
- ST-2 is the highest-risk subtask. Verify all 3 High-severity review items: §4 server-first check, §7 split lifecycle, §8 caller responsibilities (the §8 doc is technically in ST-4 but the dartdoc requirement on the class lives in ST-2).
- ST-3 must NOT hit the real network. If a test imports `dart:io` for actual sockets, bounce.
- ST-5 CI must NOT pin a specific minor SDK — use `^3.11.1` per `pubspec.yaml`.
