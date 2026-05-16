# Changelog

All notable changes to `neo_connection_health_monitor` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
