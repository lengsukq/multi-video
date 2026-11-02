import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'background_effect_selector.dart';
import 'composable_pre_join_controller.dart';
import 'media_background_image_preset.dart';
import 'realtime_strings.dart';
import 'realtime_ui_style.dart';

/// Shares one Pre-Join controller across freely arranged child widgets.
class RealtimePreJoinScope extends InheritedWidget {
  const RealtimePreJoinScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final RealtimePreJoinController controller;

  static RealtimePreJoinController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<RealtimePreJoinScope>();
    assert(
      scope != null,
      'A RealtimePreJoinScope is required above this component',
    );
    return scope!.controller;
  }

  static RealtimePreJoinController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<RealtimePreJoinScope>()
        ?.controller;
  }

  @override
  bool updateShouldNotify(RealtimePreJoinScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}

/// Displays only the SDK local preview, no fixed page or device panel.
class RealtimePreJoinPreview extends StatelessWidget {
  const RealtimePreJoinPreview({super.key, this.placeholder});
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    final controller = RealtimePreJoinScope.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final preview = controller.preview;
        if (preview == null) {
          return placeholder ??
              const Center(child: Icon(Icons.videocam_off_outlined, size: 56));
        }
        final camera = preview.cameraTrack;
        return MediaTrackView(
          renderer: preview.renderer,
          track: camera,
          fit: BoxFit.contain,
          // Native renderers (LiveKit/Agora/TRTC) know the decoded camera
          // orientation. Do not force stale landscape track metadata over
          // portrait iPhone frames; processed textures still use their own
          // explicit source dimensions.
          rendererManagesFit:
              camera != null && preview.renderer.handlesVideoFit(camera),
          placeholder:
              placeholder ??
              const Center(child: Icon(Icons.videocam_off_outlined, size: 56)),
        );
      },
    );
  }
}

/// Provider-agnostic backend, permission and device readiness checks.
class RealtimePreJoinCheckList extends StatelessWidget {
  const RealtimePreJoinCheckList({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = RealtimePreJoinScope.of(context);
    final strings = RealtimeStrings.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final checks = controller.result?.checks ?? const <MediaPreJoinCheck>[];
        if (controller.loading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (controller.error != null) {
          return Text(
            controller.error.toString(),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final check in checks)
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(
                  children: [
                    Icon(
                      check.passed
                          ? Icons.check_circle_rounded
                          : check.isBlocking
                          ? Icons.error_rounded
                          : Icons.info_outline_rounded,
                      size: 18,
                      color: check.passed
                          ? Theme.of(context).colorScheme.tertiary
                          : check.isBlocking
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        strings.preJoinCheckDescription(check),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (check.isBlocking)
                      Text(
                        strings.requiredLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// iOS-style expandable Readiness Card summarizing pre-join checks.
class RealtimePreJoinReadinessCard extends StatefulWidget {
  const RealtimePreJoinReadinessCard({
    super.key,
    this.initiallyExpanded = false,
    this.embedded = false,
  });

  final bool initiallyExpanded;

  /// Drops the card shell so the checks can live inside a combined settings
  /// card without a card-inside-card border.
  final bool embedded;

  @override
  State<RealtimePreJoinReadinessCard> createState() =>
      _RealtimePreJoinReadinessCardState();
}

class _RealtimePreJoinReadinessCardState
    extends State<RealtimePreJoinReadinessCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final controller = RealtimePreJoinScope.of(context);
    final strings = RealtimeStrings.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final result = controller.result;
        final checks = result?.checks ?? const <MediaPreJoinCheck>[];
        final isReady = result?.isReady ?? false;
        final hasBlocking = checks.any((c) => !c.passed && c.isBlocking);

        final statusColor = isReady
            ? RealtimeUiTokens.iosGreen
            : hasBlocking
            ? RealtimeUiTokens.danger
            : RealtimeUiTokens.warning;

        final content = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isReady
                          ? Icons.check_circle_rounded
                          : hasBlocking
                          ? Icons.error_rounded
                          : Icons.info_rounded,
                      size: 17,
                      color: statusColor,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isReady
                          ? strings.systemReady
                          : hasBlocking
                          ? strings.resolveBlockingIssues
                          : strings.checkAttention,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                  Text(
                    '${checks.where((c) => c.passed).length}/${checks.length}',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: RealtimeUiTokens.textMuted,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: RealtimeUiTokens.textMuted,
                  ),
                ],
              ),
            ),
            if (_expanded) ...[
              const SizedBox(height: 10),
              Divider(
                height: 1,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.06),
              ),
              const SizedBox(height: 10),
              const RealtimePreJoinCheckList(),
            ],
          ],
        );

        if (widget.embedded) return content;
        return RealtimeCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: content,
        );
      },
    );
  }
}

