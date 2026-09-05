import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';

import 'connection_health_state.dart';

/// Monitors device internet connectivity AND a specific server's
/// reachability, exposing transitions via a broadcast [Stream].
///
/// Construct one instance at app startup, [start] it, and listen to
/// [stream]. The monitor performs a dual-tier check on an adaptive
/// schedule (every [healthyInterval] while the server answers, every
/// [retryInterval] while the probe fails, each with +/-[jitterRatio]
/// jitter to avoid synchronized thundering-herd load on the backend).
///
/// ## Caller responsibility - backgrounding
///
/// This is a pure-Dart package; it does NOT observe Flutter's app
/// lifecycle. The caller MUST call [stop] when the app is backgrounded
/// (`AppLifecycleState.paused` / `detached` / `hidden`) and call [start]
/// again on `resumed`. Do NOT stop on `inactive` — on iOS that fires
/// during transient foreground interruptions (control center, the app
/// switcher, Face ID / permission dialogs), and each resume would issue
/// a fresh immediate probe, thrashing requests. Failing to stop causes the
/// monitor to continue polling (every 1 minute in the unhealthy state)
/// while the app is backgrounded - visible battery drain and avoidable
/// HTTP traffic.
///
/// A copy-paste `WidgetsBindingObserver` snippet lives in the README.
class ConnectionHealthMonitor {
  /// Creates a monitor that probes `${baseUrl}${healthPath}` on an
  /// adaptive schedule and reports state transitions on [stream].
  ///
  /// - [baseUrl] - required. The API base URL, e.g.
  ///   `https://neo-backend-v2.dev-api.neosapien.xyz`. Any trailing `/`
  ///   is stripped at construction time.
  /// - [healthPath] - defaults to `/health`. A leading `/` is added if
  ///   missing. **Neosapien consumers must pass `/healthz`** - the
  ///   backend serves `/healthz` and has no `/health` route on any
  ///   environment. Since 0.4.0 a wrong path no longer surfaces: a `404` is a
  ///   server fault, and server faults with internet up now resolve to
  ///   `healthy` (server-down is firebase-owned), so a misconfigured path
  ///   fails **silent-green** rather than reporting `serverUnreachable`. The
  ///   default stays `/health` because it is the conventional choice for a
  ///   reusable package.
  /// - [healthyInterval] - delay between checks after the server
  ///   ANSWERED, i.e. `healthy` or `weakNetwork`. Default: 5 minutes.
  /// - [retryInterval] - delay between checks after the server probe
  ///   FAILED with no internet, i.e. `internetDisconnected` (the only
  ///   probe-reachable failure since `serverUnreachable` was retired in
  ///   0.4.0). Default: 1 minute.
  /// - [requestTimeout] - per-request timeout. Default: 8 seconds
  ///   (chosen over 5 s for 3G on tier-2 networks). It also bounds the
  ///   failure-path internet tiebreaker: a probe that runs past it throws
  ///   `TimeoutException` and is read as offline (`internetDisconnected`).
  ///   For that to mean "the link is dead" rather than "the link is slow",
  ///   `requestTimeout` MUST exceed the injected [internetChecker]'s own
  ///   per-endpoint timeout. The default checker
  ///   (`internet_connection_checker_plus`) probes its endpoints in parallel
  ///   at 3 s each and returns a clean `false` when all fail, so the 8 s
  ///   default clears it with headroom and the timeout branch fires only on a
  ///   genuinely hung link. If you inject a checker whose per-endpoint timeout
  ///   is >= `requestTimeout`, a slow-but-working link can be mislabelled
  ///   `internetDisconnected` - raise `requestTimeout` above it.
  /// - [slowThreshold] - a probe that SUCCEEDS but takes longer than
  ///   this reports [ConnectionHealthState.weakNetwork] instead of
  ///   `healthy`. Default: 3 seconds. Must be `> Duration.zero` and
  ///   `< requestTimeout` (throws [ArgumentError]): at or above the timeout
  ///   the probe
  ///   is aborted before it could ever be judged slow, leaving
  ///   `weakNetwork` unreachable.
  /// - [downConfirmationCount] - how many consecutive degraded probes are
  ///   required before the state is emitted. Default `1` (emit on first
  ///   observation - the historical behaviour, so existing consumers are
  ///   unaffected). Must be `>= 1` (asserted). Set `2`+ to stop a single
  ///   blip - a lift, a tunnel, one overloaded response - from putting an
  ///   error state in front of the user. Recovery to `healthy` is never
  ///   delayed by this. Two rules apply: N observations of the SAME state,
  ///   or N of ANY kind while nothing degraded is reported yet - see
  ///   [_isConfirmed] for why both are needed and why a link alternating
  ///   between two failure modes would otherwise report nothing at all.
  /// - [jitterRatio] - +/- random jitter fraction on each delay.
  ///   Default: 0.1 (+/-10%); pass `0.0` to disable. See the field for
  ///   the `[0, 1)` bound.
  /// - [httpClient] - optional injected client. If `null`, the monitor
  ///   creates its own [http.Client] and closes it on [dispose]. An
  ///   injected client is never closed by the monitor.
  /// - [internetChecker] - optional injected internet probe. Used only
  ///   as a tiebreaker when the server probe fails. If `null`, a
  ///   dedicated `InternetConnection.createInstance()` is created (NOT
  ///   the app-wide singleton — the package owns and disposes it), per
  ///   `internet_connection_checker_plus`'s guidance for third-party
  ///   packages. An injected checker is never disposed by the monitor.
  /// - [random] - optional source of randomness for jitter. Inject a
  ///   seeded `Random(42)` in tests; defaults to `Random()` in
  ///   production.
  ConnectionHealthMonitor({
    required String baseUrl,
    String healthPath = '/health',
    this.healthyInterval = const Duration(minutes: 5),
    this.retryInterval = const Duration(minutes: 1),
    this.requestTimeout = const Duration(seconds: 8),
    this.slowThreshold = const Duration(seconds: 3),
    this.downConfirmationCount = 1,
    this.jitterRatio = 0.1,
    http.Client? httpClient,
    InternetConnection? internetChecker,
    Random? random,
  })  : assert(
          jitterRatio >= 0 && jitterRatio < 1,
          'jitterRatio must be in [0, 1)',
        ),
        assert(
          downConfirmationCount >= 1,
          'downConfirmationCount must be >= 1',
        ),
        _ownsClient = httpClient == null,
        _ownsChecker = internetChecker == null,
        _httpClient = httpClient ?? http.Client(),
        _internetChecker =
            internetChecker ?? InternetConnection.createInstance(),
        _random = random ?? Random(),
        _uri = _composeUri(baseUrl, healthPath) {
    // ArgumentError, not `assert`: asserts are stripped in release, so a
    // consumer who raises `requestTimeout` (e.g. tuning for 3G) without
    // moving `slowThreshold` would silently lose `weakNetwork` entirely in
    // the shipped build while tests stayed green. Fails loud at construction
    // instead, matching [_composeUri]'s handling of a bad `baseUrl`.
    if (slowThreshold <= Duration.zero || slowThreshold >= requestTimeout) {
      throw ArgumentError.value(
        slowThreshold,
        'slowThreshold',
        'must be in (0, requestTimeout=$requestTimeout) — at or above the '
            'timeout the probe aborts before it can be judged slow, making '
            'weakNetwork unreachable',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Configuration (immutable after construction).
  // ---------------------------------------------------------------------------

  /// Delay between checks while the server is ANSWERING — `healthy` or
  /// `weakNetwork`. See [_nextDelay] for why slow-but-working shares the
  /// relaxed cadence.
  final Duration healthyInterval;

  /// Delay between checks while the server probe is FAILING —
  /// `internetDisconnected` (the only probe-reachable failure since
  /// `serverUnreachable` was retired in 0.4.0).
  final Duration retryInterval;

  /// Per-request timeout for the server `/health` probe.
  final Duration requestTimeout;

  /// Round-trip duration above which a SUCCESSFUL probe reports
  /// [ConnectionHealthState.weakNetwork] instead of `healthy`.
  final Duration slowThreshold;

  /// Consecutive identical degraded observations required before that
  /// state is emitted. `1` (default) preserves the historical
  /// emit-on-first-observation behaviour.
  final int downConfirmationCount;

  /// Fraction of the scheduled delay applied as +/- random jitter.
  /// `0.1` means +/-10%. Must be in `[0, 1)` (asserted at construction):
  /// a value `>= 1` lets negative jitter exceed the base delay, which the
  /// clamp floors to 0 -> immediate back-to-back re-probes.
  final double jitterRatio;

  // ---------------------------------------------------------------------------
  // Private state.
  // ---------------------------------------------------------------------------

  /// `true` if the monitor created [_httpClient] itself, so [dispose]
  /// closes it. An injected client is the caller's to close.
  final bool _ownsClient;

  /// `true` if the monitor created [_internetChecker] itself, so [dispose]
  /// disposes it. An injected checker is the caller's to dispose.
  final bool _ownsChecker;

  /// Pre-composed request URI. Built once at construction time so the
  /// hot path does not repeat URL parsing/normalization on every check.
  final Uri _uri;

  /// HTTP client used for the server probe. Either injected by the
  /// caller or created in the constructor (see [_ownsClient]).
  final http.Client _httpClient;

  /// Generic-internet probe used as a tiebreaker when the server check
  /// fails. Probes public CDN endpoints (Cloudflare, Apple captive,
  /// Google) - see `internet_connection_checker_plus` docs.
  final InternetConnection _internetChecker;

  /// Source of jitter randomness (seeded in tests).
  final Random _random;

  /// Broadcast controller for state transitions. Multiple subscribers
  /// are supported; emissions are de-duplicated against [_lastState].
  final StreamController<ConnectionHealthState> _controller =
      StreamController<ConnectionHealthState>.broadcast();

  /// `true` between [start] and [stop]. The loop checks this before
  /// emitting and before scheduling the next iteration; a pending check
  /// that completes after `stop()` must NOT emit or reschedule.
  bool _running = false;

  /// `true` after [dispose]. Every public method checks this first and
  /// throws [StateError] if set, to guarantee no late events fire from
  /// a disposed instance.
  bool _disposed = false;

  /// Handle for the next scheduled check. Stored so [stop] and
  /// [dispose] can cancel it cleanly.
  Timer? _pendingTimer;

  /// Monotonically increasing generation counter. Bumped on every [start]
  /// call. Loop iterations capture the generation at entry; if it changes
  /// (e.g. `stop()` → `start()` fires a fresh run while a prior check is
  /// still mid-await), the stale iteration bails out instead of emitting
  /// and rescheduling — preventing concurrent loops doubling the request
  /// rate.
  int _generation = 0;

  /// Last state emitted on [stream]. Doubles as the de-dupe baseline and
  /// as the value [currentState] returns, which is what keeps the two in
  /// lockstep: this field is assigned in exactly one place
  /// ([_emitIfChanged]), immediately before the matching
  /// `_controller.add`. Nothing else may write it — an ungated write is
  /// how `currentState` previously drifted to a value the stream had
  /// never carried, with no path back into agreement.
  ConnectionHealthState _currentState = ConnectionHealthState.initial;

  /// The degraded state currently being counted toward
  /// [downConfirmationCount], or `null` when the last observation was
  /// `healthy`. Keyed on the state itself so a switch between two
  /// different failures restarts the run — see [_isConfirmed].
  ConnectionHealthState? _streakState;

  /// How many consecutive times [_streakState] has been observed.
  int _streakCount = 0;

  /// How many consecutive FAILED observations of any kind have been seen.
  /// Distinct from [_streakCount], which restarts whenever the specific
  /// failure changes; this one does not. It is what lets a link that
  /// alternates between two failure modes still report SOMETHING — see the
  /// second rule in [_isConfirmed].
  ///
  /// `weakNetwork` does NOT count toward it and clears it on observation:
  /// the probe succeeded, so it is not a failure, and leaving it counted
  /// would let one slow probe plus one failure confirm on a single failing
  /// observation.
  int _degradedRun = 0;

  // ---------------------------------------------------------------------------
  // Public API.
  // ---------------------------------------------------------------------------

  /// Broadcast stream of state transitions. Multiple listeners are
  /// supported. Emissions are de-duplicated - the same state is never
  /// emitted twice in a row.
  ///
  /// **Replay semantics:** a new subscriber is immediately replayed
  /// [currentState] if at least one check has completed
  /// (i.e. `currentState != initial`). This lets a `StreamBuilder` that
  /// mounts AFTER the first check still receive the current state
  /// without waiting for the next transition. If no check has completed
  /// yet, no event is replayed — the next live emission will be the
  /// first one the subscriber sees.
  ///
  /// After [dispose], a new subscriber receives `onDone` immediately
  /// (no phantom replay).
  Stream<ConnectionHealthState> get stream => _stream;

  /// Backing broadcast-with-replay stream. Built once (not rebuilt on
  /// every `stream` access) so `StreamBuilder(stream: monitor.stream)`
  /// keeps a stable stream identity across widget rebuilds — otherwise
  /// each rebuild would tear down and re-subscribe. `Stream.multi` still
  /// re-runs the callback below per subscriber, so replay and
  /// per-subscriber de-dupe are unaffected.
  late final Stream<ConnectionHealthState> _stream =
      Stream<ConnectionHealthState>.multi((controller) {
    if (_disposed) {
      controller.close();
      return;
    }
    if (_currentState != ConnectionHealthState.initial) {
      controller.add(_currentState);
    }
    // No per-subscriber de-dupe needed: `_currentState` is written only in
    // `_emitIfChanged`, immediately before the matching `add`, so the value
    // replayed above is by construction the last one broadcast — and the
    // next broadcast is guaranteed to differ from it.
    final sub = _controller.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });

  /// The most recent state EMITTED on [stream], or
  /// [ConnectionHealthState.initial] if nothing has been emitted yet.
  ///
  /// This is never a raw probe result: an unconfirmed observation (see
  /// `downConfirmationCount`) and a [checkNow] result both leave it
  /// untouched. It reports what a subscriber has been told, so the two can
  /// never disagree.
  ///
  /// Warning: this returns `initial` between construction and the first
  /// completed check. Do NOT render UI from a synchronous read of this
  /// getter immediately after construction - subscribe to [stream] and
  /// react to the first emitted event instead. Synchronous reads are
  /// only useful for diagnostics / logging.
  ConnectionHealthState get currentState => _currentState;

  /// Begins (or resumes) the polling loop. The first check fires
  /// immediately, not after [healthyInterval], so consumers get a
  /// signal on app launch instead of 5 minutes later.
  ///
  /// Idempotent: a second call while already running is a no-op.
  /// Calling after [dispose] throws [StateError].
  void start() {
    _throwIfDisposed();
    if (_running) return;
    _running = true;
    // Invalidate any stale in-flight _loop from a prior start()/stop()
    // cycle (see [_generation]).
    final gen = ++_generation;
    unawaited(_loop(gen)); // fire-and-forget; the loop self-schedules
  }

  /// Pauses the polling loop without tearing down the monitor.
  ///
  /// Cancels the pending timer and clears the running flag; the [stream]
  /// controller stays open and an owned [http.Client] is NOT closed, so a
  /// subsequent [start] resumes cleanly. Call this when the app is
  /// backgrounded — not on `inactive` (see the class docs for the
  /// backgrounding contract). For shutdown, use [dispose].
  ///
  /// Any partial confirmation run (see [downConfirmationCount]) is
  /// discarded: observations either side of a pause are not consecutive in
  /// any meaningful sense, and the recommended background/foreground
  /// pattern would otherwise let a probe from hours ago confirm a state
  /// alongside one from just now.
  void stop() {
    _throwIfDisposed();
    _running = false;
    _pendingTimer?.cancel();
    _pendingTimer = null;
    // A run spans a pause only by accident; see the doc comment above.
    _streakState = null;
    _streakCount = 0;
    _degradedRun = 0;
  }

  /// Terminal cleanup. Cancels the pending timer, closes the broadcast
  /// stream controller, and closes the owned [http.Client] (only if the
  /// monitor created it - an injected client is left alone).
  ///
  /// After [dispose] returns, any public method call - including a
  /// second [dispose] - throws [StateError]. Use [stop] instead if you
  /// want to pause and resume.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _running = false;
    _pendingTimer?.cancel();
    _pendingTimer = null;
    await _controller.close();
    if (_ownsClient) await _closeQuietly(_httpClient.close);
    if (_ownsChecker) await _closeQuietly(_internetChecker.dispose);
  }

  /// Runs a resource-release [action] during terminal disposal, swallowing
  /// anything it throws. Cleanup must not surface — the client may be
  /// mid-request when closed (the `_loop` in-flight guard drops its
  /// result), and a checker override could raise. Unlike `_runCheck` (which
  /// narrows to `on Exception` so programmer-bug `Error`s propagate in
  /// development), disposal is terminal, so every throwable is swallowed.
  Future<void> _closeQuietly(FutureOr<void> Function() action) async {
    try {
      await action();
    } on Object {
      // Intentionally swallowed: see doc comment.
    }
  }

  /// Performs a one-off health check immediately and returns the
  /// observed state.
  ///
  /// When the check is inconclusive — the internet probe threw, so there is no
  /// proof either way — this returns the last known [currentState] rather than
  /// a freshly observed value (there is nothing new to report). So "returns the
  /// observed state" holds except on that inconclusive path.
  ///
  /// Pure probe: the returned [Future] is the ONLY delivery path. It does
  /// not emit on [stream] and does not move [currentState] — both continue
  /// to report the last state the polling loop confirmed. Use it from a
  /// retry button that wants the result locally (e.g. to drive a spinner
  /// or toast).
  ///
  /// It does reset the schedule, so the next polling delay is measured
  /// from this call's completion rather than from the previous tick.
  ///
  /// Why it leaves [currentState] alone: a lone probe has not cleared the
  /// [downConfirmationCount] gate, and writing it here would let
  /// `currentState` (and therefore the value replayed to a late
  /// subscriber) report something [stream] never carried — a disagreement
  /// with no path back, since the next loop tick sees "no change" and
  /// stays silent. One writer, one gate.
  ///
  /// Consequence worth knowing: a retry that succeeds does not itself
  /// clear a banner driven by [stream]. Act on the returned value, or
  /// wait for the next scheduled tick.
  Future<ConnectionHealthState> checkNow() async {
    _throwIfDisposed();
    _pendingTimer?.cancel();
    _pendingTimer = null;
    // Invalidate any concurrent in-flight _loop (see [_generation]): else a
    // _runCheck that completes after this checkNow would overwrite the
    // timer scheduled below, resetting the schedule from the wrong point.
    final gen = ++_generation;
    // `_runCheck` returns `null` when the internet check was inconclusive (it
    // threw); the `on Object` guard additionally catches a non-Exception
    // `Error` escaping the server probe (which `_runCheck` deliberately does
    // NOT catch). In both cases the probe told us nothing new, so we report the
    // last known state to the caller and — like `_loop` — reschedule on the
    // RETRY cadence (something is wrong, re-probe soon), not the relaxed one.
    //
    // The guard prevents a RELEASE wedge: without it an escaped `Error` would
    // reject this future after `_pendingTimer` was already cancelled above,
    // stopping the poller until the caller does stop()/start(). In DEBUG the
    // assert deliberately still fails loud (like `_loop`) so a real programmer
    // bug is not swallowed — asserts are stripped in release, where the
    // fall-through reschedule runs.
    ConnectionHealthState? probed;
    try {
      probed = await _runCheck();
    } on Object catch (e, st) {
      assert(
        e is Exception,
        'Non-Exception escaped _runCheck (likely a programmer bug): $e\n$st',
      );
      probed = null;
    }
    final state = probed ?? _currentState;
    if (_disposed) return state;
    if (_running && gen == _generation) {
      _pendingTimer = Timer(
        _nextDelay(probed ?? ConnectionHealthState.internetDisconnected),
        () => unawaited(_loop(gen)),
      );
    }
    return state;
  }

  // ---------------------------------------------------------------------------
  // Internal helpers.
  // ---------------------------------------------------------------------------

  /// One adaptive iteration: run the dual-tier check, emit on change,
  /// schedule the next. Bails without emitting or rescheduling if [stop]/
  /// [dispose] fired mid-check or a newer [start] cycle superseded [gen]
  /// (see [_generation]).
  Future<void> _loop(int gen) async {
    if (!_running || _disposed || gen != _generation) return;
    ConnectionHealthState? state;
    try {
      state = await _runCheck();
    } on Object catch (e, st) {
      // Last-resort guard. `_runCheck` is expected to swallow every probe
      // fault itself, but if anything ever escapes it, the poller must NOT
      // die: a rejected `_loop` future stops rescheduling, freezing the last
      // banner on screen until the app is backgrounded/resumed. Skip this
      // tick's emit and fall through to reschedule.
      //
      // But an `Error` (StateError, type error) escaping here is our own
      // programmer bug, which the server-probe catch deliberately lets
      // propagate ("Do NOT catch Error"). Re-surface it in debug via assert
      // (stripped in release) so it is loud in development; in release keep
      // swallowing so a production device never wedges on it.
      assert(
        e is Exception,
        'Non-Exception escaped _runCheck (likely a programmer bug): $e\n$st',
      );
      // ponytail: swallowed without logging (the package takes no logger yet);
      // route it to a log seam here if one is ever added.
    }
    if (!_running || _disposed || gen != _generation) return;
    if (state != null) _emitIfChanged(state);
    // Accepted limitation (cold-start dead zone): a null tick is inconclusive,
    // so it is skipped to keep a throw INVISIBLE — it must never advance the
    // confirmation gate (that invisibility is load-bearing; see test 8c). The
    // cost is that a device launched on a platform where the plugin throws on
    // EVERY tick, while also offline, stays at `initial` with no banner: we
    // cannot prove offline without a working checker, and guessing here would
    // both blame the user's link without proof and let a throw drive
    // confirmation. Narrow and unproven in the field; revisit only with data.
    //
    // On a thrown tick (state == null) retry soon rather than at the relaxed
    // cadence — something is wrong and the next probe should confirm quickly.
    _pendingTimer = Timer(
      _nextDelay(state ?? ConnectionHealthState.internetDisconnected),
      () => unawaited(_loop(gen)),
    );
  }

  /// Server-first dual-tier check. On a fast 2xx from the server probe,
  /// returns `healthy`. On a SLOW 2xx it does not trust the backend round
  /// trip alone — a slow backend is not the user's problem
  /// ([ConnectionHealthState.weakNetwork] means "your link is slow, the
  /// server is fine"; a sick *backend* is the reserved `serverDegraded`,
  /// §Out of scope, which we deliberately do not report). It times the
  /// user's real internet (the neutral CDN probe) and reports
  /// `weakNetwork` only on positive evidence that link is slow; otherwise
  /// `healthy`. On a failed probe it disambiguates: if the generic internet
  /// probe also fails the device is offline
  /// ([ConnectionHealthState.internetDisconnected]); otherwise the link is fine
  /// and the package reports `healthy`. It no longer judges the backend —
  /// server-down moved to the app's firebase `system_banners` channel in 0.4.0
  /// ([ConnectionHealthState.serverUnreachable] is retired but kept; see the
  /// seam below and the decouple plan).
  ///
  /// Inverting the previous "internet probe first" order fixes the
  /// false-negative on corporate firewalls that whitelist the API host
  /// but block public CDN probe endpoints, and keeps the happy path (fast
  /// 2xx) at ONE request — the second probe runs only on the rare slow 2xx
  /// or the rare failure.
  ///
  /// Returns `null` when the failure-path internet check is INCONCLUSIVE (it
  /// threw): the tick is skipped by the caller — no emit, no confirmation-gate
  /// reset, last banner preserved. A throw is neither proof of offline nor
  /// proof of health, so it must not move state in either direction.
  Future<ConnectionHealthState?> _runCheck() async {
    var serverOk = false;
    // `clock.now()` rather than `Stopwatch`: `fake_async` installs a fake
    // `Clock` but leaves `Stopwatch` on the real wall clock, so a stopwatch
    // here would read ~0 in every test regardless of elapsed virtual time.
    final startedAt = clock.now();
    try {
      // Wrap the whole probe (send + body drain) in a single timeout so a
      // server that returns headers quickly but dribbles the body cannot
      // hang the loop past `requestTimeout`.
      serverOk = await _probeServer().timeout(requestTimeout);
    } on TimeoutException {
      // fall through to disambiguation
    } on http.ClientException {
      // Client.send() throws this after close(); IOClient also wraps
      // SocketException as this type. Fall through.
    } on Exception {
      // Any other transport failure (HandshakeException, raw SocketException).
      // This generic clause is the backstop — it's why no `dart:io` catch is
      // needed, keeping the file import-free of `dart:io` for Web/WASM. Do
      // NOT catch `Error`: programmer bugs (StateError, type errors) must
      // propagate, not be misclassified as `serverUnreachable`.
    }

    if (serverOk) {
      // Fast 2xx: the user's path to us is quick, so their link is fine.
      // Happy path stays ONE request — no internet probe here.
      if (clock.now().difference(startedAt) <= slowThreshold) {
        return ConnectionHealthState.healthy;
      }
      // Slow 2xx. `weakNetwork` must mean the USER'S internet is slow, not
      // that our backend had a slow moment (we don't report backend health
      // client-side — that is the reserved `serverDegraded`). The backend
      // round trip cannot tell the two apart, so measure the user's real
      // internet and report `weakNetwork` only on positive proof it is slow.
      return await _userInternetIsSlow()
          ? ConnectionHealthState.weakNetwork
          : ConnectionHealthState.healthy;
    }

    // Server failed. Disambiguate via the generic internet probe.
    // `null` = the check could not be completed (threw), which is NOT the same
    // as a clean `false`.
    bool? hasInternet;
    try {
      hasInternet =
          await _internetChecker.hasInternetAccess.timeout(requestTimeout);
    } on TimeoutException {
      // Every neutral CDN endpoint (Cloudflare/Apple/Google) hung past
      // `requestTimeout`. Unlike a plugin `Error`, this is positive evidence
      // the device cannot reach the internet — a hanging/black-holing link is
      // offline from the user's point of view — so treat it as a clean
      // `false`, not an inconclusive skip. Without this, a black-holing captive
      // portal that makes the probe hang would leave the last banner frozen
      // instead of showing `internetDisconnected`.
      hasInternet = false;
    } on Object {
      // `on Object`, not `on Exception`: the checker can throw a non-Exception
      // `Error` (a null-deref inside the plugin on some platforms). An `Error`
      // is not an `Exception`, so an `on Exception` clause would let it escape,
      // rejecting the `_loop` future — which then never reschedules. The poller
      // wedges and the last banner freezes on screen until the app is
      // backgrounded/resumed. Swallow everything here so the check stays
      // self-contained; `hasInternet` stays `null` = "could not determine".
      hasInternet = null;
    }
    // Only a CLEAN `false` (endpoints reached, none answered) is proof the
    // device is offline. A throw is inconclusive: return `null` to SKIP this
    // tick entirely — no emit, no confirmation-gate reset, last banner
    // preserved. Returning `healthy` here instead would emit a false all-clear
    // AND clear the gate, so a genuinely offline device whose plugin throws on
    // alternating ticks would never confirm `internetDisconnected` (it never
    // reaches a run of `downConfirmationCount`) and stay masked as healthy. The
    // loop reschedules on `null` regardless, so a wedge is still impossible.
    if (hasInternet == null) return null;
    if (hasInternet == false) return ConnectionHealthState.internetDisconnected;
    // serverUnreachable is now owned by the app's firebase `system_banners`
    // channel — see
    // docs/plans/2026-07-31-001-refactor-decouple-server-unreachable-firebase-plan.md.
    // The package no longer judges the backend: with internet up, the only
    // thing it still owns (the device's link) is fine, so it reports `healthy`.
    // The enum value AND this return are kept (commented) so re-enabling the
    // package as the server-down authority (Approach C) is a diff, not an
    // archaeology dig. Retired in 0.4.0.
    // return ConnectionHealthState.serverUnreachable;
    return ConnectionHealthState.healthy;
  }

  /// Whether the user's own internet is measurably slow — the positive
  /// signal behind [ConnectionHealthState.weakNetwork].
  ///
  /// Times the injected neutral-CDN check. That check is non-strict, so it
  /// returns as soon as the FASTEST reachable endpoint answers — its
  /// duration is therefore best-case link latency, and if even that exceeds
  /// [slowThreshold] the link genuinely is slow. Anything short of positive
  /// evidence — a fast result, an unreachable/blocked result (`false`), a
  /// transport error, or a timeout — returns `false`, so `weakNetwork` never
  /// fires on a link we cannot PROVE is slow (e.g. a firewall that whitelists
  /// our host but blocks the CDN probes: backend 2xx, CDNs unreachable → the
  /// user's link is not blamed).
  Future<bool> _userInternetIsSlow() async {
    final startedAt = clock.now();
    try {
      final reachable =
          await _internetChecker.hasInternetAccess.timeout(requestTimeout);
      if (!reachable) return false;
    } on Object {
      // `on Object`, not `on Exception`: the checker can throw a non-Exception
      // `Error` (null-deref inside the plugin on some platforms), which must
      // not escape and wedge the poller. Inconclusive = not proven slow.
      return false;
    }
    return clock.now().difference(startedAt) > slowThreshold;
  }

  /// Issues `GET _uri` (redirects disabled) and reports whether the
  /// server responded 2xx. Wrapped in `requestTimeout` by the caller.
  /// Drains the body so the pooled connection is reusable (a future
  /// `serverDegraded` state would parse it here instead).
  // ponytail: drain isn't cancelled on timeout; a hung body keeps the
  // subscription alive until the transport's idle timeout (~60s, under the
  // retry cadence) reclaims it — self-limiting, not a leak. Upgrade to a
  // cancelable drain if metrics ever show a real slow-body leak.
  Future<bool> _probeServer() async {
    final req = http.Request('GET', _uri)..followRedirects = false;
    final res = await _httpClient.send(req);
    final ok = res.statusCode >= 200 && res.statusCode < 300;
    await res.stream.drain<void>();
    return ok;
  }

  /// The single writer of [_currentState]: emits on [_controller] only if
  /// the state differs from the last emission, and records it in the same
  /// breath. `initial` is a valid previous-state baseline so the first
  /// non-`initial` observation emits exactly one event.
  ///
  /// A degraded [state] must first clear [_isConfirmed]; until it does,
  /// this returns without touching [_currentState], so an unconfirmed
  /// observation is invisible to BOTH the stream and [currentState] (a
  /// late subscriber is replayed [_currentState], and must never receive a
  /// value the stream itself never emitted).
  void _emitIfChanged(ConnectionHealthState state) {
    if (!_isConfirmed(state)) return;
    if (state == _currentState) return;
    _currentState = state;
    if (!_controller.isClosed) _controller.add(state);
  }

  /// Consecutive-observation gate: `true` once [state] may be reported.
  ///
  /// `healthy` always passes immediately and clears both runs — recovery is
  /// never delayed (the inverse of the circuit-breaker convention,
  /// deliberately: a breaker trips fast to shield a fragile downstream
  /// from a retry storm, which is not what one polling client is doing).
  ///
  /// A degraded state passes on either of two rules.
  ///
  /// **Rule 1 — the same state, [downConfirmationCount] times in a row.**
  /// Keyed on the state ITSELF, not on "something was wrong", so
  /// `internetDisconnected` then `serverUnreachable` confirms neither: two
  /// different failures are not yet a consistent story, and swapping the
  /// banner's advice ("check your WiFi" vs "our servers are down") on every
  /// probe is worse than picking one and holding it.
  ///
  /// **Rule 2 — [downConfirmationCount] consecutive failures of ANY kind,
  /// while nothing degraded is being reported yet.** Rule 1 alone has a
  /// hole: a link alternating between two failure modes never builds a
  /// same-state run, so it would report NOTHING, forever — the app looks
  /// perfectly healthy while every request fails. Rule 2 closes it. Once a
  /// degraded state IS on screen, rule 2 stops applying and rule 1 governs
  /// the label again, so an established banner cannot flap between two
  /// failure modes on alternating probes.
  ///
  /// **`weakNetwork` is exempt from "degraded is on screen".** It is a
  /// SUCCESSFUL probe — the server answered, just slowly — so it belongs
  /// semantically with `healthy` despite sitting among the failure values.
  /// Counting it as an established banner disarmed rule 2 and re-opened the
  /// never-confirms trap: reach `weakNetwork` from a slow link, then degrade
  /// into ALTERNATING failure modes, and neither rule can ever fire. The
  /// user holds a reassuring "connection will improve" banner on a fully
  /// offline device, forever. Escalating out of `weakNetwork` is therefore
  /// allowed generically.
  ///
  /// Blip protection survives both rules: a single failure can never pass,
  /// because rule 2 also requires [downConfirmationCount] observations. That
  /// holds on exit from `weakNetwork` only because confirming `weakNetwork`
  /// also clears [_degradedRun] — otherwise the counter would already sit at
  /// threshold the moment the banner appeared, and the exemption above would
  /// let the next single failure through on one observation.
  ///
  /// This split follows the industry precedent rather than inventing one.
  /// Kubernetes `failureThreshold`, gRPC's connectivity state machine and
  /// Resilience4j all count failure as a GENERIC condition rather than
  /// matching a specific failure sub-type — which is exactly what avoids
  /// the never-confirms trap. Per-state matching is retained on top of that
  /// only where it earns its keep: choosing WHICH label to show, and
  /// keeping it steady once shown.
  bool _isConfirmed(ConnectionHealthState state) {
    if (state == ConnectionHealthState.healthy) {
      _streakState = null;
      _streakCount = 0;
      _degradedRun = 0;
      return true;
    }
    _degradedRun++;
    if (state == _streakState) {
      _streakCount++;
    } else {
      _streakState = state;
      _streakCount = 1;
    }
    var confirmed = _streakCount >= downConfirmationCount;
    if (!confirmed) {
      // Rule 2 — only while the user is being shown nothing. `weakNetwork`
      // counts as nothing: it is a SUCCESSFUL probe, so escalating out of it
      // must stay generically available.
      final reportingDegraded =
          _currentState != ConnectionHealthState.healthy &&
              _currentState != ConnectionHealthState.initial &&
              _currentState != ConnectionHealthState.weakNetwork;
      confirmed = !reportingDegraded && _degradedRun >= downConfirmationCount;
    }
    // `weakNetwork` is a SUCCESSFUL probe, so it never contributes to the
    // generic failure run — cleared on OBSERVATION, not merely on
    // confirmation. Gating this on `confirmed` would leave the run primed by
    // an unconfirmed `weakNetwork` (which still incremented it above), and
    // `_currentState` is then typically `healthy`, so rule 2 is armed: one
    // slow probe followed by a single failure would confirm that failure on
    // one observation, defeating the blip protection `downConfirmationCount`
    // exists to provide. Placed after both rules so it cannot be applied to
    // one confirming path and missed on the other.
    if (state == ConnectionHealthState.weakNetwork) {
      _degradedRun = 0;
    }
    return confirmed;
  }

  /// Next delay: [healthyInterval] when the server ANSWERED (`healthy` or
  /// `weakNetwork`), [retryInterval] when it did not, with uniform
  /// `±jitterRatio` jitter.
  ///
  /// `weakNetwork` deliberately polls on the slow cadence. It is a
  /// SUCCESSFUL probe — the request completed, the server replied, the
  /// connection works and is merely slow — so there is no outage to
  /// recover from and nothing that a 1-minute re-probe would learn sooner
  /// in a way the user could act on. The fast cadence costs ~1440
  /// requests/day sustained, plus a radio wakeup each, on exactly the
  /// connections least able to spare either. Recovery is still picked up
  /// within one [healthyInterval].
  Duration _nextDelay(ConnectionHealthState state) {
    final serverAnswered = state == ConnectionHealthState.healthy ||
        state == ConnectionHealthState.weakNetwork;
    final base = serverAnswered ? healthyInterval : retryInterval;
    if (jitterRatio == 0) return base;
    final jitterMs =
        (base.inMilliseconds * jitterRatio) * (_random.nextDouble() * 2 - 1);
    final totalMs = base.inMilliseconds + jitterMs.toInt();
    return Duration(milliseconds: max(0, totalMs));
  }

  /// Throws [StateError] if this monitor has been [dispose]d. Used by
  /// every mutating public method.
  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('ConnectionHealthMonitor has been disposed');
    }
  }

