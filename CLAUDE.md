# CLAUDE.md

Guidance for Claude Code when working in this repository.

**Plan status:** Approved with required changes by senior mobile review. Architectural foundation sound; correctness, lifecycle, and operational issues called out below were folded into this document. Three High-severity blockers (§4 inverted check, §7 split lifecycle, §8 caller responsibilities) MUST be honored before first implementation PR merges. Medium-severity items (§3 jitter, §6 `checkNow` semantics, §2 URL normalization + redirects + GET, §7 in-flight handling) MAY be follow-up PRs only under schedule pressure, and only if filed as tickets before the first release — not discovered in production.

## Project

**`neo_connection_health`** — pure Dart package that monitors device internet connectivity AND a specific server's reachability, exposing real-time state via a `Stream`.

Consumer is a Flutter app (Neosapien). The app passes its API base URL (e.g. `https://neo-backend-v2.dev-api.neosapien.xyz`) into the package; the package pings the health route on that base URL on an adaptive schedule and streams state transitions back to the UI.

```
App ──(baseUrl + /healthz)──▶ Package ──(5 min healthy / 1 min retry, ±10% jitter)──▶ Server /healthz
                                 │
                                 └──(Stream<ConnectionHealthState>)──▶ UI (StreamBuilder)
```

### Backend endpoint — verified live 2026-07-16

The real Neosapien route is **`/healthz`**, not the package default `/health`. `neo-backend-v2/main.py:245`:

```python
@app.get("/healthz", include_in_schema=False)
async def healthz():
    return {"status": "ok"}
```

Consumers MUST pass `healthPath: '/healthz'`. The package default stays `/health` — it is the conventional generic default for a reusable package, and the override is one line at the construction site. **Do not "fix" this by changing the default** unless Neosapien is confirmed the only consumer forever.

Hosts follow `neo-backend-v2.<env->api.neosapien.xyz`:

| Env | Base URL | `/healthz` (re-probed 2026-07-30) |
|---|---|---|
| dev | `https://neo-backend-v2.dev-api.neosapien.xyz` | **200** `{"status":"ok"}` |
| prod | `https://neo-backend-v2.api.neosapien.xyz` | **200** `{"status":"ok"}` — live since somewhere between 2026-07-16 and 2026-07-30 |

`https://api.neosapien.xyz` is the **bare gateway host, not neo-backend-v2** (`neo-backend-v2/auth/principal_resolver.py:17`). It answers `200` on `/` but `404` on `/healthz`. Earlier revisions of this document used it as the example base URL; that was wrong. Do not reintroduce it.

**Prod is live now.** It was not on 2026-07-16 — commit `2ae0314a feat: add /healthz endpoint` sat on `origin/dev` only, and `neo-backend-v2/.github/workflows/deploy.yaml:67-69` maps `main`→prod, `stg`→stg, `dev`→dev, so the route needed promoting `dev` → `stg` → `main`. That promotion has happened: `GET https://neo-backend-v2.api.neosapien.xyz/healthz` returns `200 {"status":"ok"}` as of 2026-07-30. A prod-configured monitor no longer reports a permanent `serverUnreachable`.

**What the live routes confirm** (both envs re-probed 2026-07-30):

- **`HEAD /healthz` → `405` on dev AND prod.** Direct live proof of the §Tech `GET`-not-`HEAD` mandate: the route is declared `@app.get`, so a `HEAD` probe would report `serverUnreachable` against a perfectly healthy server. This is no longer a hypothetical, and promoting to prod did not change it.
- **No redirects, 0 hops** on the happy path, both envs — `followRedirects = false` (§4) stays quiet.
- **Cloudflare is in front of dev, but not of prod.** Dev answers with `server: cloudflare` + `cf-ray` + `cf-cache-status: DYNAMIC`; prod returns none of those headers. §4's "Cloudflare bot challenge / 3xx" rationale still describes a real proxy in the dev path. Do not infer prod's edge from dev's headers — re-probe prod before reasoning about caching or challenges there.
- **`cf-cache-status: DYNAMIC` on dev** — uncached, which is required. A CDN-cached health response is worse than none: it reports a stale `healthy` while the server is down. Re-verify this if anyone adds cache rules for `*.neosapien.xyz`, and re-check prod separately since it carries no cache-status header to read.
- **~350 ms dev latency** — the 8 s default `requestTimeout` has ample headroom.
- **`{"status": "ok"}` is a static literal** — liveness, not readiness; it touches no datastore. This is what we want (see `docs/solutions/architecture-patterns/health-endpoint-liveness-vs-readiness.md`), with one known consequence: backend up + database down still returns 200 → package emits `healthy` → no banner while the app is broken. Covering that is the future `serverDegraded` state (§Out of scope), which needs a real dependency-check body.

