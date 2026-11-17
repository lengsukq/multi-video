import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'realtime_strings.dart';
import 'realtime_ui_style.dart';
import 'media_background_image_preset.dart';

/// Shared pre-join/in-room controls. Image import belongs to the host app.
class BackgroundEffectSelector extends StatelessWidget {
  const BackgroundEffectSelector({
    super.key,
    required this.capabilities,
    required this.effect,
    required this.onChanged,
    this.imageBytes,
    this.busy = false,
    this.imagePresets = const [],
  });

  final MediaBackgroundCapabilities capabilities;
  final MediaBackgroundEffect effect;
  final ValueChanged<MediaBackgroundEffect> onChanged;
  final Uint8List? imageBytes;
  final bool busy;
  final List<MediaBackgroundImagePreset> imagePresets;

  @override
  Widget build(BuildContext context) {
    final strings = RealtimeStrings.of(context);
    final availableImage =
        effect.imageBytes ??
        imageBytes ??
        (imagePresets.isEmpty ? null : imagePresets.first.imageBytes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          strings.virtualBackground,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 8),
        RealtimeCupertinoSegmentedBar<MediaBackgroundEffectType>(
          groupValue: effect.type,
          onValueChanged: (val) {
            if (busy) return;
            onChanged(switch (val) {
              MediaBackgroundEffectType.none =>
                const MediaBackgroundEffect.none(),
              MediaBackgroundEffectType.blur =>
                const MediaBackgroundEffect.blur(),
              MediaBackgroundEffectType.replaceImage =>
                MediaBackgroundEffect.replaceImage(
                  imageBytes: availableImage ?? Uint8List(0),
                ),
            });
          },
          children: {
            MediaBackgroundEffectType.none: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                strings.noVirtualBackground,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (capabilities.canBlur)
              MediaBackgroundEffectType.blur: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  strings.backgroundBlur,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            if (capabilities.canReplaceImage && availableImage != null)
              MediaBackgroundEffectType.replaceImage: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  strings.backgroundImage,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          },
        ),
        if (effect.type == MediaBackgroundEffectType.blur) ...[
          const SizedBox(height: 10),
          RealtimeCupertinoSegmentedBar<MediaBackgroundBlurStrength>(
            groupValue: effect.blurStrength,
            onValueChanged: (val) {
              if (!busy) {
                onChanged(MediaBackgroundEffect.blur(blurStrength: val));
              }
            },
            children: {
              for (final strength in MediaBackgroundBlurStrength.values)
                strength: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  child: Text(
                    strings.backgroundBlurStrength(strength),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            },
          ),
        ],
        if (effect.type == MediaBackgroundEffectType.replaceImage &&
            capabilities.canReplaceImage &&
            imagePresets.isNotEmpty) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: imagePresets.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final preset = imagePresets[index];
                final isSelected = effect == preset.effect;
                return GestureDetector(
                  onTap: busy ? null : () => onChanged(preset.effect),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 76,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected
                            ? RealtimeUiTokens.iosBlue
                            : Colors.black.withValues(alpha: 0.08),
                        width: isSelected ? 2.0 : 1.0,
                      ),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: RealtimeUiTokens.iosBlue.withValues(
                                  alpha: 0.25,
                                ),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(
                            _decoderBytes(preset.imageBytes),
                            fit: BoxFit.cover,
                          ),
                          Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.65),
                                ],
                              ),
                            ),
                          ),
                          Positioned(
                            left: 4,
                            right: 4,
                            bottom: 4,
                            child: Text(
                              preset.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (isSelected)
                            const Positioned(
                              top: 4,
                              right: 4,
                              child: CircleAvatar(
                                radius: 8,
                                backgroundColor: RealtimeUiTokens.accent,
                                child: Icon(
                                  Icons.check,
                                  size: 11,
                                  color: RealtimeUiTokens.onAccent,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        if (busy) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(minHeight: 2),
        ],
      ],
    );
  }
}

// Flutter Web's image codec expects a mutable NativeUint8List (.toJS rejects
// _UnmodifiableUint8ListView). Copy into a plain Uint8List for decoding.
Uint8List _decoderBytes(Uint8List bytes) => Uint8List.fromList(bytes);
