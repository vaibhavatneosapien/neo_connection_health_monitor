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
    case ConnectionHealthState.serverUnreachable:   /* "Server down" */
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

| Env | `baseUrl` | Status (probed 2026-07-30) |
|---|---|---|
| dev | `https://neo-backend-v2.dev-api.neosapien.xyz` | Live — `200 {"status":"ok"}` |
| prod | `https://neo-backend-v2.api.neosapien.xyz` | Live — `200 {"status":"ok"}` |

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

`weakNetwork` is a latency verdict on a single request, not a bandwidth measurement: at the default `downConfirmationCount: 1`, one slow probe on an otherwise healthy network reports it. That is deliberate — the banner it drives is advisory, so a false positive costs nothing, while a missed slow network leaves the user staring at a stalled upload with no explanation.

It polls at `healthyInterval`, **not** `retryInterval`. The probe succeeded — the server replied and the connection works — so there is no outage to recover from, and re-checking a slow link five times as often would sustain roughly 1440 requests a day, plus a radio wakeup each, on exactly the connections least able to spare either.

## API

| Symbol | Summary |
|---|---|
| `stream` | Broadcast `Stream<ConnectionHealthState>`. De-duplicated; emits only on real state changes. Degraded states are gated by `downConfirmationCount` — see below. |
| `currentState` | Synchronous read of the last state **emitted on `stream`**. Never a raw probe result — an unconfirmed observation and a `checkNow()` result both leave it untouched. Returns `initial` before the first emission — see warning below. |
| `start()` | Begins (or resumes) the polling loop. The first check fires immediately. Idempotent. |
| `stop()` | Pause. Cancels the pending timer and clears the running flag; leaves the stream controller open so a later `start()` resumes cleanly. |
| `dispose()` | Terminal cleanup. Cancels the timer, closes the broadcast controller, and closes the owned `http.Client` (an injected client is never closed). Any subsequent call throws `StateError`. |
| `checkNow()` | One-off probe. Returns the observed state. **Does NOT emit on the stream and does NOT move `currentState`** — the returned `Future` is the only delivery path. Resets the schedule so the next polling delay is measured from the probe's completion. |

Notes:

- **`stop()` vs `dispose()` — pause vs terminal.** `stop()` is the recommended call when the app is backgrounded (`AppLifecycleState.paused` / `detached` / `hidden` — NOT `inactive`, a transient iOS foreground state); the monitor can be resumed with `start()`. `dispose()` is the call at app shutdown; the monitor cannot be reused afterwards.
- **`checkNow()` does NOT emit on the stream.** It is a pure probe — use the returned `Future<ConnectionHealthState>` to drive a button spinner or toast locally. Consumers that expect a stream emission will get silent breakage; subscribe to `stream` for emissions, await `checkNow()` for the return value.
- **`currentState` returns `initial` before the first check.** Do not render UI from a synchronous read of `currentState` immediately after construction — subscribe to `stream` and react to the first emitted event instead.
- **`checkNow()` does not participate in `downConfirmationCount`, and does not move `currentState` either.** It reports what it saw, unconfirmed, to its caller alone. The confirmation streak is only advanced by the scheduled polling loop, and `currentState` only ever reports what a subscriber has been told — so the two can never disagree. The practical consequence: a retry that succeeds does not itself clear a banner driven by `stream`. Act on the returned value, or wait for the next scheduled tick.

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
- **Two rules decide when a degraded state is reported.** *Rule 1* — the same state observed N times in a row. *Rule 2* — N consecutive failures of **any** kind, but only while nothing degraded is on screen yet.

  Rule 1 alone has a hole worth understanding: a connection alternating between `internetDisconnected` and `serverUnreachable` never builds a matching run, so the monitor would report **nothing, ever** — the app looks perfectly healthy while every request fails, and it never self-corrects. Rule 2 closes it. Once a degraded state *is* being reported, rule 2 switches off and rule 1 governs the label, so an established banner cannot swap its advice ("check your WiFi" / "our servers are down") on every alternating probe. A different failure takes over the banner only by earning its own run of N.

  **`weakNetwork` does not count as "on screen" for rule 2.** It is a *successful* probe, so it belongs with `healthy` despite sitting among the failure values. Counting it re-opened the same never-confirms trap from the other side: reach `weakNetwork` on a slow link, then degrade into alternating failure modes, and neither rule can fire — leaving a reassuring "your connection will improve" banner up while the device is fully offline. Escalating *out* of `weakNetwork` is therefore allowed generically.

  Blip protection is unaffected: a single failure never passes either rule. That holds on the way out of `weakNetwork` too, because confirming `weakNetwork` also clears the generic failure run — otherwise the counter would already be at threshold the moment the banner appeared, and the exemption above would let the next single failure through on one observation.

  This follows existing practice rather than inventing a rule — Kubernetes `failureThreshold`, gRPC's connectivity state machine and Resilience4j all count failure as a **generic** condition rather than matching a specific sub-type, which is precisely what avoids the never-confirms trap. Per-state matching is kept only where it earns its keep: choosing which label to show, and holding it steady once shown.
