/// The four states reported by [ConnectionHealthMonitor].
///
/// These map 1:1 to the affordances a UI should show. They are deliberately
/// kept distinct so that `internetDisconnected` (user can act — fix WiFi) and
/// `serverUnreachable` (user is stuck waiting on us) drive different copy.
///
/// Do not collapse [internetDisconnected] and [serverUnreachable] into a
/// single "offline" state — they communicate different things to the user.
enum ConnectionHealthState {
  /// Emitted before the first health check completes. Acts as a starting
  /// sentinel so consumers can distinguish "not yet checked" from
  /// "checked and healthy/unhealthy".
  ///
  /// Do not render an error banner from this state — show a neutral
  /// placeholder (e.g. nothing) and wait for the first real emission.
  initial,

  /// Emitted when the configured server `/health` endpoint returned a 2xx
  /// status within the configured timeout. The device has working internet
  /// AND the server is reachable.
  healthy,

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