/// Mic/camera capture switches independent of any toolbar or route.
///
/// Automatically displays an inline checkmark or cross status indicator next to
/// each switch depending on the current permission state, allowing the user to
/// request access or navigate to app settings directly from the row.
class RealtimePreJoinMediaControls extends StatelessWidget {
  const RealtimePreJoinMediaControls({super.key});

  Widget? _permissionIndicator({
    required RealtimePreJoinController controller,
    required MediaPermissionKind kind,
    required RealtimeStrings strings,
  }) {
    final permission = controller.permissions[kind];
    if (permission == null || permission == MediaPermissionState.unsupported) {
      return null;
    }
    if (permission == MediaPermissionState.granted) {
      return Tooltip(
        message: strings.permissionStateLabel(MediaPermissionState.granted),
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: RealtimeUiTokens.iosGreen.withValues(alpha: 0.14),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.check_rounded,
            size: 13,
            color: RealtimeUiTokens.iosGreen,
          ),
        ),
      );
    }

    final isBlocked = permission == MediaPermissionState.permanentlyDenied;
    final isPending = permission == MediaPermissionState.unknown;
    return Tooltip(
      message: isBlocked ? strings.openAppSettings : strings.requestPermission,
      child: InkWell(
        onTap: controller.busy
            ? null
            : () {
                if (isBlocked) {
                  unawaited(controller.openAppSettings());
                } else {
                  unawaited(controller.requestPermission(kind));
                }
              },
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color:
                (isPending
                        ? RealtimeUiTokens.textMuted
                        : RealtimeUiTokens.danger)
                    .withValues(alpha: 0.14),
            shape: BoxShape.circle,
          ),
          child: Icon(
            isPending ? Icons.help_outline_rounded : Icons.close_rounded,
            size: 13,
            color: isPending
                ? RealtimeUiTokens.textMuted
                : RealtimeUiTokens.danger,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = RealtimePreJoinScope.of(context);
    final strings = RealtimeStrings.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final preview = controller.preview;
        if (preview == null || controller.result?.role == MediaRole.viewer) {
          return const SizedBox.shrink();
        }

        final micPermission =
            controller.permissions[MediaPermissionKind.microphone];
        final micHasPermission =
            micPermission == null ||
            micPermission == MediaPermissionState.granted ||
            micPermission == MediaPermissionState.unsupported;
        final micBlocked =
            micPermission == MediaPermissionState.permanentlyDenied;

        final camPermission =
            controller.permissions[MediaPermissionKind.camera];
        final camHasPermission =
            camPermission == null ||
            camPermission == MediaPermissionState.granted ||
            camPermission == MediaPermissionState.unsupported;
        final camBlocked =
            camPermission == MediaPermissionState.permanentlyDenied;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RealtimeCupertinoSwitchRow(
              title: LayoutBuilder(
                builder: (context, constraints) => constraints.maxWidth < 116
                    ? Text(strings.microphone)
                    : Row(
                        children: [
                          Flexible(
                            child: Text(
                              strings.microphone,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (preview.settings.microphoneEnabled)
                            const Padding(
                              padding: EdgeInsets.only(left: 12),
                              child: SizedBox(
                                width: 84,
                                child: RealtimeMicrophoneLevelMeter(),
                              ),
                            ),
                        ],
                      ),
              ),
              subtitle: !micHasPermission
                  ? Text(
                      micBlocked
                          ? '${strings.permissionStateLabel(micPermission)} · ${strings.openAppSettings}'
                          : '${strings.permissionStateLabel(micPermission)} · ${strings.requestPermission}',
                    )
                  : null,
              leading: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: RealtimeUiTokens.iosBlue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.mic_rounded,
                  size: 16,
                  color: RealtimeUiTokens.text,
                ),
              ),
              statusWidget: _permissionIndicator(
                controller: controller,
                kind: MediaPermissionKind.microphone,
                strings: strings,
              ),
              value: micHasPermission && preview.settings.microphoneEnabled,
              enabled: !controller.busy,
              onChanged: (enabled) {
                if (!micHasPermission) {
                  if (micBlocked) {
                    unawaited(controller.openAppSettings());
                  } else {
                    unawaited(
                      controller.requestPermissionAndEnable(
                        MediaPermissionKind.microphone,
                      ),
                    );
                  }
                  return;
                }
                unawaited(controller.setMicrophoneEnabled(enabled));
              },
            ),
            Divider(
              height: 1,
              indent: 54,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06),
            ),
            RealtimeCupertinoSwitchRow(
              title: Text(strings.camera),
              subtitle: !camHasPermission
                  ? Text(
                      camBlocked
                          ? '${strings.permissionStateLabel(camPermission)} · ${strings.openAppSettings}'
                          : '${strings.permissionStateLabel(camPermission)} · ${strings.requestPermission}',
                    )
                  : null,
              leading: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: RealtimeUiTokens.iosTeal.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.videocam_rounded,
                  size: 16,
                  color: RealtimeUiTokens.iosTeal,
                ),
              ),
              statusWidget: _permissionIndicator(
                controller: controller,
                kind: MediaPermissionKind.camera,
                strings: strings,
              ),
              value: camHasPermission && preview.settings.cameraEnabled,
              enabled: !controller.busy,
              onChanged: (enabled) {
                if (!camHasPermission) {
                  if (camBlocked) {
                    unawaited(controller.openAppSettings());
                  } else {
                    unawaited(
                      controller.requestPermissionAndEnable(
                        MediaPermissionKind.camera,
                      ),
                    );
                  }
                  return;
                }
                unawaited(controller.setCameraEnabled(enabled));
              },
            ),
          ],
        );
      },
    );
  }
}