  /// Normalizes [baseUrl] + [healthPath] into a single [Uri] computed
  /// once at construction time:
  ///
  /// - Strips ALL trailing `/` from `baseUrl` (so
  ///   `https://api.example.com/` and `https://api.example.com//` both
  ///   produce `https://api.example.com/health`, never `...//health`).
  /// - Prepends a `/` to `healthPath` if missing.
  ///
  /// Throws [ArgumentError] if [baseUrl] is not a valid absolute
  /// http/https URL with a non-empty host and no query/fragment.
  /// `Uri.parse` alone is too permissive — `'not a url'` parses as an
  /// opaque URI; `'http://'` parses with `hasAuthority == true` but an
  /// empty host; `'https://api.x?k=v'` would put `/health` inside the
  /// query string. Each of those would silently produce garbage
  /// requests at probe time.
  static Uri _composeUri(String baseUrl, String healthPath) {
    final trimmedBase = baseUrl.replaceAll(_trailingSlashes, '');
    final parsed = Uri.tryParse(trimmedBase);
    if (parsed == null ||
        !parsed.hasAuthority ||
        parsed.host.isEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'must be an absolute http/https URL with a non-empty host and '
            'no query/fragment (e.g. https://api.example.com)',
      );
    }
    final normalizedPath = '/${healthPath.replaceFirst(_leadingSlashes, '')}';
    return Uri.parse('$trimmedBase$normalizedPath');
  }
}

final RegExp _trailingSlashes = RegExp(r'/+$');
final RegExp _leadingSlashes = RegExp(r'^/+');
