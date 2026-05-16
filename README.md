# neo_connection_health_monitor

Lightweight pure-Dart package that monitors **device internet connectivity** AND **your application server's reachability**, exposing the combined state as a real-time `Stream`.

Stop showing a generic "No internet" banner when your servers are actually down. This package tells you *which* side broke.

```
┌─────┐  baseUrl + /health   ┌─────────┐   5 min healthy / 1 min retry   ┌──────────────┐
│ App │ ───────────────────▶ │ Package │ ─────────────────────────────▶  │ Server /health│
└─────┘                       └─────────┘                                 └──────────────┘
                                  │
                                  └── Stream<ConnectionHealthState> ──▶ UI (StreamBuilder)
```

---

## Features

- **Dual-tier health check** — distinguishes "no internet" from "your server is down".
- **Adaptive polling** — checks every 5 min when healthy, switches to 1 min retry on failure.
- **Reactive stream API** — one broadcast `Stream` powers any number of widgets.
- **Pure Dart** — no Flutter dependency. Works in CLI, server, and Flutter apps.
- **Testable** — inject your own `http.Client` and connection checker for unit tests.
- **Lightweight** — only two runtime deps: `http` + `internet_connection_checker_plus`.

## Connection states

| State | Meaning | Typical UI |
|---|---|---|
| `initial` | First check has not completed yet. | Show nothing / splash. |
| `healthy` | Internet works AND server `/health` returned 2xx. | Hide banner. |
| `internetDisconnected` | Device has no internet at all. | "Check your WiFi / data". |
| `serverUnreachable` | Internet works, but your server is down or timing out. | "We're having trouble reaching our servers". |

## Install

```yaml
dependencies:
  neo_connection_health_monitor: ^1.0.0
```

Then:

```bash
dart pub get
```

## Quick start

### 1. Construct once at app startup

This package is designed as a **singleton** — one instance per app, started in `main()` before `runApp()`, so the heartbeat runs continuously in the background.

Recommended DI: [`get_it`](https://pub.dev/packages/get_it).

```dart
// lib/di/service_locator.dart
import 'package:get_it/get_it.dart';
import 'package:neo_connection_health_monitor/neo_connection_health_monitor.dart';

final getIt = GetIt.instance;

void setupLocator() {
  getIt.registerSingleton<ConnectionHealthMonitor>(
    ConnectionHealthMonitor(baseUrl: AppConfig.apiBaseUrl)..start(),
  );
}
```

```dart
// lib/main.dart
void main() {
  setupLocator();
  runApp(const MyApp());
}
```

### 2. Listen anywhere in the widget tree

```dart
import 'package:flutter/material.dart';
import 'package:neo_connection_health_monitor/neo_connection_health_monitor.dart';

class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final monitor = getIt<ConnectionHealthMonitor>();

    return StreamBuilder<ConnectionHealthState>(
      stream: monitor.stream,
      initialData: monitor.currentState,
      builder: (context, snapshot) {
        return switch (snapshot.data!) {
          ConnectionHealthState.healthy ||
          ConnectionHealthState.initial => const SizedBox.shrink(),
          ConnectionHealthState.internetDisconnected =>
            const _Banner(text: 'Check your internet connection'),
          ConnectionHealthState.serverUnreachable =>
            const _Banner(text: 'We\'re having trouble reaching our servers'),
        };
      },
    );
  }
}
```

### 3. Manual refresh (pull-to-refresh / retry button)

```dart
ElevatedButton(
  onPressed: () => getIt<ConnectionHealthMonitor>().checkNow(),
  child: const Text('Retry'),
);
```

### 4. Clean up on shutdown

```dart
await getIt<ConnectionHealthMonitor>().stop();
```

## API

```dart
ConnectionHealthMonitor({
  required String baseUrl,                     // your API base, e.g. https://api.example.com
  String healthPath = '/health',               // appended to baseUrl
  Duration healthyInterval = const Duration(minutes: 5),
  Duration retryInterval   = const Duration(minutes: 1),
  Duration requestTimeout  = const Duration(seconds: 5),
  http.Client? httpClient,                     // inject for tests
  InternetConnection? internetChecker,         // inject for tests
});

Stream<ConnectionHealthState> get stream;      // broadcast — multi-listener safe
ConnectionHealthState         get currentState;// last emitted value

void start();                                  // idempotent
Future<void> stop();                           // cancels loop + closes stream
Future<ConnectionHealthState> checkNow();      // forces immediate check
```

## How the check works

The package runs an adaptive loop. Each tick performs two checks **in order**:

1. **Internet check** (`internet_connection_checker_plus`) — verifies the device can actually reach the open internet, not just a captive WiFi portal.
   - Fails → emit `internetDisconnected`, schedule next check in **1 min**.
2. **Server check** — sends a `GET` to `{baseUrl}{healthPath}` with a 5s timeout.
   - 2xx → emit `healthy`, schedule next check in **5 min**.
   - Non-2xx / timeout / network error → emit `serverUnreachable`, schedule next check in **1 min**.

Duplicate consecutive states are de-duped — the stream only emits on real transitions.

The loop uses recursive `Future.delayed` (not `Timer.periodic`) so checks cannot overlap if a request hangs near the timeout.

## Server requirements

Your backend must expose the health endpoint (default `/health`). It should:

- Return **200 OK** when the service is healthy.
- Be **cheap** — no DB queries, no auth. Just `200`.
- Be **fast** — respond within the request timeout (5s default).

Example (Express):

```js
app.get('/health', (_, res) => res.sendStatus(200));
```

Override the path if your server uses a different route:

```dart
ConnectionHealthMonitor(
  baseUrl: 'https://api.example.com',
  healthPath: '/api/v1/ping',
);
```

## Testing

Inject fakes so tests never hit the network:

```dart
final monitor = ConnectionHealthMonitor(
  baseUrl: 'https://fake.test',
  httpClient: MockClient((req) async => http.Response('', 200)),
  internetChecker: FakeInternetConnection(hasConnection: true),
);
```

Use `package:fake_async` for deterministic time control of the polling loop.

## Why this exists

Most "connectivity" packages only tell you whether the device has a WiFi/cellular interface up — which lies to you constantly (captive portals, your servers being down, DNS failures). This package answers the only question your UI actually cares about: **can the user use my app right now, and if not, whose fault is it?**

## License

BSD-3-Clause (or whatever the project decides at publish time — update before pushing to pub.dev).