class RealtimePreJoinDevicePicker extends StatelessWidget {
  const RealtimePreJoinDevicePicker({
    super.key,
    required this.kind,
    this.footer,
  });
  final MediaDeviceKind kind;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final controller = RealtimePreJoinScope.of(context);
    final strings = RealtimeStrings.of(context);
    final style = RealtimeStyle.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final preview = controller.preview;
        final devices = controller.devices
            .where((device) => device.kind == kind)
            .toList();
        if (preview == null) return const SizedBox.shrink();
        final selected = switch (kind) {
          MediaDeviceKind.microphone => preview.settings.microphone,
          MediaDeviceKind.camera => preview.settings.camera,
          MediaDeviceKind.audioOutput => preview.settings.audioOutput,
        };
        final initial = devices
            .where((device) => device.id == selected?.id)
            .firstOrNull;

        final label = switch (kind) {
          MediaDeviceKind.microphone => strings.microphone,
          MediaDeviceKind.camera => strings.camera,
          MediaDeviceKind.audioOutput => strings.speaker,
        };

        // Reference green-room field: a small label above a 40 pt filled
        // select, not a floating-label form field.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 6),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: style.textMuted,
                ),
              ),
            ),
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: style.surfaceSubtle,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: style.border),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<MediaDevice>(
                  key: ValueKey((kind, initial?.id)),
                  value: initial,
                  hint: Text(
                    selected?.label ??
                        (strings.isZh ? '系统默认' : 'System default'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: RealtimeFonts.bodyOf(context),
                      fontSize: 13,
                      color: initial != null ? style.text : style.textMuted,
                    ),
                  ),
                  isExpanded: true,
                  isDense: true,
                  borderRadius: BorderRadius.circular(12),
                  icon: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: style.textMuted,
                  ),
                  style: TextStyle(
                    fontFamily: RealtimeFonts.bodyOf(context),
                    fontSize: 13,
                    color: style.text,
                  ),
                  items: [
                    for (final device in devices)
                      DropdownMenuItem(
                        value: device,
                        child: Text(
                          device.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: controller.busy || devices.isEmpty
                      ? null
                      : (device) {
                          if (device != null) {
                            unawaited(controller.selectDevice(device));
                          }
                        },
                ),
              ),
            ),
            if (footer != null) ...[const SizedBox(height: 8), footer!],
          ],
        );
      },
    );
  }
}

