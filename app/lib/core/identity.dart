/// Device identity, trust list and pairing-payload value types
/// (docs/PROTOCOL.md §8). Pure Dart — **no Flutter and no crypto imports**.
///
/// Public keys travel as base64url strings (the wire form); signing and
/// verification live in `services/crypto_service.dart`. These types only carry
/// and (de)serialize the data; they never touch a private key.
library;

import 'dart:convert';

/// Whether a device acts as the camera or a parent in the trust model (§8).
enum DeviceRole {
  camera,
  parent;

  /// Parses the wire string (`"camera"` | `"parent"`).
  static DeviceRole fromWire(String value) => switch (value) {
        'camera' => DeviceRole.camera,
        'parent' => DeviceRole.parent,
        _ => throw FormatException('unknown device role "$value"'),
      };

  /// The wire string for this role.
  String get wire => name;
}

/// This device's public identity: the 16-hex [deviceId] (§5.3), a display
/// [name] and its base64url Ed25519 [publicKey] (§8).
class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceId,
    required this.name,
    required this.publicKey,
  });

  final String deviceId;
  final String name;

  /// base64url-encoded 32-byte Ed25519 public key.
  final String publicKey;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'pk': publicKey,
      };

  factory DeviceIdentity.fromJson(Map<String, dynamic> json) => DeviceIdentity(
        deviceId: json['deviceId'] as String,
        name: json['name'] as String,
        publicKey: json['pk'] as String,
      );

  DeviceIdentity copyWith({String? name}) => DeviceIdentity(
        deviceId: deviceId,
        name: name ?? this.name,
        publicKey: publicKey,
      );

  @override
  bool operator ==(Object other) =>
      other is DeviceIdentity &&
      other.deviceId == deviceId &&
      other.name == name &&
      other.publicKey == publicKey;

  @override
  int get hashCode => Object.hash(deviceId, name, publicKey);
}

/// One entry in a device's trust store (§8): the peer's identity plus the role
/// it plays and when it was added. Public data — safe to keep in normal
/// preferences.
class TrustedDevice {
  const TrustedDevice({
    required this.deviceId,
    required this.name,
    required this.pk,
    required this.role,
    required this.addedAt,
  });

  final String deviceId;
  final String name;

  /// base64url-encoded 32-byte Ed25519 public key.
  final String pk;
  final DeviceRole role;
  final DateTime addedAt;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'pk': pk,
        'role': role.wire,
        'addedAt': addedAt.toUtc().toIso8601String(),
      };

  factory TrustedDevice.fromJson(Map<String, dynamic> json) => TrustedDevice(
        deviceId: json['deviceId'] as String,
        name: json['name'] as String,
        pk: json['pk'] as String,
        role: DeviceRole.fromWire(json['role'] as String),
        addedAt: DateTime.parse(json['addedAt'] as String),
      );

  TrustedDevice copyWith({String? name}) => TrustedDevice(
        deviceId: deviceId,
        name: name ?? this.name,
        pk: pk,
        role: role,
        addedAt: addedAt,
      );

  @override
  bool operator ==(Object other) =>
      other is TrustedDevice &&
      other.deviceId == deviceId &&
      other.name == name &&
      other.pk == pk &&
      other.role == role &&
      other.addedAt == addedAt;

  @override
  int get hashCode => Object.hash(deviceId, name, pk, role, addedAt);
}

/// The QR payload a camera shows in pairing mode (§8.1):
/// `{"v":1,"t":"pair","deviceId":…,"name":…,"pk":…,"port":…,"addrs":[…],"token":…}`.
///
/// [parse] enforces the version and message-type discriminator so a scanner
/// rejects a QR from an incompatible build (or a non-pairing QR) up front.
class PairingPayload {
  const PairingPayload({
    required this.deviceId,
    required this.name,
    required this.pk,
    required this.port,
    required this.addrs,
    required this.token,
  });

  /// Wire version understood by this build.
  static const int currentVersion = 1;

