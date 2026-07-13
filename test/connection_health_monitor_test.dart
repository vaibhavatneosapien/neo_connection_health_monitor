// Full behavioral test suite for `ConnectionHealthMonitor`. Covers all
// 14 cases required by `CLAUDE.md` §Testing plus supplementary cases
// added during code review (7b, 14b, 15, 15b, 16, 17, 18, 19) and the
// post-review mend pass (20 timeout+offline, 21 dispose-in-flight,
// 22 checkNow-before-start, 23 late-subscriber de-dupe, 24 jitter assert,
// 25 injected-checker not disposed).
//
// Uses:
//   - `package:http/testing.dart` `MockClient` to fake the server probe.
//   - A `_FakeInternetConnection` subclass to control the internet probe.
//   - `package:fake_async` to drive timer-based scheduling deterministically.
//   - A seeded `Random` for predictable jitter.
//
// Every test injects all dependencies — no test hits the real network or
// the real wall clock.

import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:neo_connection_health_monitor/neo_connection_health_monitor.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Fakes.
// ---------------------------------------------------------------------------

/// Test double for `InternetConnection`. The `hasInternetAccess` getter is
/// the only API the monitor uses; overriding it covers the surface.
class _FakeInternetConnection extends InternetConnection {
  _FakeInternetConnection({required this.online}) : super.createInstance();

  bool online;

  /// Set true if the monitor ever calls [dispose] on this instance. Used to
  /// verify the monitor never disposes an INJECTED checker (only one it
  /// created itself is owned).
  bool disposed = false;

  @override
  Future<bool> get hasInternetAccess async => online;

  @override
  Future<void> dispose() async {
    disposed = true;
    // Deliberately do NOT call super.dispose(): the base spins real timers
    // this fake never started.
  }
}

