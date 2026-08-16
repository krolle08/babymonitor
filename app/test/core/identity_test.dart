import 'dart:convert';

import 'package:babymonitor/core/identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeviceRole', () {
    test('round-trips via wire strings', () {
      expect(DeviceRole.fromWire('camera'), DeviceRole.camera);
      expect(DeviceRole.fromWire('parent'), DeviceRole.parent);
      expect(DeviceRole.camera.wire, 'camera');
      expect(DeviceRole.parent.wire, 'parent');
    });

    test('rejects an unknown role', () {
      expect(() => DeviceRole.fromWire('server'), throwsFormatException);
    });
  });

  group('DeviceIdentity', () {
    test('JSON round-trip preserves every field', () {
      const identity = DeviceIdentity(
        deviceId: 'a1b2c3d4e5f60718',
        name: "Mom's phone",
        publicKey: 'cHVibGljLWtleQ',
      );
      final restored = DeviceIdentity.fromJson(
          jsonDecode(jsonEncode(identity.toJson())) as Map<String, dynamic>);
      expect(restored, identity);
      expect(restored.toJson()['pk'], 'cHVibGljLWtleQ');
    });
  });

  group('TrustedDevice', () {
    test('JSON round-trip preserves role + addedAt', () {
      final device = TrustedDevice(
        deviceId: 'deadbeefdeadbeef',
        name: "Dad's phone",
        pk: 'a2V5',
        role: DeviceRole.parent,
        addedAt: DateTime.utc(2026, 7, 18, 21, 30),
      );
      final restored = TrustedDevice.fromJson(
          jsonDecode(jsonEncode(device.toJson())) as Map<String, dynamic>);
      expect(restored, device);
    });

    test('copyWith renames without touching identity', () {
      final device = TrustedDevice(
        deviceId: 'deadbeefdeadbeef',
        name: 'old',
        pk: 'a2V5',
        role: DeviceRole.camera,
        addedAt: DateTime.utc(2026, 1, 1),
      );
      final renamed = device.copyWith(name: 'Nursery camera');
      expect(renamed.name, 'Nursery camera');
      expect(renamed.deviceId, device.deviceId);
      expect(renamed.pk, device.pk);
      expect(renamed.role, device.role);
      expect(renamed.addedAt, device.addedAt);
    });
  });

  group('PairingPayload', () {
    const payload = PairingPayload(
      deviceId: 'cam0cam0cam0cam0',
      name: 'Nursery',
      pk: 'Y2FtLWtleQ',
      port: 47800,
      addrs: ['192.168.1.42', '10.0.0.9'],
      token: 'dG9rZW4',
    );

    test('serialize/parse round-trip', () {
      final parsed = PairingPayload.parse(payload.serialize());
      expect(parsed.deviceId, payload.deviceId);
      expect(parsed.name, payload.name);
      expect(parsed.pk, payload.pk);
      expect(parsed.port, payload.port);
      expect(parsed.addrs, payload.addrs);
      expect(parsed.token, payload.token);
      expect(parsed.identity.deviceId, payload.deviceId);
      expect(parsed.identity.publicKey, payload.pk);
    });

    test('serialized JSON carries version + type discriminators', () {
      final map = jsonDecode(payload.serialize()) as Map<String, dynamic>;
      expect(map['v'], PairingPayload.currentVersion);
      expect(map['t'], 'pair');
    });

    test('rejects malformed JSON', () {
      expect(() => PairingPayload.parse('not json'), throwsFormatException);
      expect(() => PairingPayload.parse('[]'), throwsFormatException);
    });

    test('rejects an unsupported version', () {
      final future = jsonEncode({
        'v': 99,
        't': 'pair',
        'deviceId': 'x',
        'name': 'x',
        'pk': 'x',
        'port': 1,
        'addrs': <String>[],
        'token': 'x',
      });
      expect(() => PairingPayload.parse(future), throwsFormatException);
    });

    test('rejects a non-pairing type', () {
      final other = jsonEncode({
        'v': 1,
        't': 'hello',
        'deviceId': 'x',
        'name': 'x',
        'pk': 'x',
        'port': 1,
        'token': 'x',
      });
      expect(() => PairingPayload.parse(other), throwsFormatException);
    });

    test('rejects missing/mistyped required fields', () {
      final badPort = jsonEncode({
        'v': 1,
        't': 'pair',
        'deviceId': 'x',
        'name': 'x',
        'pk': 'x',
        'port': '47800', // string, not int
        'token': 'x',
      });
      expect(() => PairingPayload.parse(badPort), throwsFormatException);
    });

    test('tolerates a missing addrs list (defaults to empty)', () {
      final noAddrs = jsonEncode({
        'v': 1,
        't': 'pair',
        'deviceId': 'x',
        'name': 'x',
        'pk': 'x',
        'port': 47800,
        'token': 'x',
      });
      expect(PairingPayload.parse(noAddrs).addrs, isEmpty);
    });

    test('encodeCompact/parseFlexible round-trip (manual entry)', () {
      final code = payload.encodeCompact();
      expect(code, startsWith('BM1-'));
      // Typeable: no JSON punctuation or base64 padding to trip up a user.
      expect(code.contains('{'), isFalse);
      expect(code.contains('='), isFalse);
      final parsed = PairingPayload.parseFlexible(code);
      expect(parsed.deviceId, payload.deviceId);
      expect(parsed.pk, payload.pk);
      expect(parsed.port, payload.port);
      expect(parsed.addrs, payload.addrs);
      expect(parsed.token, payload.token);
    });

    test('parseFlexible also accepts a raw QR payload and tolerates spacing',
        () {
      final fromJson = PairingPayload.parseFlexible(payload.serialize());
      expect(fromJson.deviceId, payload.deviceId);
      // Surrounding whitespace (e.g. from a clipboard) is trimmed.
      final padded = PairingPayload.parseFlexible('  ${payload.encodeCompact()}\n');
      expect(padded.token, payload.token);
    });

    test('parseFlexible rejects gibberish and empty input', () {
      expect(() => PairingPayload.parseFlexible(''), throwsFormatException);
      expect(() => PairingPayload.parseFlexible('   '), throwsFormatException);
      expect(
          () => PairingPayload.parseFlexible('BM1-not*valid*base64'),
          throwsFormatException);
    });
  });
}
