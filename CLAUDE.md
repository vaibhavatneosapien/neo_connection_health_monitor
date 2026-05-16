# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

**`neo_connection_health_monitor`** — pure Dart package that monitors device internet connectivity AND a specific server's reachability, exposing real-time state via a `Stream`.

Consumer is a Flutter app (Neosapien). The app passes its API base URL (e.g. `https://api.neosapien.xyz`) into the package; the package pings a `/health` route on that base URL on an adaptive schedule and streams state transitions back to the UI.

```
App ──(baseUrl + /health)──▶ Package ──(5 min healthy / 1 min retry)──▶ Server /health
                                │
                                └──(Stream<ConnectionHealthState>)──▶ UI (StreamBuilder)
```

## Tech

- Pure Dart package (no Flutter dep) — keeps it lightweight and reusable.
- SDK: `^3.11.1` (see `pubspec.yaml`).
- Lints: `lints: ^6.0.0`.

### Dependencies to add

| Package | Why | Notes |
|---|---|---|
| `http` | Lightweight server health request (`GET`/`HEAD` to `/health`). | Use `http.Client` so it can be injected for tests. |
| `internet_connection_checker_plus` | HTTP-level check that device actually has internet (not just WiFi attached to captive portal). | **Required** over the original `internet_connection_checker` — the original pulls `flutter` + `connectivity_plus` as deps, which breaks the pure-Dart goal. `_plus` depends only on `http`. Pin `^3.0.0` and read the v3 migration guide before bumping. Override the default endpoint list (`one.one.one.one`, `captive.apple.com`, `icanhazip.com`, `ajax.googleapis.com`) if corp firewalls block any of them. |

Optional:
- `rxdart` — only if `BehaviorSubject` semantics are wanted (new listeners immediately receive the last state). Otherwise stick with `StreamController.broadcast()` + a cached "last value".

Do **not** add Flutter as a dependency. State-replay for late subscribers should be solved in Dart, not by depending on Flutter.

## Architecture

### 1. `ConnectionHealthState` enum (`lib/src/connection_health_state.dart`)

```dart
enum ConnectionHealthState {
  initial,              // before first check completes
  healthy,              // internet OK AND server /health returned 2xx
  internetDisconnected, // device has no internet at all
  serverUnreachable,    // internet OK but baseUrl/health failed or timed out
}
```

Four states are intentional — UI needs to distinguish "check your WiFi" from "our servers are down". Do not collapse them.

### 2. `ConnectionHealthMonitor` service (`lib/src/connection_health_monitor.dart`)

Public API surface (keep small and stable):

```dart
class ConnectionHealthMonitor {
  ConnectionHealthMonitor({
    required String baseUrl,
    String healthPath = '/health',
    Duration healthyInterval = const Duration(minutes: 5),
    Duration retryInterval = const Duration(minutes: 1),
    Duration requestTimeout = const Duration(seconds: 5),
    http.Client? httpClient,                 // inject for tests
    InternetConnection? internetChecker, // inject for tests
  });

  Stream<ConnectionHealthState> get stream;  // broadcast
  ConnectionHealthState get currentState;    // last known

  void start();         // idempotent — no-op if already running
  Future<void> stop();  // cancels loop, closes stream
  Future<ConnectionHealthState> checkNow(); // manual trigger, also feeds the stream
}
```

### 3. Adaptive recursive loop (NOT a `Timer.periodic`)

`Timer.periodic` can overlap if a check takes longer than the interval. Use a recursive `Future.delayed` pattern:

```
loop():
  state = await _runCheck()
  _emit(state)
  delay = state == healthy ? healthyInterval : retryInterval
  _pendingTimer = Timer(delay, loop)   // store handle so stop() can cancel
```

Guard with a `_disposed` / `_running` flag so `stop()` truly halts the chain and `start()` is idempotent.

### 4. Dual-tier check — order matters

