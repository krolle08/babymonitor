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

  // --- Sound filter (F13: ignore snoring, breathing, the fan) ---
  /// The bar a sound must clear, when no preset/custom value is stored.
  static const double defaultNoiseThreshold = 0.30; // == 'medium'
  static const double minNoiseThreshold = 0.05;
  static const double maxNoiseThreshold = 0.95;

  /// How long a sound must hold above the bar before it alerts. A snore burst
  /// is 1–2 s; 2 s still leaves headroom inside the F7 "alert within 5 s" AC.
  static const Duration defaultNoiseSustain = Duration(seconds: 2);
  static const Duration maxNoiseSustain = Duration(seconds: 15);

  /// Reject sound that only just clears the room's learned quiet floor.
  static const bool defaultIgnoreSteadySound = true;

  /// How far above the learned quiet floor a sound must be to count.
  static const double steadySoundMargin = 0.08;

  /// EMA weight the quiet floor follows sub-threshold samples with (~20 s to
  /// settle at the 1 s sampling interval).
  static const double quietFloorAlpha = 0.05;

  /// How long the parent keeps hearing the room after it goes quiet again
  /// (the squelch's hang time — stops the speaker chattering between sobs).
  static const Duration defaultAudioHang = Duration(seconds: 15);
  static const Duration maxAudioHang = Duration(seconds: 120);

  /// A parent whose gate news is older than this stops trusting the squelch
  /// and opens the audio (NTR1: never go silently deaf).
  static const Duration audioGateStaleAfter = Duration(seconds: 10);

  /// Playback modes for the camera's audio on a parent device.
  static const String defaultListenMode = 'filtered';

  // --- Camera image controls (F15) ---
  /// Capture frame rate: normal, and in night mode (lower = longer exposure
  /// per frame, so a dim room is visibly brighter).
  static const int captureFrameRate = 15;
  static const int nightCaptureFrameRate = 8;

  /// Bounds for the night frame rate. 5 fps is about as low as it is worth
  /// going: below that the picture stops reading as live video.
  static const int minNightFrameRate = 5;
  static const int maxNightFrameRate = 15;

  /// Extra picture gain night mode starts from, -1.0 … 1.0.
  static const double nightModeBrightness = 0.35;

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