## Tech

- Pure Dart package (no Flutter dep) — keeps it lightweight and reusable across CLI tools, server-side Dart, and future non-Flutter contexts. This is a load-bearing constraint, not a stylistic preference; do not relax it for convenience.
- SDK: `^3.11.1` (see `pubspec.yaml`).
- Lints: `lints: ^6.0.0`.

### Dependencies to add

| Package | Why | Notes |
|---|---|---|
| `http` | Lightweight server health request. Use **`GET`** (see below). | Use `http.Client` so it can be injected for tests. |
| `clock` | Measures probe round-trip time for the `weakNetwork` verdict. | Use `clock.now()`, **not `Stopwatch`** — `fake_async` installs a fake `Clock` but leaves `Stopwatch` on the real wall clock, so a stopwatch reads ~0 in every test regardless of elapsed virtual time. Pure Dart, maintained by the Dart team. |
| `internet_connection_checker_plus` | HTTP-level check that device actually has internet (not just WiFi attached to a captive portal). | **Required** over the original `internet_connection_checker` — the original pulls `flutter` + `connectivity_plus` as deps, which breaks the pure-Dart goal. `_plus` depends only on `http`. Pin `^3.0.0` and read the v3 migration guide before bumping. Override the default endpoint list (`one.one.one.one`, `captive.apple.com`, `icanhazip.com`, `ajax.googleapis.com`) if corp firewalls block any of them. This kind of dependency archaeology prevents pain later — do not "simplify" back to the original package. |

**HTTP method: `GET`, not `HEAD`.** Many backend frameworks return `405 Method Not Allowed` for `HEAD` on routes declared only as `GET` — silent breakage that the package would currently treat as `serverUnreachable`. `GET` is universally supported and lets us read the response body later (e.g. a future `{"status":"degraded"}` payload that could drive a `serverDegraded` state without an API break).

**Confirmed against the real backend 2026-07-16, not just predicted.** `/healthz` is declared `@app.get` and `HEAD https://neo-backend-v2.dev-api.neosapien.xyz/healthz` returns `405` live, while `GET` returns `200 {"status":"ok"}` (15-byte JSON body). Had this package shipped `HEAD`, it would have reported `serverUnreachable` permanently against a healthy server. See §Project → Backend endpoint.

Optional:
- `rxdart` — provides `BehaviorSubject` (new listeners immediately get the last state). It is **pure Dart** (does not pull Flutter); the only valid argument against adding it is dependency surface area, NOT a "Flutter dependency" claim. Hand-rolling replay-on-subscribe correctly is more code than it looks: must handle `close`, error forwarding, listener add/remove timing, and `onListen`/`onCancel` callbacks for the broadcast controller. Prefer `BehaviorSubject` unless the dependency cost is unacceptable.

Do **not** add Flutter as a dependency.

## Architecture

### 1. `ConnectionHealthState` enum (`lib/src/connection_health_state.dart`)

```dart
enum ConnectionHealthState {
  initial,              // before first check completes; starting sentinel
  healthy,              // server /health returned 2xx within slowThreshold
  weakNetwork,          // slow 2xx AND the user's own internet is also slow
  internetDisconnected, // server unreachable AND generic internet probe also failed
  serverUnreachable,    // server failed but generic internet probe succeeded
}
```

The distinct states are intentional — UI needs to distinguish "check your WiFi" (`internetDisconnected`, user can act) from "our servers are down" (`serverUnreachable`, user is stuck waiting). Do not collapse them. They drive different UI affordances and copy, and conflating them produces a worse product.

`weakNetwork` is a **latency verdict on the user's own internet**, not a failure — it reports a connection that works but is slow enough for uploads to visibly lag. It is a **two-signal** verdict: a slow 2xx from our server is only a *trigger*; the monitor then times the user's real internet (the neutral-CDN probe) and reports `weakNetwork` only on positive evidence that link is slow, so a slow *backend* on a healthy link resolves to `healthy`, not `weakNetwork` (§4). Note it is NOT the `serverDegraded` state reserved in §Out of scope: that one is a *backend*-reported condition read from the response body (`{"status":"degraded"}`) — "the link is fine, the backend is sick", the mirror of `weakNetwork`'s "your link is slow, the server is fine". Both may eventually exist; do not conflate the terms, and note the reserved name carries a `server` prefix precisely so they cannot be confused — see §Out of scope for why.