  /// Message-type discriminator inside the QR JSON.
  static const String type = 'pair';

  final String deviceId;
  final String name;

  /// base64url-encoded 32-byte Ed25519 public key of the camera.
  final String pk;

  /// The camera's LAN signaling port (§7).
  final int port;

  /// Candidate LAN host addresses (IPv4/IPv6) the parent can dial directly.
  final List<String> addrs;

  /// One-time pairing token (base64url, 5-minute TTL, single use — §8.1).
  final String token;

  Map<String, dynamic> toJson() => {
        'v': currentVersion,
        't': type,
        'deviceId': deviceId,
        'name': name,
        'pk': pk,
        'port': port,
        'addrs': addrs,
        'token': token,
      };

  /// Serializes to the compact JSON string encoded into the QR code.
  String serialize() => jsonEncode(toJson());

  /// A compact, typeable pairing code carrying the exact same data as the QR:
  /// base64url (unpadded) of [serialize], prefixed with `BM1-` so a human can
  /// recognise it. Used for manual "enter a code" pairing when scanning is
  /// impractical (e.g. joining from an emulator). Because it carries the same
  /// [pk] as the QR, typing it preserves the QR's MITM-resistance (§8.1).
  String encodeCompact() {
    final bytes = utf8.encode(serialize());
    return 'BM1-${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  /// The camera's own identity as advertised in this payload.
  DeviceIdentity get identity =>
      DeviceIdentity(deviceId: deviceId, name: name, publicKey: pk);

  /// Parses a scanned QR string. Throws [FormatException] when the JSON is
  /// malformed, the version is unsupported, the type is not `pair`, or a
  /// required field is missing/mistyped.
  factory PairingPayload.parse(String source) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(source);
    } catch (e) {
      throw FormatException('pairing payload is not valid JSON: $e', source);
    }
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('pairing payload is not a JSON object', source);
    }
    final version = decoded['v'];
    if (version != currentVersion) {
      throw FormatException(
          'unsupported pairing version $version (expected $currentVersion)',
          source);
    }
    if (decoded['t'] != type) {
      throw FormatException(
          'not a pairing payload (t=${decoded['t']})', source);
    }
    final deviceId = decoded['deviceId'];
    final name = decoded['name'];
    final pk = decoded['pk'];
    final port = decoded['port'];
    final token = decoded['token'];
    if (deviceId is! String ||
        name is! String ||
        pk is! String ||
        port is! int ||
        token is! String) {
      throw FormatException('pairing payload has missing/invalid fields', source);
    }
    final rawAddrs = decoded['addrs'];
    final addrs = rawAddrs is List
        ? rawAddrs.whereType<String>().toList(growable: false)
        : const <String>[];
    return PairingPayload(
      deviceId: deviceId,
      name: name,
      pk: pk,
      port: port,
      addrs: addrs,
      token: token,
    );
  }

  /// Parses either a raw QR payload (JSON from [serialize]) or a compact code
  /// from [encodeCompact] that was typed/pasted by hand. Surrounding
  /// whitespace, an optional `BM1-` prefix, and missing base64 padding are all
  /// tolerated. Throws [FormatException] on anything else.
  factory PairingPayload.parseFlexible(String source) {
    var text = source.trim();
    if (text.isEmpty) {
      throw const FormatException('empty pairing code');
    }
    // A raw QR payload is JSON — hand it to the strict parser unchanged.
    if (text.startsWith('{')) return PairingPayload.parse(text);
    // Otherwise treat it as a compact base64url code (optionally BM1-prefixed).
    if (text.startsWith('BM1-')) text = text.substring(4);
    text = text.replaceAll(RegExp(r'\s'), '');
    // Restore the '=' padding the compact encoder strips.
    final padded = text.padRight((text.length + 3) ~/ 4 * 4, '=');
    final String json;
    try {
      json = utf8.decode(base64Url.decode(padded));
    } catch (_) {
      throw FormatException('not a valid pairing code', source);
    }
    return PairingPayload.parse(json);
  }
}
