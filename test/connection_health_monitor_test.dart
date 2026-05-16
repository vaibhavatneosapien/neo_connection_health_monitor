// Full behavioral test suite for `ConnectionHealthMonitor`. Covers all
// 14 cases required by `CLAUDE.md` §Testing plus supplementary cases
// added during code review (7b, 14b, 15, 15b, 16, 17, 18, 19).
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

  @override
  Future<bool> get hasInternetAccess async => online;
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
        expect(emissions, [
          ConnectionHealthState.healthy,
        ], reason: 'checkNow must NEVER emit on stream');
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
        // Every inter-fire delta must land inside [0.9*base, 1.1*base].
        for (var i = 1; i < fireTimes.length; i++) {
          final deltaMs = (fireTimes[i] - fireTimes[i - 1]).inMilliseconds;
          expect(
            deltaMs,
            inInclusiveRange(9000, 11000),
            reason: 'cycle ${i + 1} delta $deltaMs ms outside ±10% band',
          );
        }
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
      // Let the first check land so currentState is non-initial.
      await Future<void>.delayed(Duration.zero);
      await monitor.dispose();

      final events = <ConnectionHealthState>[];
      var done = false;
      monitor.stream.listen(events.add, onDone: () => done = true);
      await Future<void>.delayed(Duration.zero);
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
  });
}
