// Behavioral suite for `ConnectionHealthMonitor`: states, lifecycle,
// jitter, and URL normalization. Injects `MockClient`, a
// `_FakeInternetConnection`, and a seeded `Random` under `fake_async` — no
// test touches the real network or wall clock.

import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:neo_connection_health/neo_connection_health.dart';
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
  // Defaults to half the (possibly overridden) requestTimeout rather than a
  // fixed 3s, so a test that shortens requestTimeout below 3s does not trip
  // the `slowThreshold < requestTimeout` assert.
  Duration? slowThreshold,
  int downConfirmationCount = 1,
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
    slowThreshold: slowThreshold ??
        Duration(microseconds: requestTimeout.inMicroseconds ~/ 2),
    downConfirmationCount: downConfirmationCount,
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
        expect(
            emissions,
            [
              ConnectionHealthState.healthy,
            ],
            reason: 'checkNow must NEVER emit on stream');
        // The probe result reaches the caller and nowhere else:
        // currentState is what the STREAM last carried, so a pure probe
        // must not move it either. Otherwise a late subscriber gets
        // replayed a value no subscriber was ever sent, and the next loop
        // tick sees "no change" and never reconciles them.
        expect(
          monitor.currentState,
          ConnectionHealthState.healthy,
          reason: 'checkNow must not move currentState past the stream',
        );
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
    // 22: checkNow() BEFORE start() — probes once, reports only through
    // its return value, and does NOT schedule a loop (nothing running to
    // reschedule).
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
        expect(
          monitor.currentState,
          ConnectionHealthState.initial,
          reason: 'nothing emitted yet, so nothing to report',
        );

        // No loop was scheduled (monitor never started).
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(hits, 1, reason: 'no scheduled loop without start()');
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 23: a state-changing checkNow() must NOT move currentState ahead of
    // the stream. Regression guard: while it did, a late subscriber was
    // replayed a state no subscriber had ever been sent, and the next loop
    // tick saw "no change" — so the two never reconciled. Fixing that made
    // the old per-subscriber replay de-dupe unnecessary; this test now
    // proves the divergence itself cannot occur.
    // -------------------------------------------------------------------
    test('23: checkNow() cannot move currentState ahead of the stream', () {
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

        statusCode = 500;
        monitor.checkNow();
        async.flushMicrotasks();
        expect(
          monitor.currentState,
          ConnectionHealthState.healthy,
          reason: 'the probe result belongs to the caller, not to the state',
        );
        expect(existing, [ConnectionHealthState.healthy]);

        // A subscriber arriving in that window is replayed the emitted
        // state, not the private probe result.
        final late = <ConnectionHealthState>[];
        monitor.stream.listen(late.add);
        async.flushMicrotasks();
        expect(late, [ConnectionHealthState.healthy]);

        // The next scheduled tick observes the same failure and emits it
        // once, to everyone.
        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();
        expect(existing, [
          ConnectionHealthState.healthy,
          ConnectionHealthState.serverUnreachable,
        ]);
        expect(late, [
          ConnectionHealthState.healthy,
          ConnectionHealthState.serverUnreachable,
        ]);
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

    // -------------------------------------------------------------------
    // 26: a 2xx that takes longer than slowThreshold → weakNetwork, and it
    // is polled at healthyInterval (NOT retryInterval): the probe
    // succeeded, so there is no outage to recover from, and the fast
    // cadence would burn ~1440 requests/day on the connections least able
    // to spare them.
    // -------------------------------------------------------------------
    test('26: slow 200 → weakNetwork, next check at healthyInterval', () {
      fakeAsync((async) {
        var hits = 0;
        final emissions = <ConnectionHealthState>[];
        final monitor = _build(
          httpClient: MockClient((_) async {
            hits++;
            await Future<void>.delayed(const Duration(seconds: 4));
            return http.Response('ok', 200);
          }),
          internetChecker: _FakeInternetConnection(online: true),
          slowThreshold: const Duration(seconds: 3),
          requestTimeout: const Duration(seconds: 8),
          healthyInterval: const Duration(minutes: 5),
          retryInterval: const Duration(minutes: 1),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();

        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(emissions, [ConnectionHealthState.weakNetwork]);
        expect(hits, 1);

        // healthyInterval (5 min) governs, not retryInterval (1 min). The
        // delay is measured from the check's COMPLETION (t=4s), so the next
        // probe lands at t=304s — we are at t=5s here.
        async.elapse(const Duration(minutes: 1));
        async.flushMicrotasks();
        expect(
          hits,
          1,
          reason: 'a retryInterval passing must NOT trigger a re-probe',
        );

        async.elapse(const Duration(minutes: 4, seconds: 5));
        async.flushMicrotasks();
        expect(hits, 2, reason: 'weakNetwork re-probes at healthyInterval');
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 27: a 2xx faster than slowThreshold stays healthy — the latency
    // branch must not hijack the happy path.
    // -------------------------------------------------------------------
    test('27: fast 200 → healthy, not weakNetwork', () {
      fakeAsync((async) {
        final emissions = <ConnectionHealthState>[];
        final monitor = _build(
          httpClient: MockClient((_) async {
            await Future<void>.delayed(const Duration(seconds: 1));
            return http.Response('ok', 200);
          }),
          internetChecker: _FakeInternetConnection(online: true),
          slowThreshold: const Duration(seconds: 3),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(emissions, [ConnectionHealthState.healthy]);
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 28: weakNetwork → healthy emits both (the new state participates in
    // de-dupe like any other).
    // -------------------------------------------------------------------
    test('28: weakNetwork → healthy emits both transitions', () {
      fakeAsync((async) {
        final emissions = <ConnectionHealthState>[];
        var latency = const Duration(seconds: 4);
        final monitor = _build(
          httpClient: MockClient((_) async {
            await Future<void>.delayed(latency);
            return http.Response('ok', 200);
          }),
          internetChecker: _FakeInternetConnection(online: true),
          slowThreshold: const Duration(seconds: 3),
          // weakNetwork reschedules on the healthy cadence, so this is the
          // interval that governs the re-probe below.
          healthyInterval: const Duration(seconds: 30),
        );
        monitor.stream.listen(emissions.add);
        monitor.start();

        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(emissions, [ConnectionHealthState.weakNetwork]);

        // Network recovers before the next scheduled probe.
        latency = const Duration(milliseconds: 100);
        async.elapse(const Duration(seconds: 31));
        async.flushMicrotasks();
        expect(emissions, [
          ConnectionHealthState.weakNetwork,
          ConnectionHealthState.healthy,
        ]);
        monitor.dispose();
      });
    });

    // -------------------------------------------------------------------
    // 29: slowThreshold outside (0, requestTimeout) is a misconfiguration
    // — at/above the timeout the probe aborts before it can be judged
    // slow, so weakNetwork would be unreachable. ArgumentError, not an
    // assert: it must fail in release too, where asserts are stripped.
    // -------------------------------------------------------------------
    test('29: slowThreshold outside (0, requestTimeout) throws', () {
      expect(
        () => ConnectionHealthMonitor(
          baseUrl: 'https://api.example.com',
          requestTimeout: const Duration(seconds: 8),
          slowThreshold: const Duration(seconds: 8),
        ),
        throwsA(isA<ArgumentError>()),
        reason: 'slowThreshold == requestTimeout makes weakNetwork dead code',
      );
      expect(
        () => ConnectionHealthMonitor(
          baseUrl: 'https://api.example.com',
          slowThreshold: Duration.zero,
        ),
        throwsA(isA<ArgumentError>()),
        reason: 'slowThreshold must be > 0',
      );
    });

    // -------------------------------------------------------------------
    // downConfirmationCount — a degraded state must be observed N times in
    // a row before it reaches the stream. Recovery is never delayed.
    // -------------------------------------------------------------------
    group('downConfirmationCount', () {
      /// Builds a monitor whose probe outcome is controlled by two mutable
      /// closures, so a single test can walk it through a sequence of
      /// different results.
      ({
        ConnectionHealthMonitor monitor,
        List<ConnectionHealthState> emissions,
        void Function(int status) setStatus,
        void Function({required bool online}) setOnline,
        int Function() hits,
      }) harness({
        int downConfirmationCount = 2,
        Duration retryInterval = const Duration(seconds: 30),
        Duration healthyInterval = const Duration(minutes: 5),
      }) {
        var status = 500;
        var hitCount = 0;
        final checker = _FakeInternetConnection(online: false);
        final emissions = <ConnectionHealthState>[];
        final monitor = _build(
          httpClient: MockClient((_) async {
            hitCount++;
            return http.Response('', status);
          }),
          internetChecker: checker,
          downConfirmationCount: downConfirmationCount,
          retryInterval: retryInterval,
          healthyInterval: healthyInterval,
        );
        monitor.stream.listen(emissions.add);
        return (
          monitor: monitor,
          emissions: emissions,
          setStatus: (s) => status = s,
          setOnline: ({required bool online}) => checker.online = online,
          hits: () => hitCount,
        );
      }

      test('30: first bad probe is silent, second identical one emits', () {
        fakeAsync((async) {
          final h = harness();
          h.monitor.start();
          async.flushMicrotasks();
          expect(h.emissions, isEmpty, reason: 'one blip must not alarm');

          async.elapse(const Duration(seconds: 31));
          async.flushMicrotasks();
          expect(h.emissions, [ConnectionHealthState.internetDisconnected]);
          h.monitor.dispose();
        });
      });

      test('31: a healthy probe between two bad ones resets the streak', () {
        fakeAsync((async) {
          final h = harness();
          h.monitor.start();
          async.flushMicrotasks();
          expect(h.emissions, isEmpty);

          // Recovers before confirmation, then fails again once.
          h.setStatus(200);
          async.elapse(const Duration(seconds: 31));
          async.flushMicrotasks();
          expect(h.emissions, [ConnectionHealthState.healthy]);

          // Land exactly ONE bad probe: the post-healthy check is scheduled
          // a healthyInterval out, and a second would follow a retryInterval
          // later and legitimately confirm. Stop in between.
          h.setStatus(500);
          async.elapse(const Duration(minutes: 5, seconds: 5));
          async.flushMicrotasks();
          expect(
            h.emissions,
            [ConnectionHealthState.healthy],
            reason: 'the streak restarted, so one bad probe is unconfirmed',
          );
          h.monitor.dispose();
        });
      });

      // 32: alternating failure modes must still report SOMETHING. Under a
      // purely per-state run they never build a matching streak, so nothing
      // was ever emitted — the app looked perfectly healthy while every
      // request failed, and it never self-corrected. Rule 2 (N consecutive
      // failures of ANY kind, while nothing degraded is on screen yet)
      // closes that hole. Matches how Kubernetes failureThreshold, gRPC and
      // Resilience4j count failure: generically, not per sub-type.
      test('32: alternating bad states still confirm from a cold start', () {
        fakeAsync((async) {
          final h = harness();
          h.monitor.start();
          async.flushMicrotasks(); // probe 1 -> internetDisconnected
          expect(h.emissions, isEmpty, reason: 'one failure is still a blip');

          // Same failing server, but the internet probe now succeeds, so
          // this reads as serverUnreachable rather than a repeat.
          h.setOnline(online: true);
          async.elapse(const Duration(seconds: 31));
          async.flushMicrotasks(); // probe 2 -> serverUnreachable

          expect(
            h.emissions,
            [ConnectionHealthState.serverUnreachable],
            reason: 'two failures running is proof enough that we are down, '
                'even without agreement on which kind',
          );
          h.monitor.dispose();
        });
      });

      // 32b: the other half of the contract. Once a degraded state IS on
      // screen, rule 2 switches off and the per-state run governs the
      // label — otherwise every alternating probe would pass the gate and
      // the banner would swap its advice ("check your WiFi" / "our servers
      // are down") once a minute, which is worse than holding one answer.
      test('32b: an established banner does not flap between failure modes',
          () {
        fakeAsync((async) {
          final h = harness();
          h.monitor.start();
          async.flushMicrotasks(); // 1 -> internetDisconnected
          h.setOnline(online: true);
          async.elapse(const Duration(seconds: 31));
          async.flushMicrotasks(); // 2 -> serverUnreachable, emits
          expect(h.emissions, [ConnectionHealthState.serverUnreachable]);

          // Alternate for several more probes. None may emit: no state
          // manages two in a row, and the banner is no longer empty.
          for (var i = 0; i < 4; i++) {
            h.setOnline(online: i.isOdd);
            async.elapse(const Duration(seconds: 31));
            async.flushMicrotasks();
          }
          expect(
            h.emissions,
            [ConnectionHealthState.serverUnreachable],
            reason: 'the label holds until a different one earns its own run',
          );

          // A genuine consecutive pair of the other kind DOES take over.
          h.setOnline(online: false);
          async.elapse(const Duration(seconds: 31));
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 31));
          async.flushMicrotasks();
          expect(h.emissions, [
            ConnectionHealthState.serverUnreachable,
            ConnectionHealthState.internetDisconnected,
          ]);
          h.monitor.dispose();
        });
      });

      test('33: each state confirms on its own run', () {
        fakeAsync((async) {
          final h = harness();
          h.monitor.start();
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 31));
          async.flushMicrotasks();
          expect(h.emissions, [ConnectionHealthState.internetDisconnected]);

          h.setOnline(online: true);
          async.elapse(const Duration(seconds: 31)); // restarts the run
          async.flushMicrotasks();
          expect(h.emissions, [ConnectionHealthState.internetDisconnected]);

          async.elapse(const Duration(seconds: 31)); // confirms it
          async.flushMicrotasks();
          expect(h.emissions, [
            ConnectionHealthState.internetDisconnected,
            ConnectionHealthState.serverUnreachable,
          ]);
          h.monitor.dispose();
        });
      });

      test('34: recovery emits on the FIRST healthy probe, never delayed', () {
        fakeAsync((async) {
          final h = harness();
          h.monitor.start();
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 31));
          async.flushMicrotasks();
          expect(h.emissions, [ConnectionHealthState.internetDisconnected]);

          h.setStatus(200);
          async.elapse(const Duration(seconds: 31));
          async.flushMicrotasks();
          expect(
            h.emissions,
            [
              ConnectionHealthState.internetDisconnected,
              ConnectionHealthState.healthy,
            ],
            reason: 'slow to alarm, fast to reassure',
          );
          h.monitor.dispose();
        });
      });

      test('35: weakNetwork is confirmed on the same rule', () {
        fakeAsync((async) {
          final emissions = <ConnectionHealthState>[];
          final monitor = _build(
            httpClient: MockClient((_) async {
              await Future<void>.delayed(const Duration(seconds: 4));
              return http.Response('ok', 200);
            }),
            internetChecker: _FakeInternetConnection(online: true),
            slowThreshold: const Duration(seconds: 3),
            downConfirmationCount: 2,
            // weakNetwork reschedules on the HEALTHY cadence (the probe
            // succeeded), so confirmation of a slow link arrives one
            // healthyInterval later — not one retryInterval.
            healthyInterval: const Duration(seconds: 30),
          );
          monitor.stream.listen(emissions.add);
          monitor.start();

          async.elapse(const Duration(seconds: 5));
          async.flushMicrotasks();
          expect(emissions, isEmpty, reason: 'one slow response is not proof');

          async.elapse(const Duration(seconds: 35));
          async.flushMicrotasks();
          expect(emissions, [ConnectionHealthState.weakNetwork]);
          monitor.dispose();
        });
      });

      test('36: currentState never reports an unconfirmed state', () {
        fakeAsync((async) {
          final h = harness();
          h.monitor.start();
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 31));
          async.flushMicrotasks();
          expect(h.monitor.currentState,
              ConnectionHealthState.internetDisconnected);

          // One serverUnreachable — unconfirmed, so the reported state must
          // not move. A late subscriber is replayed currentState, and must
          // never receive a value the stream itself never emitted.
          h.setOnline(online: true);
          async.elapse(const Duration(seconds: 31));
          async.flushMicrotasks();
          expect(
            h.monitor.currentState,
            ConnectionHealthState.internetDisconnected,
            reason: 'currentState must stay consistent with the stream',
          );

          final late = <ConnectionHealthState>[];
          h.monitor.stream.listen(late.add);
          async.flushMicrotasks();
          expect(late, [ConnectionHealthState.internetDisconnected]);
          h.monitor.dispose();
        });
      });

      test('37: an unconfirmed bad probe retries on the FAST cadence', () {
        fakeAsync((async) {
          final h = harness(
            retryInterval: const Duration(minutes: 1),
            healthyInterval: const Duration(minutes: 5),
          );
          h.monitor.start();
          async.flushMicrotasks();
          expect(h.hits(), 1);

          // Scheduling keys off the RAW probe result, not the confirmed
          // one, so confirmation arrives a retryInterval later rather than
          // waiting out healthyInterval.
          async.elapse(const Duration(minutes: 1, seconds: 1));
          async.flushMicrotasks();
          expect(h.hits(), 2);
          expect(h.emissions, [ConnectionHealthState.internetDisconnected]);
          h.monitor.dispose();
        });
      });

      test('38: downConfirmationCount below 1 asserts', () {
        expect(
          () => ConnectionHealthMonitor(
            baseUrl: 'https://api.example.com',
            downConfirmationCount: 0,
          ),
          throwsA(isA<AssertionError>()),
          reason: '0 would mean a state is never confirmed',
        );
      });

      // -----------------------------------------------------------------
      // 39: stop() discards a partial confirmation run. Two observations
      // either side of a pause are not consecutive in any useful sense,
      // and stop()/start() on background/foreground is the pattern this
      // package itself recommends — so without the reset, every
      // backgrounded app would confirm on a probe from hours ago.
      // -----------------------------------------------------------------
      test('39: stop() resets the confirmation streak', () {
        fakeAsync((async) {
          final h = harness();
          h.monitor.start();
          async.flushMicrotasks();
          expect(h.emissions, isEmpty, reason: '1 of 2 — not yet confirmed');

          h.monitor.stop();
          async.elapse(const Duration(hours: 3));
          h.monitor.start();
          async.flushMicrotasks();

          expect(
            h.emissions,
            isEmpty,
            reason: 'the pre-pause probe must not count toward the run',
          );

          // A second post-resume observation is a genuine consecutive pair.
          async.elapse(const Duration(seconds: 31));
          async.flushMicrotasks();
          expect(h.emissions, [ConnectionHealthState.internetDisconnected]);
          h.monitor.dispose();
        });
      });

      // -----------------------------------------------------------------
      // 40: the slowThreshold comparison is `>`, so a probe landing on the
      // threshold exactly is healthy, not weakNetwork. Pins the boundary
      // so a later `>=` typo cannot slip through silently.
      // -----------------------------------------------------------------
      test('40: a probe exactly at slowThreshold is healthy', () {
        fakeAsync((async) {
          final emissions = <ConnectionHealthState>[];
          final monitor = _build(
            httpClient: MockClient((_) async {
              await Future<void>.delayed(const Duration(seconds: 3));
              return http.Response('ok', 200);
            }),
            internetChecker: _FakeInternetConnection(online: true),
            slowThreshold: const Duration(seconds: 3),
          );
          monitor.stream.listen(emissions.add);
          monitor.start();

          async.elapse(const Duration(seconds: 4));
          async.flushMicrotasks();
          expect(
            emissions,
            [ConnectionHealthState.healthy],
            reason: 'the threshold is exclusive — equal is not yet slow',
          );
          monitor.dispose();
        });
      });

      /// Like [harness], but the probe's LATENCY is mutable too, so one test
      /// can walk a monitor from a slow-but-successful probe (`weakNetwork`)
      /// into outright failures. Both intervals are 30 s so the cadence
      /// difference between an answered and a failed probe does not have to
      /// be tracked per step.
      ({
        ConnectionHealthMonitor monitor,
        List<ConnectionHealthState> emissions,
        void Function(Duration d) setDelay,
        void Function(int status) setStatus,
        void Function({required bool online}) setOnline,
      }) gateHarness() {
        var delay = Duration.zero;
        var status = 200;
        final checker = _FakeInternetConnection(online: true);
        final emissions = <ConnectionHealthState>[];
        final monitor = _build(
          httpClient: MockClient((_) async {
            if (delay > Duration.zero) {
              await Future<void>.delayed(delay);
            }
            return http.Response('', status);
          }),
          internetChecker: checker,
          slowThreshold: const Duration(seconds: 3),
          downConfirmationCount: 2,
          healthyInterval: const Duration(seconds: 30),
          retryInterval: const Duration(seconds: 30),
        );
        monitor.stream.listen(emissions.add);
        return (
          monitor: monitor,
          emissions: emissions,
          setDelay: (d) => delay = d,
          setStatus: (s) => status = s,
          setOnline: ({required bool online}) => checker.online = online,
        );
      }

      test(
          '41: weakNetwork does not disarm rule 2 — alternating failures '
          'still confirm', () {
        fakeAsync((async) {
          final h = gateHarness()..setDelay(const Duration(seconds: 4));
          h.monitor.start();

          // Two slow-but-successful probes confirm weakNetwork (rule 1).
          async.elapse(const Duration(seconds: 5));
          async.flushMicrotasks();
          expect(h.emissions, isEmpty,
              reason: 'one slow response is not proof');
          async.elapse(const Duration(seconds: 35));
          async.flushMicrotasks();
          expect(h.emissions, [ConnectionHealthState.weakNetwork]);

          // Now the link degrades into ALTERNATING failure modes. Rule 1 can
          // never fire (no state twice in a row), so the only route out is
          // rule 2 — which stays armed only because weakNetwork is exempt
          // from `reportingDegraded`.
          h
            ..setDelay(Duration.zero)
            ..setStatus(500)
            ..setOnline(online: false);
          async.elapse(const Duration(seconds: 30));
          async.flushMicrotasks();
          expect(
            h.emissions,
            [ConnectionHealthState.weakNetwork],
            reason: 'one failure is still just a blip',
          );

          h.setOnline(online: true);
          async.elapse(const Duration(seconds: 30));
          async.flushMicrotasks();
          expect(
            h.emissions,
            [
              ConnectionHealthState.weakNetwork,
              ConnectionHealthState.serverUnreachable,
            ],
            reason: 'without the weakNetwork exemption this confirms NOTHING, '
                'forever — a reassuring banner on a fully offline device',
          );
          h.monitor.dispose();
        });
      });

      test('42: leaving a rule-1 weakNetwork still needs a full run', () {
        fakeAsync((async) {
          final h = gateHarness()..setDelay(const Duration(seconds: 4));
          h.monitor.start();

          async.elapse(const Duration(seconds: 5));
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 35));
          async.flushMicrotasks();
          expect(h.emissions, [ConnectionHealthState.weakNetwork]);

          // Confirming weakNetwork left _degradedRun at threshold unless it
          // was cleared. If it was not, rule 2 fires on this SINGLE failure.
          h
            ..setDelay(Duration.zero)
            ..setStatus(500)
            ..setOnline(online: false);
          async.elapse(const Duration(seconds: 30));
          async.flushMicrotasks();
          expect(
            h.emissions,
            [ConnectionHealthState.weakNetwork],
            reason: 'blip protection must survive the rule-2 rearm',
          );
          h.monitor.dispose();
        });
      });

      test('43: leaving a rule-2 weakNetwork still needs a full run', () {
        fakeAsync((async) {
          // weakNetwork reached through rule 2 rather than rule 1: one
          // failure, then one slow success, from a cold start. No other test
          // takes this route, and a fix applied to rule 1's exit alone
          // leaves _degradedRun primed here.
          final h = gateHarness()..setStatus(500);
          h.monitor.start();
          async.flushMicrotasks();
          expect(h.emissions, isEmpty, reason: 'one failure is not proof');

          h
            ..setDelay(const Duration(seconds: 4))
            ..setStatus(200);
          async.elapse(const Duration(seconds: 35));
          async.flushMicrotasks();
          expect(
            h.emissions,
            [ConnectionHealthState.weakNetwork],
            reason: 'serverUnreachable then a slow 200 is two degraded '
                'observations of any kind — rule 2 confirms the second',
          );

          h
            ..setDelay(Duration.zero)
            ..setStatus(500)
            ..setOnline(online: false);
          async.elapse(const Duration(seconds: 31));
          async.flushMicrotasks();
          expect(
            h.emissions,
            [ConnectionHealthState.weakNetwork],
            reason: 'the _degradedRun reset must apply to rule 2\'s exit too, '
                'not only rule 1\'s',
          );
          h.monitor.dispose();
        });
      });

      test('44: an UNCONFIRMED weakNetwork does not prime the failure run', () {
        fakeAsync((async) {
          // Tests 42 and 43 both drive weakNetwork to CONFIRMATION before
          // failing, so both enter the failure step with the run already
          // cleared. That is why they cannot see this: a weakNetwork that
          // never emits still incremented the generic failure run, and with
          // nothing on screen rule 2 is armed — so a single failure would
          // confirm on one observation.
          final h = gateHarness()..setDelay(const Duration(seconds: 4));
          h.monitor.start();
          async.elapse(const Duration(seconds: 5));
          async.flushMicrotasks();
          expect(h.emissions, isEmpty, reason: 'one slow probe is unconfirmed');

          h
            ..setDelay(Duration.zero)
            ..setStatus(500);
          async.elapse(const Duration(seconds: 31));
          async.flushMicrotasks();
          expect(
            h.emissions,
            isEmpty,
            reason: 'one slow success plus ONE failure is not two failures — '
                'a single failure must never confirm',
          );
          h.monitor.dispose();
        });
      });
    });
  });
}
