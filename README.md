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
final monitor = ConnectionHealthMonitor(
  baseUrl: 'https://neo-backend-v2.dev-api.neosapien.xyz',
  healthPath: '/healthz',
);
monitor.start();

monitor.stream.listen((state) {
  switch (state) {
    case ConnectionHealthState.healthy:             /* hide banner */
    case ConnectionHealthState.weakNetwork:         /* "Weak Network" */
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

## Endpoint configuration (Neosapien)

`healthPath` defaults to `/health` — the conventional default for a reusable package. **The Neosapien backend serves `/healthz`**, so the consumer app must pass `healthPath: '/healthz'`. There is no `/health` route on any environment; leaving the default in place yields a permanent `serverUnreachable`.

Hosts follow `neo-backend-v2.<env->api.neosapien.xyz`:

| Env | `baseUrl` | Status (probed 2026-07-16) |
|---|---|---|
| dev | `https://neo-backend-v2.dev-api.neosapien.xyz` | Live — `200 {"status":"ok"}` |
| prod | `https://neo-backend-v2.api.neosapien.xyz` | Route not deployed yet |

`https://api.neosapien.xyz` is the bare gateway, **not** neo-backend-v2 — it 404s on `/healthz`. Don't point the monitor at it.

The endpoint is a **liveness** check: it returns a static `{"status": "ok"}` and touches no datastore. That is deliberate ([why](docs/solutions/architecture-patterns/health-endpoint-liveness-vs-readiness.md)), and it means `healthy` proves the backend is *reachable*, not that every dependency behind it is well.

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
final monitor = ConnectionHealthMonitor(baseUrl: '…', healthPath: '…');
final watcher = _AppLifecycleWatcher(monitor);
WidgetsBinding.instance.addObserver(watcher);
monitor.start();
```

## States

| State | Meaning | Recommended UI affordance |
|---|---|---|
| `initial` | First check has not completed yet. | Show nothing (loading). |
| `healthy` | The configured health endpoint returned 2xx within `slowThreshold`. | Hide banner. |
| `weakNetwork` | The health endpoint returned 2xx but took longer than `slowThreshold` (default 3 s). | "Weak network — sync will resume when the connection improves". |
| `internetDisconnected` | Server unreachable AND the generic internet probe also failed. | "Check your WiFi / mobile data". |
| `serverUnreachable` | Server failed but the generic internet probe succeeded. | "Our servers are temporarily unreachable". |

The five states are intentional. UI needs to distinguish "fix your WiFi" (user can act) from "our servers are down" (user is stuck waiting) — do not collapse them.

`weakNetwork` is a latency verdict on a single request, not a bandwidth measurement: one slow probe on an otherwise healthy network reports it. That is deliberate — the banner it drives is advisory, so a false positive costs nothing, while a missed slow network leaves the user staring at a stalled upload with no explanation. It polls at `retryInterval`, not `healthyInterval`, so recovery is noticed quickly.

## API

| Symbol | Summary |
|---|---|
| `stream` | Broadcast `Stream<ConnectionHealthState>`. De-duplicated; emits only on real state changes. Degraded states are gated by `downConfirmationCount` — see below. |
| `currentState` | Synchronous read of the last observed state. Returns `initial` before the first check completes — see warning below. |
| `start()` | Begins (or resumes) the polling loop. The first check fires immediately. Idempotent. |
| `stop()` | Pause. Cancels the pending timer and clears the running flag; leaves the stream controller open so a later `start()` resumes cleanly. |
| `dispose()` | Terminal cleanup. Cancels the timer, closes the broadcast controller, and closes the owned `http.Client` (an injected client is never closed). Any subsequent call throws `StateError`. |
| `checkNow()` | One-off probe. Returns the observed state. **Does NOT emit on the stream.** Resets the schedule so the next polling delay is measured from the probe's completion. |

Notes:

- **`stop()` vs `dispose()` — pause vs terminal.** `stop()` is the recommended call when the app is backgrounded (`AppLifecycleState.paused` / `detached` / `hidden` — NOT `inactive`, a transient iOS foreground state); the monitor can be resumed with `start()`. `dispose()` is the call at app shutdown; the monitor cannot be reused afterwards.
- **`checkNow()` does NOT emit on the stream.** It is a pure probe — use the returned `Future<ConnectionHealthState>` to drive a button spinner or toast locally. Consumers that expect a stream emission will get silent breakage; subscribe to `stream` for emissions, await `checkNow()` for the return value.
- **`currentState` returns `initial` before the first check.** Do not render UI from a synchronous read of `currentState` immediately after construction — subscribe to `stream` and react to the first emitted event instead.
- **`checkNow()` does not participate in `downConfirmationCount`.** It is a pure probe and reports what it saw, unconfirmed. The confirmation streak is only advanced by the scheduled polling loop.

### Avoiding false alarms — `downConfirmationCount`

By default the monitor reports a degraded state on the **first** probe that observes it. A single blip — a lift, a tunnel, one overloaded response — is enough to put an error state in front of the user.

Pass `downConfirmationCount: 2` (or more) to require that many **consecutive, identical** degraded observations before the state is emitted:

```dart
ConnectionHealthMonitor(
  baseUrl: '…',
  healthPath: '/healthz',
  downConfirmationCount: 2, // one blip no longer alarms
);
```

Three properties worth knowing:

- **Recovery is never delayed.** `healthy` is emitted on the first healthy probe and clears the streak. The asymmetry is deliberate — and note it is the *inverse* of the circuit-breaker convention (fast-fail, slow-recover), because a breaker exists to shield a fragile downstream from a retry storm, which is not what a single polling client is doing.
- **The streak is keyed on the specific state, not on "something was wrong."** `internetDisconnected` followed by `serverUnreachable` confirms neither and restarts the count. Two different failures are not yet a consistent story, and a generic counter would announce a state it had only observed once.
- **Confirmation arrives on the fast cadence.** An unconfirmed degraded probe still reschedules at `retryInterval`, not `healthyInterval`, so the follow-up check is a minute away rather than five.

The default of `1` is exactly the historical behaviour, so existing consumers are unaffected until they opt in.

## Why a pure-Dart package?

The package intentionally avoids a Flutter dependency so it is reusable in CLI tools, server-side Dart services, and any future non-Flutter context. The trade-off is that the package cannot observe `AppLifecycleState` itself — the consumer must wire `WidgetsBindingObserver` and call `stop()` / `start()` on background / foreground transitions (see "Caller responsibility — backgrounding" above). This is a deliberate design choice, not an oversight; the pure-Dart constraint is load-bearing.

## Development

Run the full local quality gate (format check, analyzer, tests) before committing:

```bash
bash tool/check.sh
```

The same script powers the GitHub Actions workflow on every PR and push to `master`, so passing it locally is the cheapest way to keep CI green.
