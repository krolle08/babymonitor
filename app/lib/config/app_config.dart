/// All tunable thresholds for the baby monitor live in this single file (NTR5).
/// Values mirror spec.md TR4 unless noted.
library;

class AppConfig {
  AppConfig._();

  // --- Health check (TR4) ---
  static const Duration heartbeatInterval = Duration(seconds: 3);
  static const int degradedAfterMissed = 1; // 1–2 missed → DEGRADED
  static const int reconnectingAfterMissed = 3; // 3+ missed → RECONNECTING
  static const Duration freezeSampleInterval = Duration(seconds: 5);
  static const int freezeIdenticalSamples = 2; // 2 identical → FROZEN
  static const int maxReconnectRetries = 5;
  static const List<int> backoffScheduleSeconds = [3, 6, 12, 30]; // last repeats

  // --- Noise alert (F7) ---
  static const Duration noiseCooldown = Duration(seconds: 30);
  static const Map<String, double> noiseThresholds = {
    'low': 0.50, // low sensitivity → only loud sounds alert
    'medium': 0.30,
    'high': 0.15, // high sensitivity → quiet sounds alert
  };
  static const String defaultNoiseSensitivity = 'medium';

  // --- Latency (F1) ---
  static const int latencyAlertMs = 5000;

  // --- Rooms ---
  static const int maxParentsPerRoom = 4;

  // --- Defaults for runtime settings (overridable in Settings screen) ---
  static const String defaultSignalingUrl = 'wss://localhost:8080/ws';
  static const String defaultApiBaseUrl = 'https://localhost:8080';
  static const String defaultStunUrl = 'stun:stun.cloudflare.com:3478';

  // --- Sleep log upload ---
  static const Duration logFlushInterval = Duration(seconds: 30);
  static const int logBatchMax = 100;
}