/// Builds a `ConnectionHealthMonitor` with all dependencies injected. All
/// timers are deterministic when run inside `fakeAsync(...)`.
ConnectionHealthMonitor _build({
  required http.Client httpClient,
  required InternetConnection internetChecker,
  Duration healthyInterval = const Duration(minutes: 5),
  Duration retryInterval = const Duration(minutes: 1),
  Duration requestTimeout = const Duration(seconds: 8),
  double jitterRatio = 0.0,
  Random? random,
  String baseUrl = 'https://api.example.com',
  String healthPath = '/health',
}) {
  return ConnectionHealthMonitor(
    baseUrl: baseUrl,
    healthPath: healthPath,
    healthyInterval: healthyInterval,
    retryInterval: retryInterval,
    requestTimeout: requestTimeout,
    jitterRatio: jitterRatio,
    httpClient: httpClient,
    internetChecker: internetChecker,
    random: random ?? Random(42),
  );
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

void main() {
  group('ConnectionHealthMonitor — behavioral suite', () {
    // -------------------------------------------------------------------
    // 1: Internet down → internetDisconnected, retry scheduled ~1 min.
    // -------------------------------------------------------------------
    test('1: internet down → internetDisconnected, retry in retryInterval', () {
      fakeAsync((async) {
        var hits = 0;
        final emissions = <ConnectionHealthState>[];
        final monitor = _build(
          httpClient: MockClient((_) async {
            hits++;
            throw http.ClientException('no route');
          }),
          internetChecker: _FakeInternetConnection(online: false),
          retryInterval: const Duration(minutes: 1),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();

        async.flushMicrotasks();
        expect(emissions, [ConnectionHealthState.internetDisconnected]);
        expect(hits, 1);

        // Retry is scheduled at retryInterval (no jitter here).
        async.elapse(const Duration(seconds: 59));
        expect(hits, 1, reason: 'no early re-poll');
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        // De-dupe: still internetDisconnected, so no new emission, but
        // the second HTTP attempt must have fired.
        expect(emissions.length, 1, reason: 'de-dupe suppresses re-emit');
        expect(hits, 2, reason: 'retry actually ran the probe');

        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 2: Internet up, server 500 → serverUnreachable.
    // -------------------------------------------------------------------
    test('2: server 500 → serverUnreachable', () {
      fakeAsync((async) {
        final emissions = <ConnectionHealthState>[];
        final monitor = _build(
          httpClient: MockClient((_) async => http.Response('boom', 500)),
          internetChecker: _FakeInternetConnection(online: true),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();
        async.flushMicrotasks();
        expect(emissions, [ConnectionHealthState.serverUnreachable]);
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 3: Internet up, server timeout → serverUnreachable.
    // -------------------------------------------------------------------
    test('3: server timeout → serverUnreachable', () {
      fakeAsync((async) {
        final emissions = <ConnectionHealthState>[];
        // Handler never completes; `.timeout(requestTimeout)` should fire.
        final never = Completer<http.Response>();
        final monitor = _build(
          httpClient: MockClient((_) => never.future),
          internetChecker: _FakeInternetConnection(online: true),
          requestTimeout: const Duration(seconds: 3),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();

        async.elapse(const Duration(seconds: 4));
        async.flushMicrotasks();
        expect(emissions, [ConnectionHealthState.serverUnreachable]);
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 4: Internet up, server 200 → healthy, next check at healthyInterval.
    // -------------------------------------------------------------------
    test('4: server 200 → healthy, next check at healthyInterval', () {
      fakeAsync((async) {
        var hitCount = 0;
        final emissions = <ConnectionHealthState>[];
        final monitor = _build(
          httpClient: MockClient((_) async {
            hitCount++;
            return http.Response('ok', 200);
          }),
          internetChecker: _FakeInternetConnection(online: true),
          healthyInterval: const Duration(minutes: 5),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();
        async.flushMicrotasks();
        expect(emissions, [ConnectionHealthState.healthy]);
        expect(hitCount, 1);

        async.elapse(const Duration(minutes: 4, seconds: 59));
        async.flushMicrotasks();
        expect(hitCount, 1, reason: 'no early second check');

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(hitCount, 2);
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 5: healthy → unhealthy → healthy emits exactly 3 events (de-dupe).
    // -------------------------------------------------------------------
    test('5: healthy → unhealthy → healthy emits exactly 3 events', () {
      fakeAsync((async) {
        final emissions = <ConnectionHealthState>[];
        var statusCode = 200;
        final monitor = _build(
          httpClient: MockClient((_) async => http.Response('', statusCode)),
          internetChecker: _FakeInternetConnection(online: true),
          healthyInterval: const Duration(seconds: 10),
          retryInterval: const Duration(seconds: 5),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();
        async.flushMicrotasks();
        expect(emissions, [ConnectionHealthState.healthy]);

        // Toggle to 500 → next loop tick should emit serverUnreachable.
        statusCode = 500;
        async.elapse(const Duration(seconds: 11));
        async.flushMicrotasks();
        expect(emissions, [
          ConnectionHealthState.healthy,
          ConnectionHealthState.serverUnreachable,
        ]);

        // Toggle back to 200.
        statusCode = 200;
        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();
        expect(emissions, [
          ConnectionHealthState.healthy,
          ConnectionHealthState.serverUnreachable,
          ConnectionHealthState.healthy,
        ]);

        // Stay healthy — de-dupe should suppress further emits.
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(emissions.length, 3);
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 6: stop() cancels pending timer; no further emissions after stop.
    // -------------------------------------------------------------------
    test('6: stop() cancels pending timer — no further emissions', () {
      fakeAsync((async) {
        var hits = 0;
        final emissions = <ConnectionHealthState>[];
        final monitor = _build(
          httpClient: MockClient((_) async {
            hits++;
            return http.Response('ok', 200);
          }),
          internetChecker: _FakeInternetConnection(online: true),
          healthyInterval: const Duration(seconds: 10),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();
        async.flushMicrotasks();
        expect(hits, 1);
        expect(emissions, [ConnectionHealthState.healthy]);

        monitor.stop();
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(hits, 1, reason: 'no further HTTP calls after stop');
        expect(emissions, [ConnectionHealthState.healthy]);
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 7: checkNow() returns the state, does NOT emit on the stream, resets
    // the schedule.
    // -------------------------------------------------------------------
    test('7: checkNow() returns state, does NOT emit on stream', () {
      fakeAsync((async) {
        var hits = 0;
        final emissions = <ConnectionHealthState>[];
        final monitor = _build(
          httpClient: MockClient((_) async {
            hits++;
            return http.Response('ok', 200);
          }),
          internetChecker: _FakeInternetConnection(online: true),
          healthyInterval: const Duration(seconds: 10),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();
        async.flushMicrotasks();
        expect(emissions.length, 1);
        expect(hits, 1);

        // Fire checkNow at 5s — it should run another HTTP call but NOT
        // emit (state didn't change).
        async.elapse(const Duration(seconds: 5));
        ConnectionHealthState? probed;
        monitor.checkNow().then((s) => probed = s);
        async.flushMicrotasks();
        expect(probed, ConnectionHealthState.healthy);
        expect(hits, 2);
        // Critical: even though state == healthy, no NEW emission fired
        // (and the de-dupe rule would have suppressed it anyway — but the
        // contract is "checkNow never emits", verified by the next case).
        expect(emissions.length, 1);

        // The schedule was reset: the next auto-emit should fire at
        // healthyInterval AFTER checkNow's completion, not after start.
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(hits, 2, reason: 'still inside the reset window');
        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();
        expect(hits, 3);
        monitor.dispose();
      });
    });

    // Stronger checkNow assertion: when checkNow forces a state CHANGE,
    // it STILL does not emit (Option B contract).
    test('7b: checkNow() does NOT emit even when state changes', () {
      fakeAsync((async) {
        var statusCode = 200;
        final emissions = <ConnectionHealthState>[];
        final monitor = _build(
          httpClient: MockClient((_) async => http.Response('', statusCode)),
          internetChecker: _FakeInternetConnection(online: true),
          healthyInterval: const Duration(hours: 1),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();
        async.flushMicrotasks();
        expect(emissions, [ConnectionHealthState.healthy]);

        // Toggle backend and probe via checkNow — currentState should
        // change to serverUnreachable but the stream must NOT receive it.
        statusCode = 500;
        ConnectionHealthState? probed;
        monitor.checkNow().then((s) => probed = s);
        async.flushMicrotasks();
        expect(probed, ConnectionHealthState.serverUnreachable);
        expect(monitor.currentState, ConnectionHealthState.serverUnreachable);
        expect(
            emissions,
            [
              ConnectionHealthState.healthy,
            ],
            reason: 'checkNow must NEVER emit on stream');
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 8: Internet probe fails but server returns 200 → healthy.
    // (The server-first / inverted-order corporate-firewall scenario.)
    // -------------------------------------------------------------------
    test('8: server-first — internet probe fails, server 200 → healthy', () {
      fakeAsync((async) {
        final emissions = <ConnectionHealthState>[];
        final monitor = _build(
          httpClient: MockClient((_) async => http.Response('ok', 200)),
          internetChecker: _FakeInternetConnection(online: false),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();
        async.flushMicrotasks();
        expect(
          emissions,
          [ConnectionHealthState.healthy],
          reason: 'server probe succeeded — internet probe is irrelevant',
        );
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 9: stop() then start() → monitor resumes without throwing.
    // -------------------------------------------------------------------
    test('9: stop() then start() resumes without throwing', () {
      fakeAsync((async) {
        var hits = 0;
        final emissions = <ConnectionHealthState>[];
        final monitor = _build(
          httpClient: MockClient((_) async {
            hits++;
            return http.Response('ok', 200);
          }),
          internetChecker: _FakeInternetConnection(online: true),
          healthyInterval: const Duration(seconds: 10),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();
        async.flushMicrotasks();
        expect(hits, 1);

        monitor.stop();
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(hits, 1);

        // Resume — should fire immediately like the first start.
        expect(monitor.start, returnsNormally);
        async.flushMicrotasks();
        expect(hits, 2);
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 10: dispose() then any method call → throws StateError.
    // -------------------------------------------------------------------
    test('10: dispose() then any method call throws StateError', () async {
      final monitor = ConnectionHealthMonitor(
        baseUrl: 'https://api.example.com',
        httpClient: MockClient((_) async => http.Response('ok', 200)),
        internetChecker: _FakeInternetConnection(online: true),
      );
      await monitor.dispose();

      expect(monitor.start, throwsA(isA<StateError>()));
      expect(monitor.stop, throwsA(isA<StateError>()));
      expect(monitor.checkNow, throwsA(isA<StateError>()));

      // dispose() itself is idempotent (no throw on second call).
      await monitor.dispose();
    });

    // -------------------------------------------------------------------
    // 11: baseUrl trailing / + healthPath leading / → no // in request URL.
    // -------------------------------------------------------------------
    test('11: URL normalization — no // in actual request URL', () {
      fakeAsync((async) {
        Uri? capturedUrl;
        final monitor = _build(
          baseUrl: 'https://api.example.com/',
          healthPath: '/health',
          httpClient: MockClient((req) async {
            capturedUrl = req.url;
            return http.Response('ok', 200);
          }),
          internetChecker: _FakeInternetConnection(online: true),
        );
        monitor.start();
        async.flushMicrotasks();
        expect(capturedUrl?.toString(), 'https://api.example.com/health');
        expect(capturedUrl?.toString().contains('//health'), isFalse);
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 12: initial → internetDisconnected emits EXACTLY one event.
    // -------------------------------------------------------------------
    test('12: initial → internetDisconnected emits exactly one event', () {
      fakeAsync((async) {
        final emissions = <ConnectionHealthState>[];
        final monitor = _build(
          httpClient: MockClient(
            (_) async => throw http.ClientException('no route'),
          ),
          internetChecker: _FakeInternetConnection(online: false),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();
        async.flushMicrotasks();
        expect(emissions, [ConnectionHealthState.internetDisconnected]);
        expect(emissions.length, 1);
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 13: Server returns 3xx redirect → treated as serverUnreachable.
    // (Validates followRedirects = false on the request.)
    // -------------------------------------------------------------------
    test('13: server 3xx → serverUnreachable', () {
      fakeAsync((async) {
        final emissions = <ConnectionHealthState>[];
        final monitor = _build(
          httpClient: MockClient(
            (_) async => http.Response(
              '',
              301,
              headers: {'location': 'https://elsewhere.example/'},
            ),
          ),
          internetChecker: _FakeInternetConnection(online: true),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();
        async.flushMicrotasks();
        expect(emissions, [ConnectionHealthState.serverUnreachable]);
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 14: Jitter — with a seeded Random, scheduled delays fall within
    // ±jitterRatio of the base interval.
    // -------------------------------------------------------------------
    test('14: jitter — 100 scheduled delays within ±10% of base interval', () {
      // Mirror the monitor's _nextDelay formula with the same seed.
      const baseMs = 10000;
      const jitterRatio = 0.1;
      final rng = Random(42);
      for (var i = 0; i < 100; i++) {
        final jitterMs = (baseMs * jitterRatio) * (rng.nextDouble() * 2 - 1);
        final totalMs = baseMs + jitterMs.toInt();
        expect(
          totalMs,
          inInclusiveRange(
            (baseMs * (1 - jitterRatio)).floor(),
            (baseMs * (1 + jitterRatio)).ceil(),
          ),
          reason: 'iteration $i: delay $totalMs outside ±10% band',
        );
      }
    });

    // -------------------------------------------------------------------
    // 14b: Integration jitter check — with a seeded Random, the scheduler
    // actually fires within the band (not just the formula).
    // -------------------------------------------------------------------
    test('14b: every scheduled cycle fires inside the ±10% jitter band', () {
      fakeAsync((async) {
        final fireTimes = <Duration>[];
        final monitor = _build(
          httpClient: MockClient((_) async {
            fireTimes.add(async.elapsed);
            return http.Response('ok', 200);
          }),
          internetChecker: _FakeInternetConnection(online: true),
          healthyInterval: const Duration(seconds: 10),
          jitterRatio: 0.1,
          random: Random(42),
        );
        monitor.start();
        // Run long enough that ~6 cycles fire — exercises multiple
        // successive nextDouble() outputs (both jitter polarities).
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        monitor.dispose();

        expect(
          fireTimes.length,
          greaterThanOrEqualTo(5),
          reason: 'at least 5 cycles in 60s',
        );
        final deltas = <int>[];
        for (var i = 1; i < fireTimes.length; i++) {
          final deltaMs = (fireTimes[i] - fireTimes[i - 1]).inMilliseconds;
          deltas.add(deltaMs);
          // Every inter-fire delta must land inside [0.9*base, 1.1*base].
          expect(
            deltaMs,
            inInclusiveRange(9000, 11000),
            reason: 'cycle ${i + 1} delta $deltaMs ms outside ±10% band',
          );
        }
        // Regression guard: if jitter were silently disabled, every
        // delta would equal `base` exactly. Assert both jitter polarities.
        expect(
          deltas.any((d) => d < 10000),
          isTrue,
          reason: 'no delta below base — negative jitter never fired',
        );
        expect(
          deltas.any((d) => d > 10000),
          isTrue,
          reason: 'no delta above base — positive jitter never fired',
        );
      });
    });

    // -------------------------------------------------------------------
    // 17: post-dispose stream subscriber gets onDone, no phantom replay.
    // -------------------------------------------------------------------
    test('17: post-dispose subscriber → onDone, no phantom event', () async {
      final monitor = ConnectionHealthMonitor(
        baseUrl: 'https://api.example.com',
        httpClient: MockClient((_) async => http.Response('ok', 200)),
        internetChecker: _FakeInternetConnection(online: true),
      );
      monitor.start();
      // Pump until the first check has completed (currentState becomes
      // non-initial). pumpEventQueue is more robust than a single
      // Future.delayed(zero) — survives changes to the number of
      // microtask hops inside _runCheck.
      await pumpEventQueue();
      expect(monitor.currentState, isNot(ConnectionHealthState.initial));
      await monitor.dispose();

      final events = <ConnectionHealthState>[];
      var done = false;
      monitor.stream.listen(events.add, onDone: () => done = true);
      await pumpEventQueue();
      expect(events, isEmpty, reason: 'no phantom replay after dispose');
      expect(done, isTrue, reason: 'late subscriber gets onDone');
    });

    // -------------------------------------------------------------------
    // 18: invalid baseUrl throws ArgumentError at construction.
    // -------------------------------------------------------------------
    test('18: invalid baseUrl throws ArgumentError', () {
      expect(
        () => ConnectionHealthMonitor(baseUrl: 'not a url'),
        throwsArgumentError,
      );
      expect(
        () => ConnectionHealthMonitor(baseUrl: 'ftp://example.com'),
        throwsArgumentError,
        reason: 'non-http(s) scheme rejected',
      );
      expect(
        () => ConnectionHealthMonitor(baseUrl: '//example.com'),
        throwsArgumentError,
        reason: 'missing scheme rejected',
      );
      expect(
        () => ConnectionHealthMonitor(baseUrl: 'http://'),
        throwsArgumentError,
        reason: 'empty host rejected',
      );
      expect(
        () => ConnectionHealthMonitor(baseUrl: 'https://api.example.com?k=v'),
        throwsArgumentError,
        reason: 'query string on baseUrl rejected',
      );
      expect(
        () => ConnectionHealthMonitor(baseUrl: 'https://api.example.com?'),
        throwsArgumentError,
        reason: 'empty query marker on baseUrl rejected',
      );
      expect(
        () => ConnectionHealthMonitor(baseUrl: 'https://api.example.com#frag'),
        throwsArgumentError,
        reason: 'fragment on baseUrl rejected',
      );
      expect(
        () => ConnectionHealthMonitor(baseUrl: 'https://api.example.com#'),
        throwsArgumentError,
        reason: 'empty fragment marker on baseUrl rejected',
      );
    });

    // -------------------------------------------------------------------
    // 19: multiple trailing slashes on baseUrl all collapse cleanly.
    // -------------------------------------------------------------------
    test('19: baseUrl with N trailing slashes produces no // in URL', () {
      fakeAsync((async) {
        Uri? capturedUrl;
        final monitor = _build(
          baseUrl: 'https://api.example.com///',
          healthPath: '/health',
          httpClient: MockClient((req) async {
            capturedUrl = req.url;
            return http.Response('ok', 200);
          }),
          internetChecker: _FakeInternetConnection(online: true),
        );
        monitor.start();
        async.flushMicrotasks();
        expect(capturedUrl?.toString(), 'https://api.example.com/health');
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 15: Late subscriber replay — a listener that subscribes AFTER the
    // first check completes is immediately replayed `currentState`.
    // (Closes the CLAUDE.md §5 late-subscriber-replay gap.)
    // -------------------------------------------------------------------
    test('15: late subscriber receives currentState replay', () {
      fakeAsync((async) {
        final monitor = _build(
          httpClient: MockClient((_) async => http.Response('ok', 200)),
          internetChecker: _FakeInternetConnection(online: true),
        );
        monitor.start();
        async.flushMicrotasks();
        // First check has now completed; currentState == healthy.
        expect(monitor.currentState, ConnectionHealthState.healthy);

        // Subscribe LATE — must immediately receive `healthy` without
        // waiting for the next interval.
        final late = <ConnectionHealthState>[];
        monitor.stream.listen(late.add);
        async.flushMicrotasks();
        expect(late, [ConnectionHealthState.healthy]);
        monitor.dispose();
      });
    });

    test('15b: late subscriber gets NO replay before any check completes', () {
      fakeAsync((async) {
        // Use a Completer to keep the first check pending indefinitely.
        final never = Completer<http.Response>();
        final monitor = _build(
          httpClient: MockClient((_) => never.future),
          internetChecker: _FakeInternetConnection(online: true),
        );
        monitor.start();
        async.flushMicrotasks();
        // currentState is still `initial`.
        expect(monitor.currentState, ConnectionHealthState.initial);

        final late = <ConnectionHealthState>[];
        monitor.stream.listen(late.add);
        async.flushMicrotasks();
        expect(late, isEmpty, reason: 'initial sentinel must NOT be replayed');
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 16: start/stop/start race — a stale in-flight check must NOT cause
    // a second concurrent loop. The generation counter handles this.
    // -------------------------------------------------------------------
    test('16: stop() then start() during in-flight check — no double loop', () {
      fakeAsync((async) {
        var hits = 0;
        // Driver completer for the first check; we hold it open while we
        // toggle stop → start, then complete it. After completion the
        // stale iteration must bail out (generation mismatch), so the
        // total hit count must NOT double.
        Completer<http.Response>? firstCheckGate = Completer();
        final monitor = _build(
          httpClient: MockClient((_) async {
            hits++;
            if (firstCheckGate != null && !firstCheckGate!.isCompleted) {
              final gate = firstCheckGate;
              firstCheckGate = null;
              return gate!.future;
            }
            return http.Response('ok', 200);
          }),
          internetChecker: _FakeInternetConnection(online: true),
          healthyInterval: const Duration(seconds: 10),
        );

        monitor.start();
        async.flushMicrotasks();
        expect(hits, 1, reason: 'first check fired');

        // Toggle stop → start while the first check is still mid-await.
        monitor.stop();
        monitor.start();
        async.flushMicrotasks();
        // The new start spawned a fresh check immediately. The old check
        // is still gated on the completer.
        expect(hits, 2);

        // Resolve the stale check. Its post-await guard MUST see the
        // generation mismatch and bail — no third hit fires from a
        // stale reschedule.
        firstCheckGate?.complete(http.Response('ok', 200));
        async.flushMicrotasks();

        // Elapse just enough for the FRESH timer (healthyInterval = 10s)
        // to fire once. If the stale loop had rescheduled, we'd see
        // hits > 3 inside this window.
        async.elapse(const Duration(seconds: 11));
        async.flushMicrotasks();
        expect(
          hits,
          3,
          reason: 'exactly one fresh-loop reschedule; stale loop bailed',
        );
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 20: server timeout AND internet down → internetDisconnected.
    // (Test 3 only covered timeout WITH internet up; this exercises the
    // timeout → disambiguation → offline path, plus the in-probe
    // send timeout.)
    // -------------------------------------------------------------------
    test('20: server timeout + internet down → internetDisconnected', () {
      fakeAsync((async) {
        final emissions = <ConnectionHealthState>[];
        final never = Completer<http.Response>();
        final monitor = _build(
          httpClient: MockClient((_) => never.future),
          internetChecker: _FakeInternetConnection(online: false),
          requestTimeout: const Duration(seconds: 3),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();
        async.elapse(const Duration(seconds: 4));
        async.flushMicrotasks();
        expect(emissions, [ConnectionHealthState.internetDisconnected]);
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 21: dispose() DURING an in-flight probe — the post-await guard in
    // _loop must bail: no emission, no throw when the probe later resolves.
    // -------------------------------------------------------------------
    test('21: dispose() during in-flight probe — no emit, no throw', () {
      fakeAsync((async) {
        final emissions = <ConnectionHealthState>[];
        final gate = Completer<http.Response>();
        final monitor = _build(
          httpClient: MockClient((_) => gate.future),
          internetChecker: _FakeInternetConnection(online: true),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();
        async.flushMicrotasks();
        // First probe is gated (in flight). Tear down now.
        monitor.dispose();
        async.flushMicrotasks();
        // Resolve the probe AFTER dispose — the loop's post-await guard
        // must drop it silently.
        gate.complete(http.Response('ok', 200));
        async.flushMicrotasks();
        expect(emissions, isEmpty, reason: 'no emission after dispose');
      });
    });

    // -------------------------------------------------------------------
    // 22: checkNow() BEFORE start() — probes once, updates currentState,
    // and does NOT schedule a loop (nothing running to reschedule).
    // -------------------------------------------------------------------
    test('22: checkNow() before start() probes without scheduling', () {
      fakeAsync((async) {
        var hits = 0;
        final emissions = <ConnectionHealthState>[];
        final monitor = _build(
          httpClient: MockClient((_) async {
            hits++;
            return http.Response('ok', 200);
          }),
          internetChecker: _FakeInternetConnection(online: true),
          healthyInterval: const Duration(seconds: 10),
        );
        monitor.stream.listen(emissions.add);

        ConnectionHealthState? probed;
        monitor.checkNow().then((s) => probed = s);
        async.flushMicrotasks();
        expect(probed, ConnectionHealthState.healthy);
        expect(hits, 1);
        expect(emissions, isEmpty, reason: 'checkNow never emits');
        expect(monitor.currentState, ConnectionHealthState.healthy);

        // No loop was scheduled (monitor never started).
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(hits, 1, reason: 'no scheduled loop without start()');
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 23: a state-changing checkNow() moves currentState ahead of the
    // de-dupe baseline; a late subscriber must still receive the value
    // only ONCE (per-subscriber de-dupe), not a duplicate when the next
    // loop tick re-emits it.
    // -------------------------------------------------------------------
    test('23: no duplicate to late subscriber after state-changing checkNow',
        () {
      fakeAsync((async) {
        var statusCode = 200;
        final existing = <ConnectionHealthState>[];
        final monitor = _build(
          httpClient: MockClient((_) async => http.Response('', statusCode)),
          internetChecker: _FakeInternetConnection(online: true),
          healthyInterval: const Duration(seconds: 10),
          retryInterval: const Duration(seconds: 5),
        );
        monitor.stream.listen(existing.add);
        monitor.start();
        async.flushMicrotasks();
        expect(existing, [ConnectionHealthState.healthy]);

        // Silent checkNow moves currentState → serverUnreachable without
        // emitting; _lastState (de-dupe baseline) stays healthy.
        statusCode = 500;
        monitor.checkNow();
        async.flushMicrotasks();
        expect(monitor.currentState, ConnectionHealthState.serverUnreachable);
        expect(existing, [ConnectionHealthState.healthy]);

        // Late subscriber mounts on the divergence and replays the fresh
        // currentState once.
        final late = <ConnectionHealthState>[];
        monitor.stream.listen(late.add);
        async.flushMicrotasks();
        expect(late, [ConnectionHealthState.serverUnreachable]);

        // Next loop tick (retryInterval) re-observes serverUnreachable and
        // broadcasts it to all subscribers.
        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();
        expect(existing, [
          ConnectionHealthState.healthy,
          ConnectionHealthState.serverUnreachable,
        ]);
        expect(
          late,
          [ConnectionHealthState.serverUnreachable],
          reason: 'per-subscriber de-dupe suppresses the repeat',
        );
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 24: jitterRatio outside [0, 1) is rejected by the constructor assert.
    // -------------------------------------------------------------------
    test('24: jitterRatio outside [0, 1) throws AssertionError', () {
      expect(
        () => ConnectionHealthMonitor(
          baseUrl: 'https://api.example.com',
          jitterRatio: 1.0,
        ),
        throwsA(isA<AssertionError>()),
        reason: 'jitterRatio >= 1 lets negative jitter clamp delay to 0',
      );
      expect(
        () => ConnectionHealthMonitor(
          baseUrl: 'https://api.example.com',
          jitterRatio: -0.1,
        ),
        throwsA(isA<AssertionError>()),
        reason: 'jitterRatio must be >= 0',
      );
    });

    // -------------------------------------------------------------------
    // 25: dispose() must NOT dispose an INJECTED internet checker (only a
    // checker the monitor created itself is owned).
    // -------------------------------------------------------------------
    test('25: dispose() leaves an injected internet checker untouched',
        () async {
      final checker = _FakeInternetConnection(online: true);
      final monitor = ConnectionHealthMonitor(
        baseUrl: 'https://api.example.com',
        httpClient: MockClient((_) async => http.Response('ok', 200)),
        internetChecker: checker,
      );
      await monitor.dispose();
      expect(
        checker.disposed,
        isFalse,
        reason: 'injected checker is owned by the caller, never disposed here',
      );
    });
  });
}
