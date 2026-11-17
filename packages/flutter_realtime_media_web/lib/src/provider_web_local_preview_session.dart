import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'provider_web_bridge.dart';
import 'provider_web_track.dart';
import 'provider_web_track_renderer.dart';

class ProviderWebLocalPreviewSession
    implements MediaLocalPreviewSession, MediaBackgroundEffectsController {
  ProviderWebLocalPreviewSession({
    required this.providerId,
    required this.role,
    required this.previewId,
    required this.capabilities,
  }) : _settings = const MediaLocalPreviewSettings(
         microphoneEnabled: false,
         cameraEnabled: false,
       ),
       _cameraTrack = ProviderWebVideoTrack(
         providerId: providerId,
         sessionId: previewId,
         id: 'preview:video:$previewId',
         participantId: 'preview:$previewId',
         isLocal: true,
         isScreenShare: false,
       );

  @override
  final String providerId;

  @override
  final MediaRole role;

  final String previewId;

  @override
  final MediaCapabilities capabilities;

  MediaLocalPreviewSettings _settings;
  final ProviderWebVideoTrack _cameraTrack;
  bool _disposed = false;

  @override
  MediaVideoTrack? get cameraTrack =>
      _settings.cameraEnabled ? _cameraTrack : null;

  @override
  MediaTrackRenderer get renderer => const ProviderWebTrackRenderer();

  @override
  MediaLocalPreviewSettings get settings => _settings;

  @override
  MediaBackgroundCapabilities get backgroundCapabilities =>
      MediaBackgroundCapabilities(
        canBlur: capabilities.canBlurBackground,
        canReplaceImage: capabilities.canReplaceBackgroundImage,
      );

  @override
  MediaBackgroundEffect get backgroundEffect => _settings.backgroundEffect;

  @override
  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async {
    _ensureNotDisposed();
    final requested = kinds ?? MediaDeviceKind.values.toSet();
    final values = await ProviderWebBridge.listDevices(providerId, previewId);
    return values
        .map(_previewMediaDeviceFromJson)
        .where((device) => requested.contains(device.kind))
        .toList(growable: false);
  }

  @override
  Future<void> selectMediaDevice(MediaDevice device) async {
    _ensureNotDisposed();
    await ProviderWebBridge.selectDevice(providerId, previewId, {
      'id': device.id,
      'label': device.label,
      'kind': device.kind.name,
    });
    _settings = _settings.copyWith(
      microphone: device.kind == MediaDeviceKind.microphone
          ? device
          : _settings.microphone,
      camera: device.kind == MediaDeviceKind.camera ? device : _settings.camera,
      audioOutput: device.kind == MediaDeviceKind.audioOutput
          ? device
          : _settings.audioOutput,
    );
  }

  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {
    _ensureNotDisposed();
    await ProviderWebBridge.command(providerId, previewId, 'setMuted', {
      'muted': !enabled,
    });
    _settings = _settings.copyWith(microphoneEnabled: enabled);
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    _ensureNotDisposed();
    await ProviderWebBridge.command(providerId, previewId, 'setVideoEnabled', {
      'enabled': enabled,
    });
    _settings = _settings.copyWith(cameraEnabled: enabled);
  }

  @override
  Future<void> setBackgroundEffect(MediaBackgroundEffect effect) async {
    _ensureNotDisposed();
    if (!backgroundCapabilities.supports(effect)) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message:
            '$providerId does not support the requested SDK background '
            'effect in local preview.',
        providerId: providerId,
      );
    }
    await ProviderWebBridge.command(
      providerId,
      previewId,
      'setBackgroundEffect',
      {...effect.toJson()},
    );
    _settings = _settings.copyWith(backgroundEffect: effect);
  }

  Future<void>? _disposal;
  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
    await ProviderWebBridge.dispose(providerId, previewId);
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'The local preview has already been disposed.',
        providerId: providerId,
      );
    }
  }
}

MediaDevice _previewMediaDeviceFromJson(Map<String, Object?> json) {
  final kind = switch (json['kind']?.toString()) {
    'microphone' || 'audioinput' => MediaDeviceKind.microphone,
    'audioOutput' || 'audiooutput' => MediaDeviceKind.audioOutput,
    _ => MediaDeviceKind.camera,
  };
  return MediaDevice(
    id: json['id']?.toString() ?? '',
    label: json['label']?.toString() ?? '',
    kind: kind,
    groupId: json['groupId']?.toString(),
  );
}
