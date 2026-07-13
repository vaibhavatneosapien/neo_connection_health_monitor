import 'dart:async';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';

import 'connection_health_state.dart';

/// Monitors device internet connectivity AND a specific server's
/// reachability, exposing transitions via a broadcast [Stream].
///
/// Construct one instance at app startup, [start] it, and listen to
/// [stream]. The monitor performs a dual-tier check on an adaptive
/// schedule (every [healthyInterval] when healthy, every
/// [retryInterval] otherwise, each with +/-[jitterRatio] jitter to
/// avoid synchronized thundering-herd load on the backend).
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
///
/// ## Lifecycle summary
///
/// - [start] - begins polling; idempotent.
/// - [stop] - pause; cancels the pending timer, leaves the stream
///   controller open. Calling [start] afterwards resumes polling.
/// - [dispose] - terminal; cancels the timer, closes the broadcast
///   controller, and closes the [http.Client] if (and only if) the
///   package created it. Any subsequent method call throws
///   [StateError].
/// - [checkNow] - pure probe; returns the freshly-observed state, does
///   NOT emit on [stream], resets the scheduled timer.
class ConnectionHealthMonitor {
  /// Creates a monitor that probes `${baseUrl}${healthPath}` on an
  /// adaptive schedule and reports state transitions on [stream].
  ///
  /// - [baseUrl] - required. The API base URL, e.g.
  ///   `https://api.neosapien.xyz`. Any trailing `/` is stripped at
  ///   construction time.
  /// - [healthPath] - defaults to `/health`. A leading `/` is added if
  ///   missing.
  /// - [healthyInterval] - delay between checks after a `healthy`
  ///   observation. Default: 5 minutes.
  /// - [retryInterval] - delay between checks after any non-`healthy`
  ///   observation. Default: 1 minute.
  /// - [requestTimeout] - per-request timeout. Default: 8 seconds
  ///   (chosen over 5 s for 3G on tier-2 networks).
  /// - [jitterRatio] - fraction of the scheduled delay applied as
  ///   +/- random jitter. Default: 0.1 (+/-10%). Pass exactly `0.0` to
  ///   disable jitter (the check is `jitterRatio == 0`, no epsilon).
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
    this.jitterRatio = 0.1,
    http.Client? httpClient,
    InternetConnection? internetChecker,
    Random? random,
  })  : assert(
          jitterRatio >= 0 && jitterRatio < 1,
          'jitterRatio must be in [0, 1); a value >= 1 lets negative jitter '
          'clamp the delay to 0, producing back-to-back probe bursts.',
        ),
        _ownsClient = httpClient == null,
        _ownsChecker = internetChecker == null,
        _httpClient = httpClient ?? http.Client(),
        _internetChecker =
            internetChecker ?? InternetConnection.createInstance(),
        _random = random ?? Random(),
        _uri = _composeUri(baseUrl, healthPath);

  // ---------------------------------------------------------------------------
  // Configuration (immutable after construction).
  // ---------------------------------------------------------------------------

  /// Delay between checks while the last observed state is `healthy`.
  final Duration healthyInterval;

  /// Delay between checks while the last observed state is not
  /// `healthy`.
  final Duration retryInterval;

  /// Per-request timeout for the server `/health` probe.
  final Duration requestTimeout;

  /// Fraction of the scheduled delay applied as +/- random jitter.
  /// `0.1` means +/-10%. Must be in `[0, 1)` (asserted at construction):
  /// a value `>= 1` lets negative jitter exceed the base delay, which the
  /// clamp floors to 0 -> immediate back-to-back re-probes.
  final double jitterRatio;

  // ---------------------------------------------------------------------------
  // Private state.
  // ---------------------------------------------------------------------------

  /// `true` if the monitor created [_httpClient] itself and is therefore
  /// responsible for closing it on [dispose]. An injected client is
  /// owned by the caller and must never be closed here.
  final bool _ownsClient;

  /// `true` if the monitor created [_internetChecker] itself (via
  /// `createInstance()`) and must therefore dispose it on [dispose] to
  /// free its internal timers/controllers. An injected checker is owned
  /// by the caller and must never be disposed here.
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

  /// Source of randomness for +/- jitter on scheduled delays. Inject a
  /// seeded `Random` in tests for deterministic timing.
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

  /// Cached most-recent state. Returned by [currentState] and used as
  /// the de-dupe baseline; starts as [ConnectionHealthState.initial].
  ConnectionHealthState _currentState = ConnectionHealthState.initial;

  /// Last state actually emitted on [stream]. Used to de-dupe so that
  /// repeated `healthy -> healthy` observations do not cause needless
  /// `StreamBuilder` rebuilds. Initialized to `initial` so the first
  /// real check produces exactly one emission.
  ConnectionHealthState _lastState = ConnectionHealthState.initial;

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
    ConnectionHealthState? replayed;
    if (_currentState != ConnectionHealthState.initial) {
      replayed = _currentState;
      controller.add(_currentState);
    }
    final sub = _controller.stream.listen(
      (state) {
        // Per-subscriber de-dupe: a silent `checkNow()` can move
        // `_currentState` ahead of the broadcast de-dupe baseline
        // (`_lastState`), so a late subscriber that just replayed the
        // fresh value would otherwise receive the same value again when
        // the next loop tick re-emits it. Drop that first repeat.
        if (replayed != null) {
          final justReplayed = replayed;
          replayed = null;
          if (state == justReplayed) return;
        }
        controller.add(state);
      },
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });

  /// The most recently observed state, or
  /// [ConnectionHealthState.initial] if no check has completed yet.
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
    // Bump generation so any stale in-flight loop iteration from a prior
    // start()/stop() cycle bails on its post-await guard instead of
    // emitting and rescheduling — preventing concurrent loops doubling
    // the request rate.
    final gen = ++_generation;
    // Fire-and-forget: the loop self-schedules via Timer.
    unawaited(_loop(gen));
  }

  /// Pauses the polling loop without tearing down the monitor.
  ///
  /// Cancels the pending timer and clears the running flag. The
  /// broadcast [stream] controller stays open, and any owned
  /// [http.Client] is NOT closed - so a subsequent [start] resumes
  /// polling cleanly. This is the right call when the app is backgrounded
  /// (`AppLifecycleState.paused` / `detached` / `hidden`) - NOT on
  /// `inactive`, which is a transient foreground state on iOS.
  ///
  /// For terminal cleanup at app shutdown, use [dispose] instead.
  void stop() {
    _throwIfDisposed();
    _running = false;
    _pendingTimer?.cancel();
    _pendingTimer = null;
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
  /// Pure probe: does NOT emit on [stream]. It DOES update
  /// [currentState] and reset the schedule so the next polling delay
  /// is measured from this call's completion. Use it from a retry
  /// button that wants the result locally (e.g. to drive a spinner or
  /// toast) without going through the stream.
  ///
  /// Callers that expect a stream emission will get silent breakage -
  /// subscribe to [stream] for emissions, await [checkNow] for the
  /// return value.
  Future<ConnectionHealthState> checkNow() async {
    _throwIfDisposed();
    _pendingTimer?.cancel();
    _pendingTimer = null;
    // Bump generation to invalidate any concurrent in-flight `_loop`
    // iteration. Without this, a `_loop._runCheck()` that started before
    // `checkNow` and completes after would overwrite the timer we schedule
    // below — resetting the schedule from the wrong point in time.
    final gen = ++_generation;
    final state = await _runCheck();
    if (_disposed) return state;
    _currentState = state;
    if (_running && gen == _generation) {
      _pendingTimer = Timer(_nextDelay(state), () {
        unawaited(_loop(gen));
      });
    }
    return state;
  }

  // ---------------------------------------------------------------------------
  // Internal helpers.
  // ---------------------------------------------------------------------------

  /// One adaptive iteration: run the dual-tier check, emit on change,
  /// schedule the next iteration. Bails without emitting or scheduling
  /// if [stop] or [dispose] fired while the check was in flight, or if
  /// a fresh [start] cycle bumped [_generation] past [gen] (which means
  /// a newer loop is already in flight).
  Future<void> _loop(int gen) async {
    if (!_running || _disposed || gen != _generation) return;
    final state = await _runCheck();
    if (!_running || _disposed || gen != _generation) return;
    _emitIfChanged(state);
    _pendingTimer = Timer(_nextDelay(state), () {
      unawaited(_loop(gen));
    });
  }

  /// Server-first dual-tier check. Returns `healthy` on a 2xx response
  /// from the server probe. Otherwise disambiguates: if the generic
  /// internet probe also fails, the device is offline
  /// ([ConnectionHealthState.internetDisconnected]); else the server is
  /// the cause ([ConnectionHealthState.serverUnreachable]).
  ///
  /// Inverting the previous "internet probe first" order fixes the
  /// false-negative on corporate firewalls that whitelist the API host
  /// but block public CDN probe endpoints, and is cheaper in the happy
  /// path (one request, not two).
  Future<ConnectionHealthState> _runCheck() async {
    var serverOk = false;
    try {
      // Wrap the whole probe (send + body drain) in a single timeout so a
      // server that returns headers quickly but dribbles the body cannot
      // hang the loop past `requestTimeout`.
      serverOk = await _probeServer().timeout(requestTimeout);
    } on TimeoutException {
      // Falls through to the disambiguation block below.
    } on http.ClientException {
      // Falls through (covers `Client.send` errors after `close`; the
      // IOClient also wraps `dart:io` `SocketException` as this type).
    } on Exception {
      // Any other transport-layer failure (HandshakeException, a raw
      // SocketException, etc). This generic clause is the real backstop —
      // it is why no `dart:io`-specific catch is needed, which in turn
      // keeps this file free of a `dart:io` import so the package stays
      // Web/WASM-capable. We deliberately do NOT catch `Error` — programmer
      // bugs (StateError, AssertionError, type errors) must propagate so
      // they surface in development instead of being silently classified as
      // `serverUnreachable`.
    }

    if (serverOk) return ConnectionHealthState.healthy;

    // Server failed. Disambiguate via the generic internet probe.
    bool hasInternet;
    try {
      hasInternet = await _internetChecker.hasInternetAccess;
    } on Exception {
      hasInternet = false;
    }
    return hasInternet
        ? ConnectionHealthState.serverUnreachable
        : ConnectionHealthState.internetDisconnected;
  }

  /// Issues the `GET _uri` request and reports whether the server
  /// responded with 2xx. Wrapped in `requestTimeout` by the caller.
  ///
  /// Drains the body so the pooled connection is reusable (a future
  /// `degraded` state would parse the 2xx body here instead of discarding
  /// it). Caveat: `Future.timeout` does not cancel its source, so a hung
  /// body keeps the `drain()` subscription alive until the transport's own
  /// idle timeout reclaims it. Self-limiting in practice — a health body is
  /// a few bytes and LB/proxy idle timeouts (~60s) sit under the retry
  /// cadence — so it's a caveat, not a live leak.
  // ponytail: drain-on-timeout not cancelled; upgrade to a cancelable
  // subscription if a real slow-body leak ever shows up in metrics.
  Future<bool> _probeServer() async {
    final req = http.Request('GET', _uri)..followRedirects = false;
    final res = await _httpClient.send(req);
    final ok = res.statusCode >= 200 && res.statusCode < 300;
    await res.stream.drain<void>();
    return ok;
  }

  /// Updates [_currentState] and emits on [_controller] only if the
  /// state differs from the last emission. `initial` is a valid
  /// previous-state baseline so the first non-`initial` observation
  /// emits exactly one event.
  void _emitIfChanged(ConnectionHealthState state) {
    _currentState = state;
    if (state == _lastState) return;
    _lastState = state;
    if (!_controller.isClosed) _controller.add(state);
  }

  /// Computes the next scheduled delay: `healthyInterval` when the
  /// last observed state was `healthy`, else `retryInterval`, with
  /// `±jitterRatio` random jitter applied uniformly. Inject a seeded
  /// [Random] in tests for deterministic timing.
  Duration _nextDelay(ConnectionHealthState state) {
    final base = state == ConnectionHealthState.healthy
        ? healthyInterval
        : retryInterval;
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

/// Matches one or more trailing `/` characters.
final RegExp _trailingSlashes = RegExp(r'/+$');

/// Matches one or more leading `/` characters.
final RegExp _leadingSlashes = RegExp(r'^/+');
