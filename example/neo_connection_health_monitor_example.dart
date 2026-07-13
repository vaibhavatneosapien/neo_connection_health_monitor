import 'package:neo_connection_health_monitor/neo_connection_health_monitor.dart';

/// Minimal demo: construct a monitor, subscribe to its stream, run for
/// 30 seconds, then dispose cleanly.
///
/// Replace `baseUrl` with your own API base; this example points at the
/// Neosapien production API by default.
Future<void> main() async {
  final monitor = ConnectionHealthMonitor(baseUrl: 'https://api.neosapien.xyz');

  final sub = monitor.stream.listen((state) {
    // ignore: avoid_print
    print('[connection] $state');
  });

  monitor.start();

  // Run for 30 seconds so you observe at least the first emission.
  await Future<void>.delayed(const Duration(seconds: 30));

  await sub.cancel();
  await monitor.dispose();
}