/// Real input-level meter. An enabled microphone is not evidence of sound.
class RealtimeMicrophoneLevelMeter extends StatelessWidget {
  const RealtimeMicrophoneLevelMeter({
    super.key,
    this.active,
    this.height = 22,
  });

  /// Optional override for whether the microphone is active. If omitted,
  /// reads `controller.preview?.settings.microphoneEnabled` from [RealtimePreJoinScope].
  final bool? active;
  final double height;

  @override
  Widget build(BuildContext context) {
    final controller = RealtimePreJoinScope.maybeOf(context);
    if (controller == null) {
      return _RealtimeMicrophoneLevelMeterVisual(level: 0, height: height);
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final micOn =
            active ?? (controller.preview?.settings.microphoneEnabled ?? false);
        final preview = controller.preview;
        final levels = !micOn
            ? null
            : MacosMicrophoneLevels.isAvailable
            // Native PCM capture is available even if the selected RTC
            // provider has no local audio-level API (or its visualizer
            // does not work on desktop).
            ? MacosMicrophoneLevels.levels
            : preview is MediaLocalPreviewAudioLevels
            ? (preview as MediaLocalPreviewAudioLevels).microphoneLevels
            : null;
        return StreamBuilder<double>(
          // Some native visualizers stop reporting during silence. Expire the
          // last peak rather than leave the microphone visibly speaking.
          stream: levels?.timeout(
            const Duration(milliseconds: 600),
            onTimeout: (sink) => sink.add(0),
          ),
          initialData: 0,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Tooltip(
                message: snapshot.error.toString(),
                child: Semantics(
                  label: 'Microphone level unavailable',
                  child: const SizedBox(
                    height: 22,
                    child: Icon(
                      Icons.error_outline_rounded,
                      size: 15,
                      color: Colors.orange,
                    ),
                  ),
                ),
              );
            }
            return _RealtimeMicrophoneLevelMeterVisual(
              level: levels == null ? 0 : (snapshot.data ?? 0),
              height: height,
            );
          },
        );
      },
    );
  }
}

class _RealtimeMicrophoneLevelMeterVisual extends StatefulWidget {
  const _RealtimeMicrophoneLevelMeterVisual({
    required this.level,
    required this.height,
  });
  final double level;
  final double height;

  @override
  State<_RealtimeMicrophoneLevelMeterVisual> createState() =>
      _RealtimeMicrophoneLevelMeterVisualState();
}

