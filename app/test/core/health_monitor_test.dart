import 'package:babymonitor/core/health_monitor.dart';
import 'package:babymonitor/core/health_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mutable fake clock driving the monitor (no timers inside the class).
class FakeClock {
  FakeClock(this.now);
  DateTime now;
  void advance(Duration d) => now = now.add(d);
  void advanceSeconds(int s) => advance(Duration(seconds: s));
}

/// Flush the async stream-event queue so emissions can be asserted.
Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeClock clock;
  late HealthMonitor monitor;
  late List<HealthState> emitted;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 1, 1, 20, 0, 0));
    monitor = HealthMonitor(now: () => clock.now);
    emitted = [];
    monitor.states.listen(emitted.add);
  });

  tearDown(() => monitor.dispose());

  /// Get the monitor into CONNECTED with a heartbeat just received.
  void connect() {
    monitor.onHeartbeat(0);
    expect(monitor.state, HealthState.connected);
  }

  group('initial state and first heartbeat', () {
    test('starts in connecting', () {
      expect(monitor.state, HealthState.connecting);
    });

    test('first heartbeat -> connected', () async {
      monitor.onHeartbeat(1);
      expect(monitor.state, HealthState.connected);
      await flush();
      expect(emitted, [HealthState.connected]);
    });

    test('tick while connecting does nothing', () {
      monitor.tick();
      clock.advanceSeconds(60);
      monitor.tick();
      expect(monitor.state, HealthState.connecting);
    });
  });

  group('F3 missed-heartbeat table (1-2 missed -> DEGRADED, 3+ -> RECONNECTING)',
      () {
    test('0 missed (<3s gap): stays connected', () {
      connect();
      clock.advance(const Duration(milliseconds: 2999));
      monitor.tick();
      expect(monitor.state, HealthState.connected);
    });

    test('1 missed (3s gap): connected -> degraded, silently', () async {
      connect();
      clock.advanceSeconds(3);
      monitor.tick();
      expect(monitor.state, HealthState.degraded);
      await flush();
      expect(emitted, [HealthState.connected, HealthState.degraded]);
    });

    test('2 missed (6s gap): still degraded, not reconnecting', () {
      connect();
      clock.advanceSeconds(6);
      monitor.tick();
      expect(monitor.state, HealthState.degraded);
      clock.advance(const Duration(milliseconds: 2999)); // 8.999s total
      monitor.tick();
      expect(monitor.state, HealthState.degraded);
    });

    test('3 missed (9s gap): -> reconnecting', () {
      connect();
      clock.advanceSeconds(9);
      monitor.tick();
      expect(monitor.state, HealthState.reconnecting);
    });

    test('3+ missed reached from degraded as ticks accumulate', () async {
      connect();
      clock.advanceSeconds(3);
      monitor.tick(); // degraded
      clock.advanceSeconds(3);
      monitor.tick(); // 2 missed, still degraded
      expect(monitor.state, HealthState.degraded);
      clock.advanceSeconds(3);
      monitor.tick(); // 3 missed
      expect(monitor.state, HealthState.reconnecting);
      await flush();
      expect(emitted, [
        HealthState.connected,
        HealthState.degraded,
        HealthState.reconnecting,
      ]);
    });

    test('jumping straight past both thresholds picks reconnecting', () {
      connect();
      clock.advanceSeconds(100);
      monitor.tick();
      expect(monitor.state, HealthState.reconnecting);
    });
  });

  group('heartbeat resume', () {
    test('degraded -> connected on heartbeat', () async {
      connect();
      clock.advanceSeconds(4);
      monitor.tick();
      expect(monitor.state, HealthState.degraded);
      monitor.onHeartbeat(2);
      expect(monitor.state, HealthState.connected);
      // Fresh heartbeat: an immediate tick stays connected.
      monitor.tick();
      expect(monitor.state, HealthState.connected);
      await flush();
      expect(emitted, [
        HealthState.connected,
        HealthState.degraded,
        HealthState.connected,
      ]);
    });

    test('reconnecting -> connected on heartbeat', () {
      connect();
      clock.advanceSeconds(10);
      monitor.tick();
      expect(monitor.state, HealthState.reconnecting);
      monitor.onHeartbeat(3);
      expect(monitor.state, HealthState.connected);
    });
  });

  group('freeze (F5)', () {
    test('connected -> frozen on freeze detection', () {
      connect();
      monitor.onFreezeDetected();
      expect(monitor.state, HealthState.frozen);
    });

    test('degraded -> frozen on freeze detection', () {
      connect();
      clock.advanceSeconds(3);
      monitor.tick();
      expect(monitor.state, HealthState.degraded);
      monitor.onFreezeDetected();
      expect(monitor.state, HealthState.frozen);
    });

    test('frozen is NOT cleared by heartbeats (stream alive, picture frozen)',
        () async {
      connect();
      monitor.onFreezeDetected();
      monitor.onHeartbeat(2);
      monitor.onHeartbeat(3);
      expect(monitor.state, HealthState.frozen);
      await flush();
      expect(emitted, [HealthState.connected, HealthState.frozen]);
    });

    test('tick does not leave frozen', () {
      connect();
      monitor.onFreezeDetected();
      clock.advanceSeconds(30);
      monitor.tick();
      expect(monitor.state, HealthState.frozen);
    });

    test('frozen -> connected on freeze recovery', () {
      connect();
      monitor.onFreezeDetected();
      monitor.onFreezeRecovered();
      expect(monitor.state, HealthState.connected);
    });

    test('freeze recovery in a non-frozen state is ignored', () {
      connect();
      monitor.onFreezeRecovered();
      expect(monitor.state, HealthState.connected);
    });

    test('freeze detection ignored while reconnecting or failed', () {
      connect();
      clock.advanceSeconds(10);
      monitor.tick();
      expect(monitor.state, HealthState.reconnecting);
      monitor.onFreezeDetected();
      expect(monitor.state, HealthState.reconnecting);
      monitor.onReconnectExhausted();
      monitor.onFreezeDetected();
      expect(monitor.state, HealthState.failed);
    });
  });

  group('failed (F4) — terminal until manual reset', () {
    test('onReconnectExhausted -> failed from every state', () {
      for (final setup in <void Function(HealthMonitor, FakeClock)>[
        (m, c) {}, // connecting
        (m, c) => m.onHeartbeat(0), // connected
        (m, c) {
          m.onHeartbeat(0);
          c.advanceSeconds(3);
          m.tick(); // degraded
        },
        (m, c) {
          m.onHeartbeat(0);
          c.advanceSeconds(9);
          m.tick(); // reconnecting
        },
        (m, c) {
          m.onHeartbeat(0);
          m.onFreezeDetected(); // frozen
        },
      ]) {
        final c = FakeClock(DateTime.utc(2026, 1, 1));
        final m = HealthMonitor(now: () => c.now);
        setup(m, c);
        m.onReconnectExhausted();
        expect(m.state, HealthState.failed);
        m.dispose();
      }
    });

    test('failed is not left by heartbeat, tick, freeze or reconnect events',
        () {
      connect();
      monitor.onReconnectExhausted();
      monitor.onHeartbeat(9);
      expect(monitor.state, HealthState.failed);
      clock.advanceSeconds(5);
      monitor.tick();
      expect(monitor.state, HealthState.failed);
      monitor.onFreezeDetected();
      monitor.onFreezeRecovered();
      monitor.onReconnected();
      expect(monitor.state, HealthState.failed);
    });

    test('manualReset: failed -> connecting, then first heartbeat reconnects',
        () async {
      connect();
      monitor.onReconnectExhausted();
      monitor.manualReset();
      expect(monitor.state, HealthState.connecting);
      // Heartbeat history was cleared: tick does nothing until a heartbeat.
      clock.advanceSeconds(60);
      monitor.tick();
      expect(monitor.state, HealthState.connecting);
      monitor.onHeartbeat(0);
      expect(monitor.state, HealthState.connected);
      await flush();
      expect(emitted, [
        HealthState.connected,
        HealthState.failed,
        HealthState.connecting,
        HealthState.connected,
      ]);
    });
  });

  group('onReconnected', () {
    test('reconnecting -> connected', () {
      connect();
      clock.advanceSeconds(9);
      monitor.tick();
      expect(monitor.state, HealthState.reconnecting);
      monitor.onReconnected();
      expect(monitor.state, HealthState.connected);
      // Liveness refreshed: an immediate tick must not bounce back.
      monitor.tick();
      expect(monitor.state, HealthState.connected);
    });

    test('ignored outside reconnecting', () {
      connect();
      monitor.onReconnected();
      expect(monitor.state, HealthState.connected);
      monitor.onFreezeDetected();
      monitor.onReconnected();
      expect(monitor.state, HealthState.frozen);
    });
  });

  group('stream behaviour', () {
    test('emits on change only — no duplicate emissions', () async {
      connect();
      monitor.onHeartbeat(1);
      monitor.onHeartbeat(2);
      monitor.tick();
      monitor.tick();
      clock.advanceSeconds(3);
      monitor.tick();
      monitor.tick(); // still degraded, no second emission
      await flush();
      expect(emitted, [HealthState.connected, HealthState.degraded]);
    });

    test('stream is broadcast — supports multiple listeners', () async {
      final second = <HealthState>[];
      monitor.states.listen(second.add);
      connect();
      await flush();
      expect(emitted, [HealthState.connected]);
      expect(second, [HealthState.connected]);
    });
  });

  test('custom thresholds are honoured', () {
    final c = FakeClock(DateTime.utc(2026, 1, 1));
    final m = HealthMonitor(
      now: () => c.now,
      heartbeatInterval: const Duration(seconds: 1),
      degradedAfterMissed: 2,
      reconnectingAfterMissed: 4,
    );
    m.onHeartbeat(0);
    c.advanceSeconds(1);
    m.tick(); // 1 missed < 2
    expect(m.state, HealthState.connected);
    c.advanceSeconds(1);
    m.tick(); // 2 missed
    expect(m.state, HealthState.degraded);
    c.advanceSeconds(2);
    m.tick(); // 4 missed
    expect(m.state, HealthState.reconnecting);
    m.dispose();
  });
}
