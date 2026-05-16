import 'package:neo_connection_health_monitor/neo_connection_health_monitor.dart';
import 'package:test/test.dart';

/// ST-1 only seeds a smoke test that the skeleton compiles and the
/// public API surface exists. The full 14-case suite lands in ST-3.
void main() {
  group('ConnectionHealthMonitor (skeleton)', () {
    test('exposes initial state immediately after construction', () {
      final monitor = ConnectionHealthMonitor(
        baseUrl: 'https://api.example.com',
      );
      expect(monitor.currentState, ConnectionHealthState.initial);
      expect(monitor.stream, isA<Stream<ConnectionHealthState>>());
    });

    test('normalizes baseUrl trailing slash + healthPath leading slash', () {
      // Internal _uri is private; this test asserts the constructor does
      // not throw on the canonical "both slashes" combo. The full URL
      // shape is verified in ST-3 via injected http client.
      expect(
        () => ConnectionHealthMonitor(
          baseUrl: 'https://api.example.com/',
          healthPath: '/health',
        ),
        returnsNormally,
      );
    });

    test(
      'start/stop/dispose/checkNow throw UnimplementedError (ST-2 stub)',
      () {
        final monitor = ConnectionHealthMonitor(
          baseUrl: 'https://api.example.com',
        );
        expect(monitor.start, throwsA(isA<UnimplementedError>()));
        expect(monitor.stop, throwsA(isA<UnimplementedError>()));
        expect(monitor.dispose, throwsA(isA<UnimplementedError>()));
        expect(monitor.checkNow, throwsA(isA<UnimplementedError>()));
      },
    );
  });
}
