import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';

/// Small local camera floating over the stage, like the reference classroom's
/// tutor camera. Hidden when the local camera is off or only one person is in
/// the room (the main tile already shows them).
class RealtimeSelfView extends StatelessWidget {
  const RealtimeSelfView({
    super.key,
    required this.participant,
    required this.renderer,
    this.width,
    this.fit = BoxFit.contain,
    this.onTap,
  });

  final MediaParticipant participant;
  final MediaTrackRenderer renderer;
  final double? width;
  final BoxFit fit;
  final VoidCallback? onTap;

  double _tileAspectRatio(MediaVideoTrack track) {
    if (fit == BoxFit.contain && track.width > 0 && track.height > 0) {
      return (track.width / track.height).clamp(0.56, 1.78);
    }
    return 4 / 3;
  }

  @override
  Widget build(BuildContext context) {
    if (!participant.isVideoEnabled || participant.videoTrack == null) {
      return const SizedBox.shrink();
    }
    final style = RealtimeStyle.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final effectiveWidth =
            width ?? (constraints.maxWidth * 0.28).clamp(120.0, 220.0);
        return Semantics(
          label: participant.displayName,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              width: effectiveWidth,
              decoration: BoxDecoration(
                color: style.tile,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: style.speak, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF101828).withValues(alpha: .18),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: AspectRatio(
                  aspectRatio: _tileAspectRatio(participant.videoTrack!),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      MediaTrackView(
                        renderer: renderer,
                        track: participant.videoTrack,
                        fit: fit,
                        rendererManagesFit: renderer.handlesVideoFit(
                          participant.videoTrack!,
                        ),
                      ),
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFF0C121C,
                            ).withValues(alpha: .62),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            RealtimeStrings.of(context).isZh
                                ? '${participant.displayName}（你）'
                                : '${participant.displayName} (you)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