- **Confirmation of a FAILURE arrives on the fast cadence.** An unconfirmed `internetDisconnected` / `serverUnreachable` probe reschedules at `retryInterval`, so the follow-up check is a minute away rather than five. `weakNetwork` is the exception: the probe succeeded, so it reschedules at `healthyInterval` like any other success, and confirming a slow link therefore takes one `healthyInterval` rather than one `retryInterval`. That is the intended trade — a slow-but-working connection is not worth 5x the request volume to pin down faster.

The default of `1` is exactly the historical behaviour, so existing consumers are unaffected until they opt in.

## Failing faster in a network black hole (optional)

> In a black hole — radio registered, packets vanishing — the probe burns the full `requestTimeout` (8 s) before the internet tiebreaker even starts, so the worst case from tick to emitted state is roughly 11 seconds.

A **connect-phase** timeout cuts that without touching `requestTimeout`. Connect time is round-trip-bound and sub-second even on tier-2 3G; the 8 seconds exists to protect *transfer* time, which is bandwidth-bound. The package cannot ship this itself — `HttpClient` lives in `dart:io`, which the package deliberately does not import so it stays Web/WASM-capable. Inject it instead:

```dart
import 'dart:io';
import 'package:http/io_client.dart';

// The app owns this client — see the last bullet below.
final httpClient = IOClient(
  HttpClient()..connectionTimeout = const Duration(seconds: 4),
);

final monitor = ConnectionHealthMonitor(
  baseUrl: 'https://neo-backend-v2.dev-api.neosapien.xyz',
  healthPath: '/healthz',
  httpClient: httpClient,
);
```

Four things to know before relying on it:

- **It layers under `requestTimeout`, it does not replace it.** Connect has 4 s; the whole request still has 8 s. A server that connects instantly and then stalls is caught by the outer deadline, unchanged.
- **DNS is not covered.** Name resolution happens *before* `connectionTimeout` is installed, so a black-holed resolver is still caught only by the outer 8 s.
- **A warm socket skips the connect phase entirely.** The monitor drains each response body specifically so the pooled connection stays reusable, so a probe that reuses one never enters the connect phase and this timeout never fires for it. It protects the cold-connection case.
- **You own the client's lifetime.** The monitor closes only a client it created itself; an injected one is never closed by `dispose()`. Close it yourself at app shutdown.

## Why a pure-Dart package?

The package intentionally avoids a Flutter dependency so it is reusable in CLI tools, server-side Dart services, and any future non-Flutter context. The trade-off is that the package cannot observe `AppLifecycleState` itself — the consumer must wire `WidgetsBindingObserver` and call `stop()` / `start()` on background / foreground transitions (see "Caller responsibility — backgrounding" above). This is a deliberate design choice, not an oversight; the pure-Dart constraint is load-bearing.

## Development

Run the full local quality gate (format check, analyzer, tests) before committing:

```bash
bash tool/check.sh
```

The same script powers the GitHub Actions workflow on every PR and push to `master`, so passing it locally is the cheapest way to keep CI green.
