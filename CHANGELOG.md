# Changelog

All notable changes to `neo_connection_health` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Lowered the SDK floor from `^3.11.1` to `^3.5.4` to match the consumer app; the code uses nothing past Dart 2.19, and the higher floor would break `pub get` on older toolchains.
- Default internet checker now uses `InternetConnection.createInstance()` (a dedicated instance the package owns and disposes) instead of the app-wide singleton, per `internet_connection_checker_plus`'s third-party-package guidance.
- Removed the `dart:io` import and redundant `on SocketException` catch (the generic `on Exception` already covers it), so the package no longer statically depends on `dart:io` and stays Web/WASM-capable.

### Fixed
- Constructor now asserts `jitterRatio` is in `[0, 1)`; a value `>= 1` could clamp the delay to 0 and burst back-to-back probes.
- Late subscribers no longer receive a duplicate emission when a silent `checkNow()` moved `currentState` ahead of the de-dupe baseline (per-subscriber replay de-dupe).
- README `WidgetsBindingObserver` snippet and dartdoc no longer stop the monitor on `AppLifecycleState.inactive` (a transient iOS foreground state that caused request thrash); stop only on `paused` / `detached` / `hidden`.

### Docs
- Corrected CLAUDE.md dual-tier pseudocode (`hasInternetAccess`, not the original package's `hasConnection`); clarified that `initial` is never emitted on the stream; README install now leads with path/git (package is not published).

### Tests
- Added: timeout + internet-down → `internetDisconnected`, dispose-during-in-flight-probe, `checkNow()` before `start()`, late-subscriber de-dupe after a state-changing `checkNow()`, `jitterRatio` assert, and injected-checker-not-disposed. Suite: 22 → 28.

### Known caveats
- `_probeServer` drains the response body via `Stream.drain()`; because `Future.timeout` does not cancel its source, a hung response body is only reclaimed by the transport's own idle timeout. Self-limiting in practice (tiny health body, ~60s LB idle timeout under a ≥60s retry cadence) — documented rather than fixed.

## [0.1.0] - 2026-05-16

### Added
- Initial pre-release.
- `ConnectionHealthMonitor` service with adaptive recursive polling loop (5 min healthy / 1 min retry, ±10% jitter).
- `ConnectionHealthState` enum: `initial`, `healthy`, `internetDisconnected`, `serverUnreachable`.
- Server-first dual-tier health check (`/health` GET with `followRedirects = false`; falls back to generic internet probe only when the server probe fails — fixes false-negative on corporate firewalls that whitelist the API host but block CDN-based probe endpoints).
- Lifecycle: `start()` (idempotent), `stop()` (pause, controller stays open), `dispose()` (terminal).
- `checkNow()` pure probe (returns state, does not emit on the stream).
- Broadcast `Stream<ConnectionHealthState>` with de-duplication on state change (including `initial` as starting sentinel).
- Dependency injection for `http.Client`, `InternetConnection`, and `Random` (deterministic jitter under test).
- GitHub Actions workflow + `tool/check.sh` for local + CI quality gate.

### Notes
- Caller is responsible for observing app lifecycle and calling `stop()` / `start()` on background / foreground transitions (see README §Caller responsibility).
- Pure-Dart package; no Flutter dependency. Reusable in CLI tools and server-side Dart.
