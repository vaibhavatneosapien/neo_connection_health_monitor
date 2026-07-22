/// The five states reported by [ConnectionHealthMonitor].
///
/// Each maps 1:1 to a UI affordance. Keep [internetDisconnected] (user can
/// act — fix WiFi) and [serverUnreachable] (user is stuck waiting on us)
/// distinct — do not collapse them into one "offline" state; they drive
/// different UI copy.
enum ConnectionHealthState {
  /// The state before the first health check completes. Acts as a
  /// starting sentinel so consumers can distinguish "not yet checked"
  /// from "checked and healthy/unhealthy". Note: this value is never
  /// emitted on `stream` (nor replayed to late subscribers) — it is only
  /// ever observed via `currentState`.
  ///
  /// Do not render an error banner from this state — show a neutral
  /// placeholder (e.g. nothing) and wait for the first real emission.
  initial,

  /// Emitted when the configured server `/health` endpoint returned a 2xx
  /// status within the configured timeout. The device has working internet
  /// AND the server is reachable.
  healthy,

  /// Emitted when the server probe SUCCEEDED but took longer than
  /// `slowThreshold` to do so. The connection works; it is slow enough
  /// that uploads will visibly lag.
  ///
  /// This is a latency verdict on one request, not a bandwidth
  /// measurement. At the default `downConfirmationCount: 1` a single slow
  /// probe on an otherwise fine network is enough to report it. That is
  /// deliberate: the banner it drives is advisory ("your memory will sync
  /// once the connection improves"), so a false positive costs the user
  /// nothing, while a missed slow network leaves them staring at a stalled
  /// upload with no explanation. Consumers that would rather wait for a
  /// consistent story can raise `downConfirmationCount`, which applies to
  /// this state like any other non-`healthy` one.
  ///
  /// Polled at `healthyInterval`, NOT `retryInterval` — the probe
  /// succeeded, so there is no outage to recover from. Re-checking a
  /// working-but-slow link five times as often would sustain ~1440
  /// requests a day, and the radio wakeups with them, on exactly the
  /// connections least able to spare either. Recovery is noticed within
  /// one `healthyInterval`, which is soon enough for an advisory banner.
  ///
  /// Because the probe SUCCEEDED, this state does not count as "something
  /// degraded is on screen" for the confirmation gate's generic-failure
  /// rule — it belongs semantically with [healthy] despite sitting among
  /// the failure values here. A link that degrades out of `weakNetwork`
  /// into alternating failure modes can therefore still confirm one.
  /// Without that exemption the gate locks open and the advisory banner
  /// below stays on screen while the device is fully offline.
  ///
  /// UI hint: "Weak Network" — no action available, capture continues.
  weakNetwork,

  /// Emitted when the server probe failed AND the generic internet probe
  /// (Cloudflare / Apple captive / Google CDN — see
  /// `internet_connection_checker_plus`) also failed.
  ///
  /// UI hint: "Check your WiFi / mobile data" — the user can act.
  internetDisconnected,

  /// Emitted when the server probe failed BUT the generic internet probe
  /// succeeded, indicating the device has internet but the configured
  /// server is unreachable (timeout, 3xx redirect, 4xx, 5xx, or socket
  /// error).
  ///
  /// UI hint: "Our servers are temporarily unreachable" — the user is
  /// stuck waiting; retry on a button press is the only useful action.
  serverUnreachable,
}