**Because `weakNetwork` is a success, it is deliberately exempt from the confirmation gate's failure-run logic** (rule 2): it does not count toward a run of failures and does not suppress escalation to a real failure. Get this wrong and the gate locks open — a link degrading *out of* `weakNetwork` into alternating hard failures would never confirm a down state, leaving a false-reassuring banner on a broken device. This is the single most-repeated bug in this package's history (twice). The full rule is in `CONCEPTS.md` ("Weak network" + the confirmation-gate entries) and `docs/solutions/architecture-patterns/weaknetwork-disarms-confirmation-rule-2.md`; the exemption itself lives in `_isConfirmed` / the gate logic in `connection_health_monitor.dart`. Do not touch weakNetwork's relationship to `downConfirmationCount` without reading those first.

**Adding an enum value is a breaking change** for consumers with exhaustive `switch` statements. Bump the version and write a CHANGELOG entry when you do.

### 2. `ConnectionHealthMonitor` service (`lib/src/connection_health_monitor.dart`)

Public API surface (keep small and stable):

```dart
class ConnectionHealthMonitor {
  ConnectionHealthMonitor({
    required String baseUrl,
    String healthPath = '/health',
    Duration healthyInterval = const Duration(minutes: 5),
    Duration retryInterval = const Duration(minutes: 1),
    Duration requestTimeout = const Duration(seconds: 8),
    Duration slowThreshold = const Duration(seconds: 3),
                                             // Slow-path threshold, used TWICE: a 2xx
                                             // slower than this TRIGGERS an internet
                                             // re-check, and weakNetwork is reported
                                             // only if the user's internet is ALSO
                                             // slower than this (§4). A slow backend on
                                             // a fast link stays healthy.
                                             // Must be in (0, requestTimeout);
                                             // throws ArgumentError otherwise.
                                             // NOTE: 3 s is a bare default with NO
                                             // field-data behind it (unlike the 8 s
                                             // requestTimeout, which has a documented
                                             // rationale). It is ~8x the ~350 ms healthy
                                             // baseline — headroom that keeps the trigger
                                             // from firing on normal latency. Do not tune
                                             // it (or add an adaptive baseline) until the
                                             // RTT distribution is measured — see the
                                             // measurement backlog in the trigger-seam
                                             // plan (KTD13 family).
    int downConfirmationCount = 1,           // consecutive degraded observations
                                             // required before emitting: N of the
                                             // SAME state, or N of any kind while
                                             // nothing degraded is reported yet
                                             // (else an alternating link reports
                                             // nothing, forever).
                                             // 1 = historical behaviour; 2 is the
                                             // RECOMMENDED PRODUCTION VALUE (the
                                             // Neosapien app ships 2). It is the
                                             // hysteresis latch that damps a lone slow
                                             // sample into weakNetwork — the same
                                             // "N-in-a-row" pattern Envoy/HAProxy use,
                                             // and the reason this package does NOT
                                             // need EWMA/windowed smoothing (which would
                                             // hold a 5-15 min stale value at this
                                             // probe cadence). weakNetwork routes
                                             // through this gate via _isConfirmed.
    double jitterRatio = 0.1,                // ±10% jitter on scheduled delays
    http.Client? httpClient,                 // inject for tests
    InternetConnection? internetChecker,     // inject for tests
    Random? random,                          // inject for deterministic jitter in tests
  });

  Stream<ConnectionHealthState> get stream;  // broadcast
  ConnectionHealthState get currentState;    // last known; see warning below

  void start();                              // idempotent — no-op if already running
  Future<void> stop();                       // pause: cancels timer, leaves controller open
  Future<void> dispose();                    // terminal: cancels timer, closes controller + owned client
  Future<ConnectionHealthState> checkNow();  // pure probe — see §6
}
```

**URL composition (constructor-time normalization).** A naive concat of `baseUrl: 'https://neo-backend-v2.dev-api.neosapien.xyz/'` (trailing slash) and `healthPath: '/healthz'` (leading slash) produces `https://neo-backend-v2.dev-api.neosapien.xyz//healthz`. Some servers tolerate it; some return 404; some misroute. Strip trailing `/` from `baseUrl` and ensure leading `/` on `healthPath` in the constructor, OR validate and throw `ArgumentError` on construction. Pre-compute the final `Uri` once and store it on the instance — do not rebuild per request. Test case #11 covers this.

**Warning on `currentState`.** Before the first check completes, `currentState` is `initial`. Consumers MUST NOT render UI from a synchronous read of `currentState` right after construction — that returns `initial` and tells you nothing. Consumers MUST subscribe to the stream and react to the first emitted event. Call this out in dartdoc on the getter so it shows up in IDE autocomplete tooltips.

### 3. Adaptive recursive loop (NOT a `Timer.periodic`)

