part of 'livekit_media_session.dart';

class _LiveKitPublishing {
  _LiveKitPublishing(this._session);
  final LiveKitMediaSessionBase _session;
  String get providerId => _session.providerId;
  MediaCapabilities get capabilities => _session.capabilities;
  MediaRole get role => _session.role;
  MediaSessionState get state => _session.state;
  MediaSnapshot get snapshot => _session.snapshot;
  Duration get cleanupTimeout => _session.cleanupTimeout;

  ProcessedVideoSource? _processedSource;
  lk.LocalVideoTrack? _processedTrack;
  bool _processedPublished = false;

  bool supportsProcessedVideoSource(ProcessedVideoSource source) =>
      capabilities.canBlurBackground &&
      (kIsWeb
          ? source.platform == ProcessedVideoPlatform.web &&
                source.kind == ProcessedVideoSourceKind.mediaStreamTrack
          : source.kind == ProcessedVideoSourceKind.nativeFrameHub &&
                ((defaultTargetPlatform == TargetPlatform.android &&
                        source.platform == ProcessedVideoPlatform.android) ||
                    (defaultTargetPlatform == TargetPlatform.macOS &&
                        source.platform == ProcessedVideoPlatform.macos) ||
                    (defaultTargetPlatform == TargetPlatform.iOS &&
                        source.platform == ProcessedVideoPlatform.ios) ||
                    (defaultTargetPlatform == TargetPlatform.windows &&
                        source.platform == ProcessedVideoPlatform.windows)));

  Future<void> attachProcessedVideoSource(ProcessedVideoSource source) async {
    _session._ensureActive();
    if (!supportsProcessedVideoSource(source)) {
      _unsupported('processed video input');
    }
    await detachProcessedVideoSource();
    final local = _session._requireLocalParticipant();
    // Muting retains the original camera publication in LiveKit. Remove it
    // before publishing its replacement so source lookup cannot select the
    // old muted camera and the server does not receive two camera sources.
    final camera = local.getTrackPublicationBySource(lk.TrackSource.camera);
    if (camera != null) await local.removePublishedTrack(camera.sid);
    try {
      _processedTrack = await createProcessedLiveKitTrack(source);
      _processedSource = source;
    } catch (_) {
      await disposeProcessedLiveKitTrack(source);
      rethrow;
    }
  }

  Future<void> detachProcessedVideoSource() async {
    final source = _processedSource;
    final track = _processedTrack;
    final published = _processedPublished;
    _processedSource = null;
    _processedTrack = null;
    _processedPublished = false;
    if (source == null) return;
    try {
      try {
        final sid = track?.sid;
        if (published && sid != null) {
          await _session._room?.localParticipant?.removePublishedTrack(sid);
        }
      } finally {
        await track?.dispose();
      }
    } finally {
      await disposeProcessedLiveKitTrack(source);
    }
  }

  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async {
    if (_processedSource == null) {
      return _session._devices.listMediaDevices(kinds: kinds);
    }
    final requested = kinds ?? MediaDeviceKind.values.toSet();
    final devices = await _session._devices.listMediaDevices(
      kinds: requested.difference({MediaDeviceKind.camera}),
    );
    return List.unmodifiable([
      ...devices,
      if (requested.contains(MediaDeviceKind.camera))
        for (final camera in await ProcessedVideoBridge().listCameras())
          MediaDevice(
            id: camera.id,
            label: camera.label,
            kind: MediaDeviceKind.camera,
          ),
    ]);
  }

  Future<void> selectMediaDevice(MediaDevice device) async {
    _session._ensureActive();
    final source = _processedSource;
    if (source != null && device.kind == MediaDeviceKind.camera) {
      await ProcessedVideoBridge().selectCamera(source, device.id);
      return;
    }
    await _session._devices.selectMediaDevice(device);
  }

  Future<void> setMuted(bool muted) async {
    _session._ensureActive();
    if (!capabilities.canPublishAudio) _unsupported('microphone publishing');
    try {
      await _session._requireLocalParticipant().setMicrophoneEnabled(!muted);
      _session._mapper._refreshSnapshot();
      _session._emit(MediaLocalMediaChanged(muted: muted));
    } catch (error, stack) {
      throw _session._mapError(error, 'setMuted', stackTrace: stack);
    }
  }

  Future<void> toggleMute() => setMuted(!snapshot.localMuted);

  Future<void> setVideoEnabled(bool enabled) async {
    _session._ensureActive();
    if (!capabilities.canPublishVideo) _unsupported('camera publishing');
    var stage = 'setVideoEnabled';
    try {
      final processed = _processedTrack;
      if (processed == null) {
        await _session._requireLocalParticipant().setCameraEnabled(enabled);
      } else if (enabled) {
        stage = 'enableProcessedSource';
        await ProcessedVideoBridge().setEnabled(_processedSource!, true);
        // A browser clone inherits enabled=false when attached while muted.
        // Enabling the source does not enable that independently owned clone.
        processed.mediaStreamTrack.enabled = true;
        await processed.unmute(stopOnMute: false);
        if (!_processedPublished) {
          stage = 'publishProcessedVideo';
          await _session._requireLocalParticipant().publishVideoTrack(
            processed,
          );
          _processedPublished = true;
        }
      } else {
        stage = 'muteProcessedVideo';
        await processed.mute(stopOnMute: false);
        stage = 'disableProcessedSource';
        await ProcessedVideoBridge().setEnabled(_processedSource!, false);
      }
      _session._mapper._refreshSnapshot();
      _session._emit(MediaLocalMediaChanged(videoEnabled: enabled));
    } catch (error, stack) {
      throw _session._mapError(error, stage, stackTrace: stack);
    }
  }

