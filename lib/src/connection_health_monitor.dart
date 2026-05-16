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
/// lifecycle. The caller MUST call [stop] when the app enters
/// `AppLifecycleState.paused` / `inactive` / `detached` / `hidden` and
/// call [start] again on `resumed`. Failing to do so causes the
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
  ///   +/- random jitter. Default: 0.1 (+/-10%). Set to 0 to disable.
  /// - [httpClient] - optional injected client. If `null`, the monitor
  ///   creates its own [http.Client] and closes it on [dispose]. An
  ///   injected client is never closed by the monitor.
  /// - [internetChecker] - optional injected internet probe. Used only
  ///   as a tiebreaker when the server probe fails. If `null`, the
  ///   default `InternetConnection()` from
  ///   `internet_connection_checker_plus` is used.
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
  }) : _ownsClient = httpClient == null,
       _httpClient = httpClient ?? http.Client(),
       _internetChecker = internetChecker ?? InternetConnection(),
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
  /// `0.1` means +/-10%. Must be `>= 0`.
  final double jitterRatio;

  // ---------------------------------------------------------------------------
  // Private state. ST-2 wires these up; for now they exist so the API
  // surface and lifecycle contract are visible.
  // ---------------------------------------------------------------------------

  /// `true` if the monitor created [_httpClient] itself and is therefore
  /// responsible for closing it on [dispose]. An injected client is
  /// owned by the caller and must never be closed here.
  // ignore: unused_field
  final bool _ownsClient;

  /// Pre-composed request URI. Built once at construction time so the
  /// hot path does not repeat URL parsing/normalization on every check.
  // ignore: unused_field
  final Uri _uri;

  /// HTTP client used for the server probe. Either injected by the
  /// caller or created in the constructor (see [_ownsClient]).
  // ignore: unused_field
  final http.Client _httpClient;

  /// Generic-internet probe used as a tiebreaker when the server check
  /// fails. Probes public CDN endpoints (Cloudflare, Apple captive,
  /// Google) - see `internet_connection_checker_plus` docs.
  // ignore: unused_field
  final InternetConnection _internetChecker;

  /// Source of randomness for +/- jitter on scheduled delays. Inject a
  /// seeded `Random` in tests for deterministic timing.
  // ignore: unused_field
  final Random _random;

  /// Broadcast controller for state transitions. Multiple subscribers
  /// are supported; emissions are de-duplicated against [_lastState].
  final StreamController<ConnectionHealthState> _controller =
      StreamController<ConnectionHealthState>.broadcast();

  /// `true` between [start] and [stop]. The loop checks this before
  /// emitting and before scheduling the next iteration; a pending check
  /// that completes after `stop()` must NOT emit or reschedule.
  // ignore: unused_field, prefer_final_fields
  bool _running = false;

  /// `true` after [dispose]. Every public method checks this first and
  /// throws [StateError] if set, to guarantee no late events fire from
  /// a disposed instance.
  // ignore: unused_field, prefer_final_fields
  bool _disposed = false;

  /// Handle for the next scheduled check. Stored so [stop] and
  /// [dispose] can cancel it cleanly.
  // ignore: unused_field
  Timer? _pendingTimer;

  /// Cached most-recent state. Returned by [currentState] and used as
  /// the de-dupe baseline; starts as [ConnectionHealthState.initial].
  // ignore: prefer_final_fields
  ConnectionHealthState _currentState = ConnectionHealthState.initial;

  /// Last state actually emitted on [stream]. Used to de-dupe so that
  /// repeated `healthy -> healthy` observations do not cause needless
  /// `StreamBuilder` rebuilds. Initialized to `initial` so the first
  /// real check produces exactly one emission.
  // ignore: unused_field, prefer_final_fields
  ConnectionHealthState _lastState = ConnectionHealthState.initial;

  // ---------------------------------------------------------------------------
  // Public API.
  // ---------------------------------------------------------------------------

  /// Broadcast stream of state transitions. Multiple listeners are
  /// supported. Emissions are de-duplicated - the same state is never
  /// emitted twice in a row.
  ///
  /// New subscribers do NOT automatically receive the most recent
  /// state; read [currentState] if you need the value synchronously,
  /// but heed the warning on that getter.
  Stream<ConnectionHealthState> get stream => _controller.stream;

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
    throw UnimplementedError('ST-2 will implement');
  }

  /// Pauses the polling loop without tearing down the monitor.
  ///
  /// Cancels the pending timer and clears the running flag. The
  /// broadcast [stream] controller stays open, and any owned
  /// [http.Client] is NOT closed - so a subsequent [start] resumes
  /// polling cleanly. This is the right call from
  /// `AppLifecycleState.paused` / `inactive` / `detached` / `hidden`.
  ///
  /// For terminal cleanup at app shutdown, use [dispose] instead.
  Future<void> stop() {
    throw UnimplementedError('ST-2 will implement');
  }

  /// Terminal cleanup. Cancels the pending timer, closes the broadcast
  /// stream controller, and closes the owned [http.Client] (only if the
  /// monitor created it - an injected client is left alone).
  ///
  /// After [dispose] returns, any public method call - including a
  /// second [dispose] - throws [StateError]. Use [stop] instead if you
  /// want to pause and resume.
  Future<void> dispose() {
    throw UnimplementedError('ST-2 will implement');
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
  Future<ConnectionHealthState> checkNow() {
    throw UnimplementedError('ST-2 will implement');
  }

  // ---------------------------------------------------------------------------
  // Internal helpers.
  // ---------------------------------------------------------------------------

  /// Normalizes [baseUrl] + [healthPath] into a single [Uri] computed
  /// once at construction time:
  ///
  /// - Strips a trailing `/` from `baseUrl` (so
  ///   `https://api.example.com/` does not produce `...//health`).
  /// - Prepends a `/` to `healthPath` if missing.
  ///
  /// Throws [FormatException] (via [Uri.parse]) if the composed string
  /// is not a parseable URI.
  static Uri _composeUri(String baseUrl, String healthPath) {
    final trimmedBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final normalizedPath = healthPath.startsWith('/')
        ? healthPath
        : '/$healthPath';
    return Uri.parse('$trimmedBase$normalizedPath');
  }
}
