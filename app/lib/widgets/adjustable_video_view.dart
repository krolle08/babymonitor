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
    this.onMeter,
    this.meteringPoint,
  });

  final RTCVideoRenderer renderer;

  /// Picture gain, -1.0 … 1.0 (0.0 = untouched).
  final double brightness;

  /// Night render curve: extra gain, lifted blacks, desaturated.
  final bool nightMode;

  final RTCVideoViewObjectFit objectFit;
  final bool mirror;

  /// Long-press to meter the exposure there (F15). The point handed over is
  /// in *frame* coordinates, letterboxing and cropping already accounted for;
  /// a long-press on a black bar is swallowed rather than mis-metered.
  final ValueChanged<MeteringPoint>? onMeter;

  /// The metering point in force, drawn as a marker so it is visible where
  /// the camera is currently pointing its exposure.
  final MeteringPoint? meteringPoint;

  bool get _cover => objectFit == RTCVideoViewObjectFit.RTCVideoViewObjectFitCover;

  @override
  Widget build(BuildContext context) {
    Widget video = RTCVideoView(renderer, mirror: mirror, objectFit: objectFit);
    // A colour filter costs a save layer every frame — skip it when the
    // settings are neutral, which is the common daytime case.
    if (!isNeutralVideoAdjustment(brightness: brightness, nightMode: nightMode)) {
      video = ColorFiltered(
        colorFilter: ColorFilter.matrix(
          videoColorMatrix(brightness: brightness, nightMode: nightMode),
        ),
        child: video,
      );
    }
    if (onMeter == null && meteringPoint == null) return video;

    return LayoutBuilder(
      builder: (context, constraints) {
        final videoWidth = renderer.videoWidth.toDouble();
        final videoHeight = renderer.videoHeight.toDouble();
        final marker = meteringPoint == null
            ? null
            : _markerOffset(
                point: meteringPoint!,
                widgetWidth: constraints.maxWidth,
                widgetHeight: constraints.maxHeight,
                videoWidth: videoWidth,
                videoHeight: videoHeight,
              );
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onLongPressStart: onMeter == null
              ? null
              : (details) {
                  final point = mapTapToFrame(
                    tapX: details.localPosition.dx,
                    tapY: details.localPosition.dy,
                    widgetWidth: constraints.maxWidth,
                    widgetHeight: constraints.maxHeight,
                    videoWidth: videoWidth,
                    videoHeight: videoHeight,
                    cover: _cover,
                  );
                  if (point != null) onMeter!(point);
                },
          child: Stack(
            fit: StackFit.expand,
            children: [
              video,
              if (marker != null)
                Positioned(
                  left: marker.dx - 22,
                  top: marker.dy - 22,
                  child: const _MeteringMarker(),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Inverse of [mapTapToFrame]: frame coordinates back to widget pixels.
  Offset? _markerOffset({
    required MeteringPoint point,
    required double widgetWidth,
    required double widgetHeight,
    required double videoWidth,
    required double videoHeight,
  }) {
    if (widgetWidth <= 0 || widgetHeight <= 0) return null;
    if (videoWidth <= 0 || videoHeight <= 0) return null;
    final widgetAspect = widgetWidth / widgetHeight;
    final videoAspect = videoWidth / videoHeight;
    final scale = (videoAspect > widgetAspect) == _cover
        ? widgetHeight / videoHeight
        : widgetWidth / videoWidth;
    final drawnWidth = videoWidth * scale;
    final drawnHeight = videoHeight * scale;
    return Offset(
      (widgetWidth - drawnWidth) / 2 + point.x * drawnWidth,
      (widgetHeight - drawnHeight) / 2 + point.y * drawnHeight,
    );
  }
}

/// Small reticle showing where the exposure is being metered (F15).
class _MeteringMarker extends StatelessWidget {
  const _MeteringMarker();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xCCFCD34D), width: 2),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Center(
          child: Icon(Icons.center_focus_strong_outlined,
              size: 16, color: Color(0xCCFCD34D)),
        ),
      ),
    );
  }
}
