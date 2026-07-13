/// Pure-Dart package that monitors device internet connectivity and a
/// specific server's `/health` reachability, exposing state via a
/// broadcast [Stream].
///
/// See `ConnectionHealthMonitor` for the entry point and
/// `ConnectionHealthState` for the emitted values.
library;

export 'src/connection_health_monitor.dart';
export 'src/connection_health_state.dart';
