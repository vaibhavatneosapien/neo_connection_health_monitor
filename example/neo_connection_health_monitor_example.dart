import 'package:neo_connection_health_monitor/neo_connection_health_monitor.dart';

/// Minimal usage demo. Replaced with the real example in ST-4.
void main() {
  final monitor = ConnectionHealthMonitor(baseUrl: 'https://api.neosapien.xyz');
  // Skeleton only — `start()` throws `UnimplementedError` until ST-2 lands.
  // monitor.start();
  print('current state (pre-check): ${monitor.currentState}');
  print('configured for: $ConnectionHealthState');
}