```
_runCheck():
  if (!await internetChecker.hasConnection) return internetDisconnected
  try:
    res = await httpClient.get(Uri.parse('$baseUrl$healthPath'))
          .timeout(requestTimeout)
    return (res.statusCode >= 200 && res.statusCode < 300)
        ? healthy
        : serverUnreachable
  on TimeoutException / SocketException / http errors:
    return serverUnreachable
```

Rules:
- Internet check first. If offline, skip the HTTP request entirely (saves battery, avoids misleading server-down state).
- Treat any non-2xx, timeout, or thrown exception from the HTTP call as `serverUnreachable`.
- Do not retry inside `_runCheck()` — the loop already retries on a 1-minute cadence.

### 5. Stream behavior

- Use `StreamController<ConnectionHealthState>.broadcast()` so multiple widgets can subscribe.
- Cache `currentState` and emit it to late subscribers via a wrapper (or use `rxdart.BehaviorSubject` if added).
- **De-dupe**: only emit when the state actually changes. Repeated `healthy → healthy` emissions cause needless UI rebuilds.

### 6. Lifecycle

- `start()` — kicks off the first check immediately (don't wait 5 min for the first signal), then schedules the next.
- `stop()` — must cancel the pending `Timer`, close the `StreamController`, and dispose the injected `http.Client` only if the package created it (not if caller injected one).
- App should construct one instance at startup (DI via `GetIt` / `Provider` on the consumer side) and call `stop()` on app shutdown.

## File layout (target)

```
lib/
  neo_connection_health_monitor.dart      # barrel: exports public API only
  src/
    connection_health_state.dart          # enum
    connection_health_monitor.dart        # service
example/
  neo_connection_health_monitor_example.dart  # minimal usage demo
test/
  connection_health_monitor_test.dart     # unit tests with injected fakes
```

Rename existing `lib/src/neo_connection_health_monitor_base.dart` once real files exist — don't keep the placeholder.

## Testing

- Inject `http.Client` and `InternetConnection` so tests never hit the network.
- Use `package:test` (already in `dev_dependencies`) + `http.MockClient` for HTTP fakes.
- Required cases:
  - Internet down → emits `internetDisconnected`, schedules retry in 1 min.
  - Internet up, server 500 → `serverUnreachable`.
  - Internet up, server timeout → `serverUnreachable`.
  - Internet up, server 200 → `healthy`, next check scheduled at 5 min.
  - Transition healthy → unhealthy → healthy emits exactly 3 events (de-dupe works).
  - `stop()` cancels pending timer (use `fake_async` to verify no further emissions).
  - `checkNow()` forces an immediate check without waiting for the timer and resets the schedule.

Use `package:fake_async` for deterministic time-based tests instead of real `Future.delayed`.

## Conventions

- Public API lives in `lib/neo_connection_health_monitor.dart` (barrel). Everything in `lib/src/**` is implementation; do not re-export internal classes unless intentional.
- Document every public symbol with `///` dartdoc — `dart doc` should produce clean output.
- Run before committing: `dart format .` && `dart analyze` && `dart test`.
- Keep `CHANGELOG.md` updated per pub.dev conventions (semver, dated sections).

## Out of scope (do not add without asking)

- Native platform channels — defeats "pure Dart" goal.
- Persistent storage of state across app restarts.
- Multiple base URLs / multi-endpoint health aggregation.
- Exponential backoff — spec is a flat 1-min retry; don't second-guess it.
- Logging frameworks — leave logging to the consumer app.

## Quick reference — expected consumer usage

```dart
final monitor = ConnectionHealthMonitor(baseUrl: 'https://api.neosapien.xyz');
monitor.start();

monitor.stream.listen((state) {
  switch (state) {
    case ConnectionHealthState.healthy: /* hide banner */
    case ConnectionHealthState.internetDisconnected: /* "Check your WiFi" */
    case ConnectionHealthState.serverUnreachable:   /* "Our servers are down" */
    case ConnectionHealthState.initial:             /* show nothing yet */
  }
});

// On retry button:
await monitor.checkNow();

// On app shutdown:
await monitor.stop();
```
