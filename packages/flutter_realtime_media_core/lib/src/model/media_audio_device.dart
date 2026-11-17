/// Broad device category for applications that present their own audio-output
/// picker. [label] is the provider's device label and is what gets selected;
/// [type] is a best-effort classification of that label.
class MediaAudioDevice {
  const MediaAudioDevice({this.id, required this.label, required this.type});

  /// Provider-stable device identifier when one is available.
  ///
  /// Some providers (for example LiveKit/WebRTC) require a device id to switch
  /// outputs reliably. Providers that only expose a label may leave this null.
  final String? id;

  final String label;
  final MediaAudioDeviceType type;

  factory MediaAudioDevice.fromLabel(String label, {String? id}) {
    final normalized = label.toLowerCase();
    final type = switch (normalized) {
      _ when normalized.contains('bluetooth') => MediaAudioDeviceType.bluetooth,
      _
          when normalized.contains('headset') ||
              normalized.contains('headphone') =>
        MediaAudioDeviceType.wiredHeadset,
      _ when normalized.contains('speaker') => MediaAudioDeviceType.speaker,
      _
          when normalized.contains('earpiece') ||
              normalized.contains('receiver') =>
        MediaAudioDeviceType.earpiece,
      _ => MediaAudioDeviceType.other,
    };
    return MediaAudioDevice(id: id, label: label, type: type);
  }

  @override
  String toString() =>
      'MediaAudioDevice(${id == null ? label : '$label, id: $id'}, ${type.name})';
}

/// Coarse categories for audio devices exposed by a provider.
enum MediaAudioDeviceType { bluetooth, wiredHeadset, speaker, earpiece, other }

/// Camera to use for local video capture.
enum MediaCameraPosition { front, back }
