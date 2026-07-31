/// The states of [ConnectionHealthMonitor].
///
/// Four are emitted — [healthy], [weakNetwork], [internetDisconnected], and
/// the [initial] sentinel. [serverUnreachable] is **reserved, not emitted
/// since 0.4.0** (server-down moved to the app's firebase channel; see its
/// member doc). Each emitted state maps 1:1 to a UI affordance; keep them
/// distinct — they drive different UI copy.
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

  /// Emitted when the server probe SUCCEEDED but slowly (round trip >
  /// `slowThreshold`) AND a second probe confirms the user's OWN internet
  /// is slow too. The connection works; it is slow enough that uploads
  /// will visibly lag.
  ///
  /// The two-signal check is deliberate. A slow round trip to our server
  /// alone does not prove the user's link is weak — it could be our
  /// backend having a slow moment, which is not the user's problem and not
  /// what this state reports (a sick backend is the reserved
  /// `serverDegraded`). So on a slow 2xx the monitor times the user's real
  /// internet (the neutral CDN probe) and reports `weakNetwork` only on
  /// POSITIVE evidence that link is slow; a fast, blocked, unreachable, or
  /// errored internet check resolves to [healthy] instead — the user's
  /// network is never blamed without proof. See CONCEPTS.md: "your link is
  /// slow, the server is fine."
  ///
  /// This is a latency verdict, not a bandwidth measurement. At the default
  /// `downConfirmationCount: 1` a single pair of slow probes is enough to
  /// report it: the banner it drives is advisory ("your memory will sync
  /// once the connection improves"), so a false positive costs the user
  /// nothing. Consumers that would rather wait for a consistent story can
  /// raise `downConfirmationCount`, which applies to this state like any
  /// other non-`healthy` one.
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

  /// **Reserved — not emitted in production since 0.4.0.** Server-down moved
  /// to the app's firebase `system_banners` channel (ops-published); the
  /// package no longer judges the backend, so a server probe that fails while
  /// the internet is up now reports [healthy] instead of this. The value is
  /// kept (deleting it is a source break for exhaustive `switch`es) and the
  /// producing branch is preserved commented in `_runCheck`, so re-enabling
  /// the package as the server-down authority (Approach C) is a one-line diff.
  /// See docs/plans/2026-07-31-…-decouple-server-unreachable-firebase-plan.md.
  ///
  /// Historically: emitted when the server probe failed BUT the generic
  /// internet probe succeeded (timeout, 3xx, 4xx, 5xx, or socket error while
  /// online). UI hint was "Our servers are temporarily unreachable."
  serverUnreachable,
}
