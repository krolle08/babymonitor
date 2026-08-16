/// Video surface that renders with the session's brightness / night curve
/// (F15, docs/PROTOCOL.md §4).
///
/// Both roles use it, with the same [CameraControls] values, so what the
/// camera operator frames while setting up is what the parents will see.
library;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/camera_controls.dart';

class AdjustableVideoView extends StatelessWidget {
  const AdjustableVideoView({
    super.key,
    required this.renderer,
    required this.brightness,
    required this.nightMode,
    this.objectFit = RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    this.mirror = false,
  });

  final RTCVideoRenderer renderer;

  /// Picture gain, -1.0 … 1.0 (0.0 = untouched).
  final double brightness;

  /// Night render curve: extra gain, lifted blacks, desaturated.
  final bool nightMode;

  final RTCVideoViewObjectFit objectFit;
  final bool mirror;

  @override
  Widget build(BuildContext context) {
    final video = RTCVideoView(renderer, mirror: mirror, objectFit: objectFit);
    // A colour filter costs a save layer every frame — skip it when the
    // settings are neutral, which is the common daytime case.
    if (isNeutralVideoAdjustment(brightness: brightness, nightMode: nightMode)) {
      return video;
    }
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(
        videoColorMatrix(brightness: brightness, nightMode: nightMode),
      ),
      child: video,
    );
  }
}
