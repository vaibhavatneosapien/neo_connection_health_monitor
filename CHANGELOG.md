# Changelog

All notable changes to `neo_connection_health` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-07-19

Breaking. `ConnectionHealthState` gained a value, so any consumer with an exhaustive `switch` over it stops compiling until a `weakNetwork` arm is added. Under semver's `0.x` rules the minor is the breaking slot, hence `0.2.0` rather than `0.1.1`.

The confirmation-gate fix below folds into this section rather than cutting `0.2.1`. `0.2.0` carries a date but no git tag and was never published, so no consumer holds it and there is no release boundary to preserve — a second version number would only imply one existed.

### Added
- `ConnectionHealthState.weakNetwork` — **breaking, see above.** A probe that SUCCEEDS but exceeds `slowThreshold` (new, default 3 s) now reports `weakNetwork` instead of `healthy`. It is a client-side latency verdict on one request. Do not confuse it with the future `degraded` state reserved in CLAUDE.md §Out of scope, which is a *backend*-reported condition read from the response body — different source, different meaning, deliberately not merged.
- `slowThreshold` constructor parameter (default 3 s). Must be in `(0, requestTimeout)`; violations throw `ArgumentError` at construction rather than asserting, because asserts are stripped in release and the failure mode is silent — a consumer who raises `requestTimeout` for 3G without moving `slowThreshold` would lose `weakNetwork` entirely in the shipped build while tests stayed green.
- `downConfirmationCount` constructor parameter (default `1`, byte-for-byte the previous behaviour). Requires N consecutive **identical** degraded observations before a state is emitted, so one blip — a lift, a tunnel, a single overloaded response — no longer puts an error banner in front of the user. Recovery to `healthy` is never delayed. The run is keyed on the specific state, not on "something was wrong": `internetDisconnected` followed by `serverUnreachable` confirms neither.

### Fixed
- **A connection alternating between two failure modes no longer reports nothing, forever.** `downConfirmationCount` counted only runs of the *same* state, so a link flipping between `internetDisconnected` and `serverUnreachable` never built a qualifying run: the app rendered as perfectly healthy while every request failed, with no path to self-correct. A degraded state now also passes the gate on N consecutive failures of **any** kind, but only while nothing degraded is being reported yet — so an established banner still cannot flap its advice on alternating probes, and a genuine per-state run is still what hands the label over. Blip protection is unchanged: a single failure passes neither rule. This matches how Kubernetes `failureThreshold`, gRPC's connectivity state machine and Resilience4j count failure — generically, not per sub-type. Only observable at `downConfirmationCount >= 2`; the default of `1` is unaffected.
- **A slow link that then went fully offline could hold a reassuring banner forever.** The generic-failure rule above switches off once something degraded is on screen — and `weakNetwork` counted as degraded, despite being a *successful* probe. So the never-confirms trap re-opened from the other side: reach `weakNetwork` on a slow link, then degrade into *alternating* failure modes, and neither rule can fire. The user held **"Weak Network — your memory will sync once the connection improves"** on a device with no connection at all, indefinitely and with no path to self-correct. Reassuring copy on a broken device is worse than no banner. `weakNetwork` is now exempt from the "something is on screen" test, so escalating out of it is allowed generically. Confirming `weakNetwork` also clears the generic failure run — without that, the counter would already sit at threshold when the banner appeared and the exemption would let the very next single failure through on one observation. Only observable at `downConfirmationCount >= 2`; the default of `1` is unaffected.
- Constructor now asserts `jitterRatio` is in `[0, 1)`; a value `>= 1` could clamp the delay to 0 and burst back-to-back probes.
- Late subscribers no longer receive a duplicate emission when a silent `checkNow()` moved `currentState` ahead of the de-dupe baseline (per-subscriber replay de-dupe).
- README `WidgetsBindingObserver` snippet and dartdoc no longer stop the monitor on `AppLifecycleState.inactive` (a transient iOS foreground state that caused request thrash); stop only on `paused` / `detached` / `hidden`.