class _RealtimeMicrophoneLevelMeterVisualState
    extends State<_RealtimeMicrophoneLevelMeterVisual>
    with SingleTickerProviderStateMixin {
  static const _barCount = 25;
  static const _semanticSteps = 9;

  late final _ticker = createTicker(_onTick);
  Duration _lastElapsed = Duration.zero;
  double _eased = 0;
  double _phase = 0;
  bool _reduceMotion = false;

  /// Only real input moves the waveform. The noise floor stays flat and
  /// measured levels are compressed to preserve resolution for normal voice.
  double get _targetStrength {
    final level = widget.level;
    final clean = level.isFinite ? (level - 0.015).clamp(0.0, 1.0) : 0.0;
    return sqrt((clean / 0.4).clamp(0.0, 1.0));
  }

  @override
  void initState() {
    super.initState();
    _eased = _targetStrength;
    if (_eased > 0) _start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      if (_ticker.isActive) _ticker.stop();
    } else if (_targetStrength > 0 && !_ticker.isActive) {
      _start();
    }
  }

  @override
  void didUpdateWidget(
    covariant _RealtimeMicrophoneLevelMeterVisual oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (!_reduceMotion && _targetStrength > 0 && !_ticker.isActive) _start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _start() {
    _lastElapsed = Duration.zero;
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    final dt = min(
      (elapsed - _lastElapsed).inMicroseconds / Duration.microsecondsPerSecond,
      0.05,
    );
    _lastElapsed = elapsed;
    final target = _targetStrength;
    // Fast attack and a slower release keeps speech legible, while the bars
    // keep breathing at the sample level instead of snapping frame to frame.
    final rate = target > _eased ? 30.0 : 9.0;
    final next = dt <= 0
        ? _eased
        : _eased + (target - _eased) * (1 - exp(-rate * dt));
    final idle = target <= 0.001 && next < 0.004;
    setState(() {
      _eased = idle ? 0 : next;
      _phase += dt;
    });
    // Stop scheduling frames once the input is silent; a muted meter must not
    // keep repainting (or block pumpAndSettle in host tests).
    if (idle) _ticker.stop();
  }

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    final target = _targetStrength;
    final strength = _reduceMotion ? target : _eased.clamp(0.0, 1.0);
    final lit = (target * _semanticSteps).round().clamp(0, _semanticSteps);
    final active = strength > 0.002;
    final settle = _reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 160);
    final phase = _reduceMotion ? 0.0 : _phase;
    // Keep distinct bars at the original compact width (~84px). Wider
    // consumers may still use the more detailed waveform.
    final barCount = widget.height <= 26 ? 11 : _barCount;
    final spacing = widget.height <= 26 ? 2.5 : 3.0;

    return Semantics(
      label: 'Microphone level',
      value: '$lit of $_semanticSteps',
      child: SizedBox(
        height: widget.height,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedOpacity(
              duration: settle,
              opacity: active ? 0 : 1,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  for (var i = 0; i < barCount; i++) ...[
                    if (i > 0) SizedBox(width: spacing),
                    Expanded(
                      child: Container(
                        height: 3,
                        decoration: BoxDecoration(
                          color: style.borderStrong.withValues(alpha: .65),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            AnimatedOpacity(
              duration: settle,
              opacity: active ? 1 : 0,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  for (var i = 0; i < barCount; i++) ...[
                    if (i > 0) SizedBox(width: spacing),
                    Expanded(
                      child: Container(
                        // A centered envelope keeps the inline meter legible.
                        // All movement is gated by captured input strength:
                        // silence never produces a synthetic waveform.
                        height:
                            3 +
                            (widget.height - 3) *
                                strength *
                                (0.25 +
                                    0.75 *
                                        pow(
                                          sin(pi * (i + 1) / (barCount + 1)),
                                          .7,
                                        ).toDouble()) *
                                (0.55 +
                                    0.45 *
                                        (0.5 +
                                            0.5 * sin(phase * 8 + i * 0.67))),
                        decoration: BoxDecoration(
                          color: Color.lerp(
                            style.speakStrong,
                            const Color(0xFF39AFE8),
                            i / (barCount - 1),
                          ),
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: strength > .1
                              ? [
                                  BoxShadow(
                                    color: style.speakStrong.withValues(
                                      alpha: strength * .19,
                                    ),
                                    blurRadius: 8,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Animated 3-bar equalizer widget directly matching the Tandem `.bars` speaking indicator.
class RealtimeSpeakingBars extends StatefulWidget {
  const RealtimeSpeakingBars({super.key, this.color, this.height = 12});

  final Color? color;
  final double height;

  @override
  State<RealtimeSpeakingBars> createState() => _RealtimeSpeakingBarsState();
}

class _RealtimeSpeakingBarsState extends State<RealtimeSpeakingBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = RealtimeStyle.of(context);
    final barColor = widget.color ?? style.speak;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    if (reduceMotion) {
      return SizedBox(
        height: widget.height,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _buildBar(widget.height * 0.4, barColor),
            const SizedBox(width: 2),
            _buildBar(widget.height * 0.8, barColor),
            const SizedBox(width: 2),
            _buildBar(widget.height * 0.5, barColor),
          ],
        ),
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final h1 = _computeHeight(t, 0.0);
        final h2 = _computeHeight(t, 0.167);
        final h3 = _computeHeight(t, 0.333);
        return SizedBox(
          height: widget.height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _buildBar(h1, barColor),
              const SizedBox(width: 2),
              _buildBar(h2, barColor),
              const SizedBox(width: 2),
              _buildBar(h3, barColor),
            ],
          ),
        );
      },
    );
  }

  double _computeHeight(double progress, double offset) {
    final phase = (progress - offset) % 1.0;
    final sine = sin(phase * pi);
    final minH = widget.height * (4.0 / 12.0);
    final maxH = widget.height;
    return minH + (maxH - minH) * sine.abs();
  }

  Widget _buildBar(double height, Color color) {
    return Container(
      width: 3,
      height: height.clamp(2.0, widget.height),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// Retained only for source compatibility with existing UI integrations.
/// The four non-functional preparation toggles have been removed.
@Deprecated('Removed pre-join toggles; use explicit media and effect controls.')
class RealtimePreJoinToggles extends StatelessWidget {
  const RealtimePreJoinToggles({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class RealtimePreJoinBackgroundSelector extends StatelessWidget {
  const RealtimePreJoinBackgroundSelector({
    super.key,
    this.imagePresets = const [],
  });
  final List<MediaBackgroundImagePreset> imagePresets;

  @override
  Widget build(BuildContext context) {
    final controller = RealtimePreJoinScope.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final result = controller.result;
        if (result == null ||
            result.role == MediaRole.viewer ||
            !result.backgroundCapabilities.isSupported) {
          return const SizedBox.shrink();
        }
        return BackgroundEffectSelector(
          capabilities: result.backgroundCapabilities,
          effect: controller.backgroundEffect,
          imagePresets: imagePresets,
          busy: controller.busy || controller.updatingBackground,
          onChanged: (effect) =>
              unawaited(controller.setBackgroundEffect(effect)),
        );
      },
    );
  }
}

/// Optional inline permission requests; the application can supply custom UI.
class RealtimePreJoinPermissions extends StatelessWidget {
  const RealtimePreJoinPermissions({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = RealtimePreJoinScope.of(context);
    final strings = RealtimeStrings.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.result?.role == MediaRole.viewer) {
          return const SizedBox.shrink();
        }
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final kind in MediaPermissionKind.values)
              if (kind == MediaPermissionKind.microphone ||
                  kind == MediaPermissionKind.camera)
                if (controller.permissions[kind] !=
                        MediaPermissionState.unknown ||
                    (Theme.of(context).platform != TargetPlatform.macOS &&
                        Theme.of(context).platform != TargetPlatform.windows &&
                        Theme.of(context).platform != TargetPlatform.linux))
                  ActionChip(
                    avatar: Icon(
                      controller.permissions[kind] ==
                              MediaPermissionState.granted
                          ? Icons.check
                          : Icons.lock_outline,
                      size: 18,
                    ),
                    label: Text(
                      '${kind == MediaPermissionKind.microphone ? strings.microphone : strings.camera}: '
                      '${strings.permissionStateLabel(controller.permissions[kind] ?? MediaPermissionState.unknown)}',
                    ),
                    onPressed: controller.busy
                        ? null
                        : () {
                            if (controller.permissions[kind] ==
                                MediaPermissionState.permanentlyDenied) {
                              unawaited(controller.openAppSettings());
                            } else {
                              unawaited(controller.requestPermission(kind));
                            }
                          },
                  ),
          ],
        );
      },
    );
  }
}

/// Join button knows the controller state; navigation stays with the host.
class RealtimePreJoinJoinButton extends StatelessWidget {
  const RealtimePreJoinJoinButton({
    super.key,
    required this.onEnter,
    this.label,
  });
  final Future<void> Function(MediaLocalPreviewSettings settings) onEnter;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final controller = RealtimePreJoinScope.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final resolvedLabel =
            label ??
            (controller.joining
                ? RealtimeStrings.of(context).enteringRoom
                : RealtimeStrings.of(context).join);
        final onPressed = controller.canEnter
            ? () => unawaited(controller.enter(onEnter))
            : null;
        // FilledButton.icon lays its child out in a non-flexible Row, so a
        // long localized label overflows in a 320 pt column at 200% text.
        // Compose the same appearance with a Flexible caption instead.
        return FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (controller.joining)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(Icons.login_rounded, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  resolvedLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
