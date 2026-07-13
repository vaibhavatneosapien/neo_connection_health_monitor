# neo_connection_health

Pure-Dart package that monitors device internet connectivity AND a specific server's reachability, exposing real-time state via a broadcast `Stream`. It distinguishes "the user has no internet" from "our backend is down" so the consumer app can show the correct UI affordance for each.

The package performs a server-first dual-tier check on an adaptive schedule (5 minutes between checks while healthy, 1 minute while unhealthy, both with ±10% jitter to avoid synchronized thundering-herd load) and emits state transitions on a de-duplicated broadcast `Stream<ConnectionHealthState>`.

## Install

The package is not published on pub.dev and is not intended to be. Depend on
it via a path or git dependency in your `pubspec.yaml`.

```yaml
dependencies:
  neo_connection_health:
    path: ../neo_connection_health
```

```yaml
dependencies:
  neo_connection_health:
    git:
      url: https://github.com/neosapien/neo_connection_health.git
      ref: master
```

## Quick start

```dart
final monitor = ConnectionHealthMonitor(baseUrl: 'https://api.neosapien.xyz');
monitor.start();

monitor.stream.listen((state) {
  switch (state) {
    case ConnectionHealthState.healthy:             /* hide banner */
    case ConnectionHealthState.internetDisconnected:/* "Check your WiFi" */
    case ConnectionHealthState.serverUnreachable:   /* "Our servers are down" */
    case ConnectionHealthState.initial:             /* show nothing yet */
  }
});

// On retry button (pure probe — does NOT emit on stream):
final state = await monitor.checkNow();

// On app background / foreground (caller's responsibility — see below):
monitor.stop();   // on background (paused/detached/hidden) — can resume
monitor.start();  // on resume

// On app shutdown:
await monitor.dispose();
```

## Caller responsibility — backgrounding (REQUIRED)

> The caller MUST call `monitor.stop()` when the app is backgrounded (`AppLifecycleState.paused` / `detached` / `hidden`) and `monitor.start()` on resume. The package will not do this for you; doing so would force a Flutter dependency. **Do not stop on `inactive`** — see the snippet note below.

**Why this matters.** In the unhealthy state the monitor polls every 1 minute. If the consumer leaves the monitor running while the app is backgrounded, that is 60 HTTP attempts + 60 radio wakeups per backgrounded hour — visible battery drain, avoidable cellular traffic, and the kind of behaviour that surfaces in App Store and Play Store battery / energy reviews. Observing app lifecycle is intentionally the caller's job because doing it inside the package would force a Flutter dependency and defeat the pure-Dart goal (this package needs to remain reusable in CLI tools, server-side Dart, and other non-Flutter contexts).

## Lifecycle snippet — `WidgetsBindingObserver`

Copy-paste-ready Flutter integration. Wire this once at app startup and you are done.

```dart
class _AppLifecycleWatcher with WidgetsBindingObserver {
  final ConnectionHealthMonitor monitor;
  _AppLifecycleWatcher(this.monitor);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        monitor.start();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        monitor.stop();
        break;
      case AppLifecycleState.inactive:
        // Do NOT stop here. On iOS `inactive` fires during transient
        // foreground interruptions (control center, app switcher, Face ID
        // / permission dialogs); stopping+resuming on each would issue a
        // fresh immediate probe every time — request thrash, not savings.
        break;
    }
  }
}

// In main() / top-level widget initState:
final monitor = ConnectionHealthMonitor(baseUrl: '…');
final watcher = _AppLifecycleWatcher(monitor);
WidgetsBinding.instance.addObserver(watcher);
monitor.start();
```

## States

| State | Meaning | Recommended UI affordance |
|---|---|---|
| `initial` | First check has not completed yet. | Show nothing (loading). |
| `healthy` | Server `/health` returned 2xx. | Hide banner. |
| `internetDisconnected` | Server unreachable AND the generic internet probe also failed. | "Check your WiFi / mobile data". |
| `serverUnreachable` | Server failed but the generic internet probe succeeded. | "Our servers are temporarily unreachable". |

The four states are intentional. UI needs to distinguish "fix your WiFi" (user can act) from "our servers are down" (user is stuck waiting) — do not collapse them.

## API

| Symbol | Summary |
|---|---|
| `stream` | Broadcast `Stream<ConnectionHealthState>`. De-duplicated; emits only on real state changes. |
| `currentState` | Synchronous read of the last observed state. Returns `initial` before the first check completes — see warning below. |
| `start()` | Begins (or resumes) the polling loop. The first check fires immediately. Idempotent. |
| `stop()` | Pause. Cancels the pending timer and clears the running flag; leaves the stream controller open so a later `start()` resumes cleanly. |
| `dispose()` | Terminal cleanup. Cancels the timer, closes the broadcast controller, and closes the owned `http.Client` (an injected client is never closed). Any subsequent call throws `StateError`. |
| `checkNow()` | One-off probe. Returns the observed state. **Does NOT emit on the stream.** Resets the schedule so the next polling delay is measured from the probe's completion. |

Notes:

- **`stop()` vs `dispose()` — pause vs terminal.** `stop()` is the recommended call when the app is backgrounded (`AppLifecycleState.paused` / `detached` / `hidden` — NOT `inactive`, a transient iOS foreground state); the monitor can be resumed with `start()`. `dispose()` is the call at app shutdown; the monitor cannot be reused afterwards.
- **`checkNow()` does NOT emit on the stream.** It is a pure probe — use the returned `Future<ConnectionHealthState>` to drive a button spinner or toast locally. Consumers that expect a stream emission will get silent breakage; subscribe to `stream` for emissions, await `checkNow()` for the return value.
- **`currentState` returns `initial` before the first check.** Do not render UI from a synchronous read of `currentState` immediately after construction — subscribe to `stream` and react to the first emitted event instead.

## Why a pure-Dart package?

The package intentionally avoids a Flutter dependency so it is reusable in CLI tools, server-side Dart services, and any future non-Flutter context. The trade-off is that the package cannot observe `AppLifecycleState` itself — the consumer must wire `WidgetsBindingObserver` and call `stop()` / `start()` on background / foreground transitions (see "Caller responsibility — backgrounding" above). This is a deliberate design choice, not an oversight; the pure-Dart constraint is load-bearing.

## Development

Run the full local quality gate (format check, analyzer, tests) before committing:

```bash
bash tool/check.sh
```

The same script powers the GitHub Actions workflow on every PR and push to `master`, so passing it locally is the cheapest way to keep CI green.
