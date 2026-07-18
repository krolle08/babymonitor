/// mDNS / DNS-SD advertise + discovery (docs/PROTOCOL.md §7, TR9).
///
/// The camera advertises `_babymonitor._tcp` with TXT records
/// `id`/`name`/`proto`/`port`; parents scan for it on a short budget and get
/// back resolved LAN endpoints. Thin wrapper over `bonsoir` — never throws to
/// callers (NTR3): advertise failures are logged, discovery failures yield an
/// empty result.
library;

import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// A camera found on the local network, resolved to a dialable endpoint.
class DiscoveredCamera {
  const DiscoveredCamera({
    required this.deviceId,
    required this.name,
    required this.host,
    required this.port,
  });

  final String deviceId;
  final String name;
  final String host;
  final int port;

  /// The §7 LAN signaling URL for this camera.
  String get wsUrl => 'ws://$host:$port/ws';

  @override
  String toString() => 'DiscoveredCamera($deviceId, $name, $host:$port)';
}

class DiscoveryService {
  /// The DNS-SD service type (§7).
  static const String serviceType = '_babymonitor._tcp';

  BonsoirBroadcast? _broadcast;

  /// Advertises this camera's LAN signaling endpoint. Replaces any previous
  /// advertisement. Failures are logged, not thrown.
  Future<void> advertise({
    required String deviceId,
    required String name,
    required int port,
  }) async {
    await stopAdvertising();
    try {
      final service = BonsoirService(
        name: name,
        type: serviceType,
        port: port,
        attributes: {
          'id': deviceId,
          'name': name,
          'proto': '1',
          'port': '$port',
        },
      );
      final broadcast = BonsoirBroadcast(service: service);
      await broadcast.initialize();
      await broadcast.start();
      _broadcast = broadcast;
    } catch (e) {
      debugPrint('DiscoveryService: advertise failed: $e');
    }
  }

  Future<void> stopAdvertising() async {
    final broadcast = _broadcast;
    _broadcast = null;
    if (broadcast == null) return;
    try {
      await broadcast.stop();
    } catch (e) {
      debugPrint('DiscoveryService: stop advertise failed: $e');
    }
  }

  /// Scans for cameras for [budget] and returns the resolved endpoints,
  /// deduplicated by deviceId. Never throws — returns `[]` on any failure.
  Future<List<DiscoveredCamera>> discover({
    Duration budget = const Duration(seconds: 2),
  }) async {
    BonsoirDiscovery? discovery;
    StreamSubscription<BonsoirDiscoveryEvent>? sub;
    final found = <String, DiscoveredCamera>{};
    try {
      discovery = BonsoirDiscovery(type: serviceType);
      await discovery.initialize();
      final resolver = discovery.serviceResolver;
      sub = discovery.eventStream!.listen((event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent():
            // Resolve to obtain host addresses + port (§7).
            unawaited(_safeResolve(resolver, event.service));
          case BonsoirDiscoveryServiceResolvedEvent():
            final camera = _toCamera(event.service);
            if (camera != null) found[camera.deviceId] = camera;
          default:
            break;
        }
      });
      await discovery.start();
      await Future<void>.delayed(budget);
    } catch (e) {
      debugPrint('DiscoveryService: discover failed: $e');
    } finally {
      await sub?.cancel();
      try {
        await discovery?.stop();
      } catch (_) {}
    }
    return found.values.toList(growable: false);
  }

  Future<void> _safeResolve(
      ServiceResolver resolver, BonsoirService service) async {
    try {
      await resolver.resolveService(service);
    } catch (e) {
      debugPrint('DiscoveryService: resolve failed: $e');
    }
  }

  DiscoveredCamera? _toCamera(BonsoirService service) {
    final attrs = service.attributes;
    final deviceId = attrs['id'];
    final host = service.hostAddress;
    if (deviceId == null || deviceId.isEmpty || host == null || host.isEmpty) {
      return null; // not one of ours, or not fully resolved yet
    }
    return DiscoveredCamera(
      deviceId: deviceId,
      name: attrs['name'] ?? service.name,
      host: host,
      port: service.port,
    );
  }

  Future<void> dispose() async {
    await stopAdvertising();
  }
}