### Changed
- `weakNetwork` reschedules at `healthyInterval`, not `retryInterval`. The probe succeeded, so there is no outage to recover from; the fast cadence would have sustained ~1440 requests/day, and a radio wakeup each, on exactly the connections least able to spare either. Consequence: confirming a slow link under `downConfirmationCount: 2` now takes one `healthyInterval`, not one `retryInterval`.
- `checkNow()` no longer moves `currentState` — see Fixed. Its returned `Future` is now the only delivery path, as its "pure probe" contract always claimed. Practical consequence for consumers: a successful retry does not itself clear a banner driven by `stream`; act on the returned value or wait for the next scheduled tick.
- `stop()` now discards a partial confirmation run. Observations either side of a pause are not consecutive in any useful sense, and the recommended background/foreground pattern would otherwise let a probe from hours ago confirm a state alongside one from just now.
- Lowered the SDK floor from `^3.11.1` to `^3.5.4` to match the consumer app; the code uses nothing past Dart 2.19, and the higher floor would break `pub get` on older toolchains.
- Default internet checker now uses `InternetConnection.createInstance()` (a dedicated instance the package owns and disposes) instead of the app-wide singleton, per `internet_connection_checker_plus`'s third-party-package guidance.
- Removed the `dart:io` import and redundant `on SocketException` catch (the generic `on Exception` already covers it), so the package no longer statically depends on `dart:io` and stays Web/WASM-capable.

### Docs
- Documented the real Neosapien health endpoint, verified live against the backend on 2026-07-16: the route is `/healthz` (not the package default `/health`, which exists on no environment), served from `neo-backend-v2.<env->api.neosapien.xyz`. Consumers must pass `healthPath: '/healthz'`; the default is unchanged since `/health` remains the conventional choice for a reusable package. Corrected the example `baseUrl` across CLAUDE.md, README, dartdoc, and `example/` — the previous `https://api.neosapien.xyz` is the bare gateway host, not neo-backend-v2, and 404s on `/healthz`.
- Recorded live confirmation of the `GET`-over-`HEAD` decision (§Tech): `HEAD /healthz` returns `405` against the real route, which would have meant a permanent `serverUnreachable` had the package shipped `HEAD`. Also noted Cloudflare in front of the endpoint (making §4's redirect/bot-challenge handling concrete), `cf-cache-status: DYNAMIC` (a cached health response would report stale `healthy`), and ~240 ms latency against the 8 s timeout.
- Updated `docs/solutions/architecture-patterns/health-endpoint-liveness-vs-readiness.md`: the backend shipped the liveness route as recommended, so the guidance is settled rather than speculative. Named the accepted trade-off explicitly (backend up + database down → still 200 → `healthy` with no banner) and pointed the remedy at the future `degraded` 200-body state rather than readiness/503.
- Corrected CLAUDE.md dual-tier pseudocode (`hasInternetAccess`, not the original package's `hasConnection`); clarified that `initial` is never emitted on the stream; README install now leads with path/git (package is not published).
- Added a README recipe for a connect-phase timeout injected through the existing `httpClient` parameter, for the network-black-hole case where a probe burns the full 8 s `requestTimeout` before the tiebreaker starts. It stays documentation rather than package code because `HttpClient` lives in `dart:io`, removed above to keep the package Web/WASM-capable. Names all four caveats: it layers under `requestTimeout` rather than replacing it, DNS resolves before the timeout is installed, a pooled warm socket skips the connect phase entirely, and the consumer owns an injected client's lifetime.
- Corrected CLAUDE.md §6, which still claimed `checkNow()` "DOES update `currentState`" — untrue since the change recorded above.

### Tests
- Added: timeout + internet-down → `internetDisconnected`, dispose-during-in-flight-probe, `checkNow()` before `start()`, late-subscriber de-dupe after a state-changing `checkNow()`, `jitterRatio` assert, and injected-checker-not-disposed.
- Added three guards for the `weakNetwork` gate fix, each pinned by a mutation check: alternating failures escalate out of `weakNetwork` (fails without the exemption); one failure after a `weakNetwork` confirmed by the same-state rule is still a blip (fails without the counter reset); the same after a `weakNetwork` confirmed by the generic-failure rule (fails if the reset guards only one of the two confirming paths). The third exists because `weakNetwork` reaches confirmation through both rules and only one route had coverage — a fix applied to the wrong one passes every other test in the suite. Suite: 22 → 47.

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