`Timer.periodic` can overlap if a check takes longer than the interval, producing concurrent in-flight requests and re-entrant emits. Use a recursive `Future.delayed` pattern with ±10% jitter:

```
loop():
  state = await _runCheck()
  _emitIfChanged(state)
  // healthyInterval when the server ANSWERED (healthy or weakNetwork),
  // retryInterval when the probe FAILED. weakNetwork is a successful
  // probe — no outage to recover from — so it does not earn the fast
  // cadence; see §1 and CHANGELOG 0.2.0.
  base   = serverAnswered(state) ? healthyInterval : retryInterval
  jitter = (base * jitterRatio) * (random.nextDouble() * 2 - 1)   // ±jitterRatio
  delay  = Duration(milliseconds: base.inMilliseconds + jitter.toInt())
  _pendingTimer = Timer(delay, loop)   // store handle so stop()/dispose() can cancel
```

**Why jitter.** Without jitter, if 10,000 devices launch the app at 9:00 AM (commute time), they all hit `/health` at the same instant, then again 5 minutes later, then again — a synchronized thundering herd that produces avoidable backend load spikes. ±10% jitter is cheap, effective, and prevents an incident.

Inject the `Random` so jitter is deterministic in tests (seeded `Random(42)` produces reproducible delays). Default to `Random()` in production. Test case #14 verifies 100 scheduled delays fall within ±10% of base interval.

**Run flags.** Maintain two booleans on the instance:
- `_running` — true between `start()` and `stop()`. Loop checks this before scheduling the next iteration and before emitting; if false, bail without doing either.
- `_disposed` — true after `dispose()`. Every public method must check this first and throw `StateError('ConnectionHealthMonitor has been disposed')` if true.

`start()` is idempotent — if already `_running`, return without scheduling a second loop. Two concurrent loops would emit duplicate events and double the request rate.

### 4. Dual-tier check — try SERVER FIRST; internet probe is the tiebreaker

```
_runCheck():
  try:
    final req = http.Request('GET', _uri)..followRedirects = false;
    res = await httpClient.send(req).timeout(requestTimeout)
    if (res.statusCode is 2xx) return healthy
    // 3xx / 4xx / 5xx falls through to disambiguation
  on TimeoutException / SocketException / http errors:
    // falls through to disambiguation

  // Server failed. Was it our server, or the network?
  // NOTE: the v3 `_plus` API is `hasInternetAccess` (a Future<bool>
  // getter), NOT `hasConnection` — the latter is the ORIGINAL package's
  // API, which this package deliberately does not use.
  if (!await internetChecker.hasInternetAccess) return internetDisconnected
  return serverUnreachable
```

