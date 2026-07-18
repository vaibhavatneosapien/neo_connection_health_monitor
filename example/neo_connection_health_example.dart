import 'package:neo_connection_health/neo_connection_health.dart';

/// Minimal demo: construct a monitor, subscribe to its stream, run for
/// 30 seconds, then dispose cleanly.
///
/// Replace `baseUrl` with your own API base; this example points at the
/// Neosapien dev API, whose health route is `/healthz` (the package
/// default `/health` does not exist on any Neosapien environment).
Future<void> main() async {
  final monitor = ConnectionHealthMonitor(
    baseUrl: 'https://neo-backend-v2.dev-api.neosapien.xyz',
    healthPath: '/healthz',
  );

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
