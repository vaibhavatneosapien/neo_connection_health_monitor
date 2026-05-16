import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neo_connection_health_monitor/neo_connection_health_monitor.dart';
import 'package:test/test.dart';

/// ST-2 smoke tests verifying the public API surface is wired (not the
/// 14-case behavioral suite — that lands in ST-3). Uses a `MockClient`
/// so no real network traffic is made.
void main() {
  group('ConnectionHealthMonitor', () {
    test('exposes initial state immediately after construction', () {
      final monitor = ConnectionHealthMonitor(
        baseUrl: 'https://api.example.com',
        httpClient: MockClient((_) async => http.Response('ok', 200)),
      );
      expect(monitor.currentState, ConnectionHealthState.initial);
      expect(monitor.stream, isA<Stream<ConnectionHealthState>>());
    });

    test('normalizes baseUrl trailing slash + healthPath leading slash', () {
      expect(
        () => ConnectionHealthMonitor(
          baseUrl: 'https://api.example.com/',
          healthPath: '/health',
          httpClient: MockClient((_) async => http.Response('ok', 200)),
        ),
        returnsNormally,
      );
    });

    test('start() is idempotent — second call is a no-op', () {
      final monitor = ConnectionHealthMonitor(
        baseUrl: 'https://api.example.com',
        httpClient: MockClient((_) async => http.Response('ok', 200)),
      );
      expect(monitor.start, returnsNormally);
      expect(monitor.start, returnsNormally);
    });

    test('any public method after dispose() throws StateError', () async {
      final monitor = ConnectionHealthMonitor(
        baseUrl: 'https://api.example.com',
        httpClient: MockClient((_) async => http.Response('ok', 200)),
      );
      await monitor.dispose();
      expect(monitor.start, throwsA(isA<StateError>()));
      expect(monitor.stop, throwsA(isA<StateError>()));
      expect(monitor.checkNow, throwsA(isA<StateError>()));
      // dispose() itself is idempotent — second call is a no-op, not a throw.
      await monitor.dispose();
    });
  });
}