  Future<void> setScreenShareEnabled(bool enabled) async {
    _session._ensureActive();
    if (!capabilities.canScreenShare) _unsupported('screen sharing');
    var androidServicePrepared = false;
    try {
      if (enabled) {
        await _session._screenShare._prepareAndroidScreenShare();
        androidServicePrepared =
            _session._screenShare._androidScreenShareServiceStarted;
        await _session._screenShare._prepareMacOsScreenShare();
      }
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        // Capture the ENTIRE iPhone display using a signed ReplayKit Broadcast
        // Upload Extension. Wait for LiveKit's real screen video publication,
        // not the picker request returning, before committing content mode.
        if (_session.iosScreenShareMode == IosScreenShareMode.system) {
          await _session._screenShare._setIosSystemScreenShareEnabled(enabled);
        } else {
          await _session._screenShare._setIosInAppScreenShareEnabled(enabled);
        }
      } else {
        await _session._requireLocalParticipant().setScreenShareEnabled(
          enabled,
        );
      }
      _session._mapper._refreshSnapshot();
      if (!kIsWeb &&
          defaultTargetPlatform == TargetPlatform.iOS &&
          _session.snapshot.localScreenShareEnabled != enabled) {
        throw RealtimeException(
          code: RealtimeErrorCode.providerError,
          message: 'iOS screen capture did not reach the requested state.',
          providerId: _session.providerId,
          operation: 'screenShare',
          recoverable: true,
          suggestedAction: 'retry-screen-sharing',
        );
      }
      if (!enabled) {
        await _session._screenShare._stopAndroidScreenShareService();
      }
    } catch (error, stack) {
      if (enabled && androidServicePrepared) {
        await _session._screenShare._stopAndroidScreenShareService();
      }
      throw _session._mapError(error, 'screenShare', stackTrace: stack);
    }
  }

  Future<void> switchCamera(MediaCameraPosition position) async {
    _session._ensureActive();
    if (!capabilities.canSwitchCamera) _unsupported('camera switching');
    final source = _processedSource;
    if (source != null) {
      await ProcessedVideoBridge().selectCamera(
        source,
        position == MediaCameraPosition.front ? 'front' : 'back',
      );
      return;
    }
    final publication = _session
        ._requireLocalParticipant()
        .getTrackPublicationBySource(lk.TrackSource.camera);
    final track = publication?.track;
    if (track is! lk.LocalVideoTrack) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        message: 'Enable the local camera before switching it.',
        providerId: providerId,
      );
    }
    try {
      await track.setCameraPosition(
        position == MediaCameraPosition.front
            ? lk.CameraPosition.front
            : lk.CameraPosition.back,
      );
      _session._mapper._refreshSnapshot();
    } catch (error, stack) {
      throw _session._mapError(error, 'switchCamera', stackTrace: stack);
    }
  }

  Future<List<MediaAudioDevice>> listAudioDevices() async {
    _session._ensureActive();
    if (!capabilities.canEnumerateAudioDevices) {
      _unsupported('audio device enumeration');
    }
    try {
      final devices = await lk.Hardware.instance.audioOutputs();
      return devices
          .map(
            (device) => MediaAudioDevice(
              id: device.deviceId,
              label: device.label,
              type: MediaAudioDevice.fromLabel(device.label).type,
            ),
          )
          .toList(growable: false);
    } catch (error, stack) {
      throw _session._mapError(error, 'listAudioDevices', stackTrace: stack);
    }
  }

  Future<void> selectAudioDevice(MediaAudioDevice device) async {
    _session._ensureActive();
    final id = device.id?.trim();
    final outputs = await lk.Hardware.instance.audioOutputs();
    lk.MediaDevice? selected;
    for (final candidate in outputs) {
      if ((id != null && id.isNotEmpty && candidate.deviceId == id) ||
          candidate.label == device.label) {
        selected = candidate;
        break;
      }
    }
    if (selected == null) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'The requested audio output is no longer available.',
        providerId: providerId,
      );
    }
    try {
      await _session._requireRoom().setAudioOutputDevice(selected);
    } catch (error, stack) {
      throw _session._mapError(error, 'selectAudioDevice', stackTrace: stack);
    }
  }

  Never _unsupported(String feature) => throw RealtimeException(
    code: RealtimeErrorCode.unsupportedFeature,
    message: 'LiveKit $feature is not supported for this session.',
    providerId: providerId,
  );
}