**Why server-first (NOT internet-check-first).** `internet_connection_checker_plus` probes public CDN endpoints (`one.one.one.one` / Cloudflare, `captive.apple.com`, `icanhazip.com`, `ajax.googleapis.com` / Google). On corporate firewalls, educational networks, and many Indian tier-2 ISP / corporate networks (which are part of Neosapien's user base), those probe endpoints are blocked while the Neosapien API host is whitelisted. The previous "internet-check-first" order would produce a false `internetDisconnected` verdict, and the UI would tell the user to "check your WiFi" — wrong message, wrong action, and the user cannot do anything to fix it because the WiFi is fine.

The inverted order:
- Resolves the false-negative correctly: server reachable + CDN-blocked → `healthy`.
- Is cheaper in the happy path: one request, not two. The internet probe only runs on the rare failure path.

Rules:
- **Server first.** Use `http.Request` (not `httpClient.get`) so `followRedirects = false` can be set. Treat any 3xx as `serverUnreachable` (handled by the disambiguation block — 3xx is not 2xx, so it falls through). Rationale: Cloudflare is confirmed in front of the real endpoint (§Project → Backend endpoint), so if `/healthz` ends up behind a bot challenge or a 301 to a migrated host (common during domain migrations), the "2xx = healthy" rule would silently break. Better to explicitly fail and let ops notice.
- Treat any non-2xx, timeout, or thrown exception from the HTTP call as a failure that triggers the internet-check tiebreaker.
- Do not retry inside `_runCheck()` — the loop already retries on the 1-minute cadence. Retrying here doubles request rate without improving outcomes.
- Read and discard the response body to free the connection back to the pool. Do not parse the body in v1 (future `serverDegraded` state will).

**Known limits of the dual-tier check.** The two-request disambiguation is right for the common cases (§4 rationale above), but it has two blind spots by construction. Both are accepted for v1 and documented here so they are not rediscovered as "bugs" during an incident:

1. **False `serverUnreachable` on a whitelisting network (mirror of the case §4 fixes).** §4 inverted the check order to fix the false `internetDisconnected` that a CDN-blocking network produces. The mirror is not covered: a network that *permits* the internet-probe endpoints (`one.one.one.one`, `captive.apple.com`, `icanhazip.com`, `ajax.googleapis.com` — Google/Apple/Cloudflare hosts, among the most commonly whitelisted on earth) but *blocks our host* makes the server probe fail while `hasInternetAccess` reports `true` → `serverUnreachable`. The banner then says "Server down" when our backend is healthy and the real fault is a firewall between this device and us. Same shape reaches the user from **our own misconfiguration**: a wrong `healthPath` returns `404` (or `HEAD` returns `405`, §Tech), and a `404` is currently indistinguishable from a real outage — both are non-2xx → `serverUnreachable`. Test case #13b pins this.
   - **The discriminator is already in hand and thrown away.** `_runCheck` catches three distinct failure kinds — `TimeoutException`, `http.ClientException`, generic `Exception` (`connection_health_monitor.dart:458-469`) — and `_probeServer` computes the exact status code (`:500`) — then both discard everything except a single `bool`. An *HTTP response of any status* proves we reached the server (its fault); a *socket/TLS/timeout throw* proves the path was blocked before we got there (the network's fault). That difference separates "our server is sick" from "this network won't let you talk to us," and it costs nothing to retain.
   - **Remedy (not v1):** do NOT add a fifth enum value — the user's action is identical to a real outage (wait, or switch networks), and it is a breaking change. Surface the failure kind (status code *or* exception type) through the optional diagnostic callback the trigger-seam plan already schedules (KTD13), whose signature must widen past `ConnectionHealthState` to carry it — see `docs/plans/2026-07-19-001-…-plan.md` KTD13. Cheapest honest fix meanwhile is **copy**: "Can't reach Neo servers" is true in both the real-outage and blocked-by-network cases, where "Server down" is an unprovable claim from the client. Needs a design call (Figma `5838-19485` currently says "Server down").

2. **False `healthy` via TLS interception (iOS-MDM-only).** The happy path trusts any `2xx` as `healthy` without reading the body — the deliberate §Tech `GET`-not-`HEAD`/no-body-parse decision. Over HTTPS a captive portal *cannot* forge a `2xx`: without a device-trusted certificate for our host, interception surfaces as `HandshakeException`/`SocketException`/timeout (→ correctly `serverUnreachable`/`internetDisconnected`, not a fake `healthy`). The one exception is a **trusted MITM root already installed on the device**: an MDM-managed corporate proxy ("SSL inspection" — Zscaler, Palo Alto, etc.). On Android API 24+ apps ignore user/MDM-added CAs by default, so this fails closed there; on **iOS, MDM-installed roots are auto-trusted**, so a managed iOS device behind an SSL-inspecting proxy could receive a proxy-generated `2xx` (a block/login page) and read it as `healthy`. Narrow (managed iOS only), no proven mobile-app prevalence figure exists, and body-validation is not the fix (`/healthz` returns a static literal body — §Project — so there is nothing distinctive to validate, and zero of 12 surveyed industry health checkers default to body matching). Accepted for v1; recorded so a future `serverDegraded`/body-parse revision weighs it deliberately rather than inheriting it silently.

3. **~~The slow path does NOT cross-check, so `weakNetwork` can mislabel a slow backend as a slow network.~~ RESOLVED (0.3.0).** The slow path now cross-checks. On a slow `2xx`, `_runCheck` no longer trusts the backend round trip alone — it times the user's real internet (the neutral-CDN probe via `_userInternetIsSlow`, `connection_health_monitor.dart`) and reports `weakNetwork` only on **positive evidence** the user's link is slow; a fast, blocked, unreachable, or errored internet check resolves to `healthy`. So a slow *backend* on a healthy link is now `healthy`, not a false "Weak Network". This matches the state's own definition (CONCEPTS.md: "your link slow, the server is fine") and needed no new enum value — the fix is a second probe on the rare slow-2xx path, and the happy path (fast 2xx) is still one request. See the plan doc `docs/plans/2026-07-30-001-feat-weak-internet-two-signal-plan.md`. NOTE the asymmetry that was NEVER a gap: `weakNetwork` is confirmed by the SAME gate as failures (`_isConfirmed`), and is in fact *stricter* — exempt from Rule 2's generic-failure shortcut (`:590-593`), so it can only confirm via a same-state run.

### 5. Stream behavior

- Use `StreamController<ConnectionHealthState>.broadcast()` so multiple widgets can subscribe.
- Cache `currentState` on every emit and replay it to late subscribers (manual wrapper or `rxdart.BehaviorSubject`).
- **De-dupe**: only emit when the state actually changes. Repeated `healthy → healthy` emissions cause needless UI rebuilds in every subscribed `StreamBuilder`.
- **`initial` is a valid "previous state" for de-dupe.** The first real check that lands on `internetDisconnected` MUST emit exactly one event (`initial → internetDisconnected`). The de-dupe rule "skip if newState == lastState" handles this correctly only if `lastState` is initialized to `initial` (not null and not the first observed state). Test case #12 verifies.
- Emit only from the loop and from `start()`'s initial check; `checkNow()` does NOT emit (§6).

### 6. `checkNow()` semantics — Option B: pure probe

`checkNow()` returns `Future<ConnectionHealthState>` and **does NOT emit on the stream**. It is a pure probe used by retry buttons that await the result locally. It resets the scheduled timer so the next polling delay is measured from `checkNow()`'s completion (cancel `_pendingTimer`, schedule a new one at the appropriate interval after the probe completes).

**It does NOT move `currentState` either** (changed in 0.2.0 — earlier revisions of this document said it did). `currentState` is replayed to late subscribers, so it must only ever hold a value the stream actually emitted; letting a pure probe advance it would let the two disagree. `checkNow()` likewise does not advance the `downConfirmationCount` streak. Practical consequence for consumers: a retry that succeeds does not itself clear a banner driven by `stream` — act on the returned value, or wait for the next scheduled tick.

Two options were considered:
- **Option A (rejected):** `checkNow()` returns `Future<void>`, all observation flows through the stream. Simpler mental model — one source of truth — but the retry-button use case wants the result locally to drive a button spinner / toast, so consumers would have to subscribe to the stream and await an event matching the call, which is awkward.
- **Option B (chosen):** `checkNow()` returns `Future<ConnectionHealthState>`, does NOT emit. Pure probe.

The dual emit-and-return shape was rejected because it gives the same state transition two delivery paths (future + stream), which (a) makes de-dupe semantics ambiguous (if `currentState == healthy` and the probe confirms `healthy`, does the future resolve to `healthy` while the stream emits nothing?) and (b) invites double-handling bugs where consumers act on both paths.

Document this clearly in dartdoc on `checkNow()` — consumers who expect emission will get silent breakage otherwise.

### 7. Lifecycle: `start` / `stop` / `dispose`

The previous plan conflated "pause" and "destroy" by closing the `StreamController` inside `stop()`. That makes the `stop()` → background → resume → `start()` pattern (which is the recommended battery pattern) crash on the second `start()`:

```dart
await monitor.stop();
monitor.start();   // CRASHED in old design: controller closed, cannot add events
```

The split:

| Method | Cancels timer | Closes stream controller | Closes owned HTTP client | Idempotent | Re-entry via `start()` |
|---|---|---|---|---|---|
| `start()` | — | — | — | yes | n/a |
| `stop()` | yes | **no** | **no** | yes | **yes — works** |
| `dispose()` | yes | yes | yes (only if package-owned) | yes | no — throws `StateError` |

Rules:
- `start()` — kicks off the first check immediately (don't wait `healthyInterval` for the first signal); then schedules the next. Idempotent. Throws `StateError` if `_disposed`.
- `stop()` — pause. Cancels `_pendingTimer`, sets `_running = false`. The `StreamController` stays open. Used by consumers that pause on app background and resume on foreground (the recommended battery pattern, §8).
- `dispose()` — terminal cleanup. Cancels timer, closes the broadcast controller, closes the owned `http.Client`. Calling any method (including `dispose()` itself called twice) on a disposed instance throws `StateError`.
- Close the `http.Client` on `dispose()` **only if the package created it** — never close an injected client (the test or DI container owns it). Track ownership: set `_ownsClient = (httpClient == null)` in the constructor; pass `client.close()` through the guard on dispose.
- **In-flight `GET` on `stop()` / `dispose()`:** the loop must check `_disposed` (and for `stop`, `_running`) AFTER `await _runCheck()` completes and BEFORE `_emit()` / before scheduling the next timer. If false, bail without emitting and without rescheduling. Without this guard, a long-running request that completes after `dispose()` will try to `add` to a closed controller and crash. On `dispose()` with a package-owned client, `client.close()` aborts the in-flight request, which causes `_runCheck()` to throw — catch and swallow that exception during disposal. On `dispose()` with an injected client, do NOT call `client.close()`; rely on the `_disposed` flag check to silently drop the result.

### 8. Caller responsibilities (lifecycle / battery)

**This package does NOT observe app lifecycle.** It is a pure-Dart package; observing `AppLifecycleState` would force a Flutter dependency, which is forbidden (§Tech). A consumer that ignores this section will poll every 1 minute (in the unhealthy state) while the app is backgrounded — 60 HTTP attempts + 60 radio wakeups per backgrounded hour. App Store and Play Store battery reviews WILL reflect this.

Required consumer integration on Flutter — document loudly in the README AND in the class-level dartdoc:

> The caller MUST call `monitor.stop()` when the app enters `AppLifecycleState.paused` / `inactive` and `monitor.start()` on resume. The package will not do this for you; doing so would force a Flutter dependency.

Provide a copy-paste-ready snippet in the README:

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
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        monitor.stop();
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

## File layout (target)

```
lib/
  neo_connection_health.dart      # barrel: MUST export ConnectionHealthMonitor AND ConnectionHealthState
  src/
    connection_health_state.dart          # enum
    connection_health_monitor.dart        # service
example/
  neo_connection_health_example.dart  # minimal usage demo
test/
  connection_health_monitor_test.dart     # unit tests with injected fakes
tool/
  check.sh                                # format + analyze + test; called by CI and pre-commit
docs/
  solutions/                              # documented solutions to past problems (bugs, decisions, patterns), by category, with YAML frontmatter (module, tags, problem_type); relevant when implementing or debugging in documented areas
```

`CONCEPTS.md` at the repo root holds the shared domain vocabulary — the terms with project-specific meaning (`Observation` vs `Reported state`, the confirmation gate's two rules, blip protection). Relevant when orienting to the state machine or discussing these concepts; the distinctions it records are ones this package has gotten wrong before.

Rename existing `lib/src/neo_connection_health_base.dart` once real files exist — don't keep the placeholder.

**Barrel exports.** `lib/neo_connection_health.dart` MUST export both `ConnectionHealthMonitor` AND `ConnectionHealthState`. If only the class is exported, consumers cannot pattern-match on the enum without importing `src/`, which leaks implementation paths and is fragile across refactors. Easy to forget; the barrel file must contain both `export 'src/connection_health_monitor.dart';` and `export 'src/connection_health_state.dart';`.

## Testing

- Inject `http.Client`, `InternetConnection`, and `Random` so tests never hit the network and jitter is deterministic.
- Use `package:test` (already in `dev_dependencies`) + `http.MockClient` for HTTP fakes.
- Use `package:fake_async` for deterministic time-based tests instead of real `Future.delayed`. Anyone who has tried to test timer-based code with real delays knows why — flaky tests, slow suites, brittle wall-clock dependencies.

Required cases (the original plan listed 7; review added 8–14):

1. Internet down → emits `internetDisconnected`, schedules retry in ~1 min (within ±10% jitter band).
2. Internet up, server 500 → `serverUnreachable`.
3. Internet up, server timeout → `serverUnreachable`.
4. Internet up, server 200 → `healthy`, next check scheduled at ~5 min (within ±10% jitter band).
5. Transition `healthy → unhealthy → healthy` emits exactly 3 events (de-dupe works).
6. `stop()` cancels pending timer (`fake_async` verifies no further emissions after stop).
7. `checkNow()` forces an immediate check, returns the state, **does NOT emit on the stream** (Option B, §6), resets the schedule.
8. **Internet probe fails but server returns 200 → `healthy`** (validates inverted check order in §4 — the corporate-firewall scenario).
9. **`stop()` followed by `start()` → monitor resumes without throwing** (validates §7 pause-vs-terminal split).
10. **`dispose()` followed by any method call → throws `StateError`** (validates §7 terminal contract).
11. **`baseUrl` with trailing `/` + `healthPath` with leading `/` → no `//` in the request URL** (validates URL normalization in §2).
12. **`initial` → `internetDisconnected` emits exactly one event** (validates de-dupe treats `initial` as a starting sentinel, §5).
13. **Server returns 3xx redirect → treated as `serverUnreachable`** (validates `followRedirects = false` in §4).
13b. **Server returns 4xx (internet up) → `serverUnreachable`** (pins the §4 "Known limits" mirror-case: a `404` from a misconfigured `healthPath` is indistinguishable from a real outage today).
14. **Jitter test: with a seeded `Random`, 100 scheduled delays fall within ±10% of base interval** (validates §3).

## Conventions

- Public API lives in `lib/neo_connection_health.dart` (barrel). Re-export both `ConnectionHealthMonitor` AND `ConnectionHealthState`. Everything else in `lib/src/**` is implementation; do not re-export internal classes unless intentional.
- Document every public symbol with `///` dartdoc — `dart doc` should produce clean output. Specifically required:
  - Dartdoc on `stop()` AND `dispose()` must explicitly state the pause-vs-terminal distinction so IDE tooltips show it.
  - Dartdoc on `checkNow()` must state "does NOT emit on the stream" — silent breakage otherwise.
  - Dartdoc on `currentState` must state the "do not render UI from a synchronous read right after construction" warning.
  - Class-level dartdoc must include the "caller MUST call `stop()` on background" rule from §8.
- Default `requestTimeout` is **8s** (not 5s). 5s is fine on LTE / WiFi but tight on 3G in tier-2 Indian cities, which is part of Neosapien's user base. Callers can override; 8s is the safer default.
- Pre-commit / CI: `tool/check.sh` runs `dart format --set-exit-if-changed .`, `dart analyze --fatal-infos`, and `dart test`. Wire this into CI so it is enforced, not aspirational. Verbal "run before committing" conventions decay; a script and a CI job do not.
- Keep `CHANGELOG.md` updated per pub.dev conventions (semver, dated sections).

## Out of scope (do not add without asking)

- Native platform channels — defeats "pure Dart" goal.
- App-lifecycle observation inside the package — would force a Flutter dependency; it is the caller's responsibility (§8).
- Persistent storage of state across app restarts.
- Multiple base URLs / multi-endpoint health aggregation.
- Exponential backoff — spec is a flat 1-min retry (with ±10% jitter); don't second-guess it. Adding backoff invites scope creep and changes the semantics consumers expect.
- Logging frameworks — leave logging to the consumer app. The package can accept an optional `void Function(Object)` log callback in a future revision if needed, but no framework dependency.
- A `serverDegraded` state in v1. The body-parse path for `{"status": "degraded"}` is a future revision; the `GET` choice (§Tech) keeps that door open without an API break.

  **The reserved name is `serverDegraded`, not `degraded`** — decided 2026-07-19, and the decision is the whole point. A bare `degraded` sits one synonym away from the shipped `weakNetwork`, and the two mean opposite things about who is at fault: `weakNetwork` is measured *client-side* from round-trip time (your link is slow, the server is fine), `serverDegraded` is *server-reported* from the response body (the link is fine, the backend is sick). Names that close together get merged by a well-meaning refactor, and the merge is silent — both are "sort of working", so no test fails. The `server` prefix costs one word today and makes the collision unavailable forever. It also matches the existing `serverUnreachable`, which already carries the same prefix for the same reason.

## Decisions worth NOT re-litigating

Senior review explicitly endorsed these — do not "simplify" them away in future PRs:

- **Pure-Dart constraint.** Keeps the package reusable in CLI, server-side Dart, and future non-Flutter contexts.
- **Four-state enum.** `internetDisconnected` and `serverUnreachable` MUST NOT be collapsed — they drive different UI affordances ("fix your WiFi" vs. "we're working on it").
- **Recursive `Future.delayed` over `Timer.periodic`.** Avoids the overlap bug where a slow check produces concurrent in-flight requests.
- **DI seams for `http.Client`, `InternetConnection`, `Random`.** Makes the package testable without network or wall-clock dependence.
- **First check fires immediately on `start()`**, not after one interval. Users get a signal on app launch, not 5 minutes later.
- **De-duplication on state change.** Prevents needless UI rebuilds.
- **`package:fake_async` for time-based tests.** The right tool; no real-time `Future.delayed` in the test suite.
- **Explicit "out of scope" section.** Prevents scope creep on the first PR. Keeping exponential backoff out is correct — flat retry is simpler and matches the spec.

## Severity summary (review verdict, for PR-review reference)

| # | Change | Severity |
|---|---|---|
| 1 | Invert dual-tier check order — try server first, internet check as tiebreaker (§4) | High |
| 2 | Split `stop()` and `dispose()` — pause vs. terminal cleanup (§7) | High |
| 3 | Document backgrounding responsibility prominently (§8) | High |
| 4 | Resolve `checkNow()` dual-return ambiguity — Option B, pure probe (§6) | Medium |
| 5 | Add ±10% jitter to polling interval (§3) | Medium |
| 6 | Pick `GET`, document the choice (§Tech) | Medium |
| 7 | Define in-flight request handling on stop/dispose (§7) | Medium |
| 8 | Rewrite or remove the `rxdart` Flutter-dependency claim (§Tech) | Low |
| 9 | Various nits: `initial` test, barrel exports, 8s timeout, redirect handling, URL normalization, `tool/check.sh`, `currentState` warning | Low |

## Quick reference — expected consumer usage

```dart
// healthPath is REQUIRED — the Neosapien route is /healthz, not the
// package default /health. See §Project → Backend endpoint.
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

// On app background / foreground (caller's responsibility — see §8):
monitor.stop();   // paused, can resume
monitor.start();  // resumes

// On app shutdown:
await monitor.dispose();
```
