part of 'agora_media_session.dart';

class _AgoraPublishing {
  _AgoraPublishing(this._session);
  final _AgoraMediaSession _session;
  String get providerId => _session.providerId;
  MediaCapabilities get capabilities => _session.capabilities;
  MediaRole get role => _session.role;
  MediaSessionState get state => _session.state;
  MediaSnapshot get snapshot => _session.snapshot;
  Duration get cleanupTimeout => _session.cleanupTimeout;

  MediaCameraPosition _cameraPosition = MediaCameraPosition.front;
  MediaVideoTrack? _localScreenTrack;
  bool _localScreenShareEnabled = false;
  bool _localVideoEnabled = false;
  bool _localMuted = true;
  final AgoraScreenCapture _screenCapture = const AgoraScreenCapture();
  Timer? _screenShareAnnouncementTimer;

  void _stopScreenShareAnnouncements() {
    _screenShareAnnouncementTimer?.cancel();
    _screenShareAnnouncementTimer = null;
  }

  void _startScreenShareAnnouncements() {
    _stopScreenShareAnnouncements();
    // Provider metadata is transient, unlike the video track. Keep it
    // discoverable for late joiners and peers that missed the first signal.
    _screenShareAnnouncementTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) {
        if (!_localScreenShareEnabled ||
            _session._disposed ||
            _session._joinCancelled ||
            _session._engine == null) {
          _stopScreenShareAnnouncements();
          return;
        }
        unawaited(_session._data._announceScreenShareState(true));
      },
    );
  }
  final _iosScreenSink = NativeProcessedVideoSink(providerId: 'agora');
  ProcessedVideoSource? _iosScreenCaptureSource;
  int? _iosScreenTrackId;
  int? _customVideoTrackId;
  final _processedSink = NativeProcessedVideoSink(providerId: 'agora');
  bool supportsProcessedVideoSource(ProcessedVideoSource source) =>
      role != MediaRole.viewer &&
      capabilities.canBlurBackground &&
      _processedSink.supports(source) &&
      source.platform ==
          (defaultTargetPlatform == TargetPlatform.android
              ? ProcessedVideoPlatform.android
              : defaultTargetPlatform == TargetPlatform.iOS
              ? ProcessedVideoPlatform.ios
              : defaultTargetPlatform == TargetPlatform.windows
              ? ProcessedVideoPlatform.windows
              : ProcessedVideoPlatform.macos);
  Future<void> attachProcessedVideoSource(ProcessedVideoSource source) async {
    _ensurePublisherActive('processed video');
    if (!supportsProcessedVideoSource(source)) {
      throw const RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'Processed video is unavailable.',
      );
    }
    await _session._requireEngine().enableLocalVideo(false);
    _customVideoTrackId ??= await _session
        ._requireEngine()
        .createCustomVideoTrack();
    await _processedSink.attach(
      source,
      arguments: {
        'engineHandle': await _session._requireEngine().getNativeHandle(),
        'trackId': _customVideoTrackId,
      },
    );
    await _updatePublishOptions();
  }

  Future<void> _startIosScreenCapture(agora.RtcEngine engine) async {
    final capture = IosSystemScreenCapture.instance;
    if (!await capture.isAvailable) {
      throw const RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        providerId: _agoraProviderId,
        message:
            'Agora screen sharing without a Broadcast Extension needs iOS 27+.',
      );
    }
    ProcessedVideoSource? source;
    int? videoTrackId;
    try {
      source = await capture.start();
      videoTrackId = await engine.createCustomVideoTrack();
      await _iosScreenSink.attach(
        source,
        arguments: {
          'engineHandle': await engine.getNativeHandle(),
          'trackId': videoTrackId,
        },
      );
      _iosScreenCaptureSource = source;
      _iosScreenTrackId = videoTrackId;
      capture.onSystemStopped(_onIosSystemCaptureEnded);
    } catch (_) {
      try {
        await _iosScreenSink.detach();
      } finally {
        try {
          if (videoTrackId != null) {
            await engine.destroyCustomVideoTrack(videoTrackId);
          }
        } finally {
          await capture.stop();
        }
      }
      rethrow;
    }
  }

  Future<void> _stopIosScreenCapture(agora.RtcEngine engine) async {
    final videoTrackId = _iosScreenTrackId;
    _iosScreenTrackId = null;
    _iosScreenCaptureSource = null;
    try {
      await _iosScreenSink.detach();
    } finally {
      try {
        if (videoTrackId != null) {
          await engine.destroyCustomVideoTrack(videoTrackId);
        }
      } finally {
        await IosSystemScreenCapture.instance.stop();
      }
    }
  }

  Future<void> _onIosSystemCaptureEnded() async {
    if (!_localScreenShareEnabled || _session._engine == null) return;
    await setScreenShareEnabledInternal(false);
  }

  Future<void> detachProcessedVideoSource() => _processedSink.detach();

  Future<List<MediaDevice>> listMediaDevices({
    Set<MediaDeviceKind>? kinds,
  }) async {
    _ensurePublisherActive('camera device selection');
    if (!capabilities.canEnumerateCameras ||
        (kinds != null && !kinds.contains(MediaDeviceKind.camera))) {
      return const [];
    }
    return List.unmodifiable([
      for (final camera in await ProcessedVideoBridge().listCameras())
        MediaDevice(
          id: camera.id,
          label: camera.label,
          kind: MediaDeviceKind.camera,
        ),
    ]);
  }

  Future<void> selectMediaDevice(MediaDevice device) async {
    _ensurePublisherActive('camera device selection');
    if (device.kind != MediaDeviceKind.camera ||
        !capabilities.canSelectCamera) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        providerId: providerId,
        message: 'This media device cannot be selected.',
      );
    }
    if (_processedSink.source == null) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidState,
        providerId: providerId,
        message: 'Prepare the SDK video source before selecting a camera.',
      );
    }
    await _processedSink.selectCamera(device.id);
  }

  agora.ChannelMediaOptions _channelOptions() => agora.ChannelMediaOptions(
    channelProfile: agora.ChannelProfileType.channelProfileLiveBroadcasting,
    clientRoleType: _session._canPublish
        ? agora.ClientRoleType.clientRoleBroadcaster
        : agora.ClientRoleType.clientRoleAudience,
    autoSubscribeAudio: true,
    autoSubscribeVideo: true,
    publishMicrophoneTrack: _session._canPublish && !_localMuted,
    publishCameraTrack:
        _session._canPublish &&
        _localVideoEnabled &&
        !_localScreenShareEnabled &&
        _processedSink.source == null,
    publishCustomVideoTrack:
        _session._canPublish &&
        ((_localScreenShareEnabled && _iosScreenTrackId != null) ||
            (_localVideoEnabled &&
                !_localScreenShareEnabled &&
                _processedSink.source != null)),
    customVideoTrackId: _localScreenShareEnabled && _iosScreenTrackId != null
        ? _iosScreenTrackId
        : _customVideoTrackId,
    publishScreenCaptureAudio: false,
    // Only Android/iOS use publishScreenCaptureVideo. Desktop capture requires
    // publishScreenTrack or peers receive a black screen despite local preview.
    publishScreenCaptureVideo:
        _session._canPublish &&
        _localScreenShareEnabled &&
        _iosScreenTrackId == null &&
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS),
    publishScreenTrack:
        _session._canPublish &&
        _localScreenShareEnabled &&
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS),
    enableAudioRecordingOrPlayout: true,
  );

  Future<void> setMutedInternal(bool muted) async {
    _ensurePublisherActive('microphone');
    final engine = _session._requireEngine();
    try {
      // Do not stop/recreate the iOS audio capture engine for ordinary mute.
      // Agora documents that enableLocalAudio(false/true) can interrupt
      // remote playout; muteLocalAudioStream only changes publication.
      // Audio capture is already enabled by the engine's default policy.
      await engine.muteLocalAudioStream(muted);
      _localMuted = muted;
      await _updatePublishOptions();
      _session._mapper._updateLocalParticipant();
      _session._refreshSnapshot();
      _session._emit(MediaLocalMediaChanged(muted: muted));
    } catch (error, stack) {
      throw _session._mapError(error, 'setMuted', stack: stack);
    }
  }

  Future<void> toggleMuteInternal() => setMutedInternal(!_localMuted);

  Future<void> setVideoEnabledInternal(bool enabled) async {
    _ensurePublisherActive('camera');
    final engine = _session._requireEngine();
    try {
      if (_processedSink.source == null) {
        await engine.enableLocalVideo(enabled);
      } else {
        await _processedSink.setEnabled(enabled);
      }
      // Muting outgoing camera video must not mute an active screen track.
      await engine.muteLocalVideoStream(
        !enabled && !_localScreenShareEnabled,
      );
      _localVideoEnabled = enabled;
      await _updatePublishOptions();
      final localId = _session._localUid;
      final beforeTrack = localId == null
          ? null
          : _session._mapper._participants[localId.toString()]?.videoTrack;
      _session._mapper._updateLocalParticipant();
      _session._refreshSnapshot();
      _session._emit(MediaLocalMediaChanged(videoEnabled: enabled));
      if (localId != null) {
        if (enabled && beforeTrack == null) {
          final track = _session._mapper._videoTrack(localId, local: true);
          if (track != null) _session._emit(MediaTrackPublished(track));
        } else if (!enabled && beforeTrack != null) {
          _session._emit(
            MediaTrackUnpublished(
              trackId: beforeTrack.id,
              participantId: localId.toString(),
            ),
          );
        }
      }
    } catch (error, stack) {
      throw _session._mapError(error, 'setVideoEnabled', stack: stack);
    }
  }

  Future<void> switchCameraInternal(MediaCameraPosition position) async {
    if (!capabilities.canSwitchCamera) {
      throw const RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message:
            'Agora front/back camera switching is available on Android and '
            'iOS only. macOS uses the current desktop camera.',
        providerId: _agoraProviderId,
      );
    }
    _ensurePublisherActive('camera switching');
    if (position == _cameraPosition) return;
    try {
      if (_processedSink.source != null) {
        await _processedSink.selectCamera(
          position == MediaCameraPosition.front ? 'front' : 'back',
        );
      } else {
        await _session._requireEngine().switchCamera();
      }
      _cameraPosition = position;
    } catch (error, stack) {
      throw _session._mapError(error, 'switchCamera', stack: stack);
    }
  }

  Future<void> setScreenShareEnabledInternal(bool enabled) async {
    if (!capabilities.canScreenShare) {
      throw const RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'Screen sharing is unavailable on this Agora platform.',
        providerId: _agoraProviderId,
      );
    }
    _ensurePublisherActive('screen sharing');
    if (_localScreenShareEnabled == enabled) return;
    final engine = _session._requireEngine();
    try {
      if (enabled) {
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
          await _startIosScreenCapture(engine);
        } else {
          await _screenCapture.start(engine, defaultTargetPlatform);
        }
        _localScreenShareEnabled = true;
        try {
          await engine.muteLocalVideoStream(false);
          await _updatePublishOptions();
        } catch (_) {
          _localScreenShareEnabled = false;
          if (_iosScreenCaptureSource != null) {
            await _stopIosScreenCapture(engine);
          } else {
            await _screenCapture.stop(engine);
          }
          if (!_localVideoEnabled) {
            await engine.muteLocalVideoStream(true);
          }
          rethrow;
        }
        _startScreenShareAnnouncements();
        final uid = _session._localUid;
        if (uid != null) {
          final track = AgoraMediaVideoTrack(
            engine: engine,
            channelId: _session._joinInfo!.channelName,
            uid: uid,
            local: true,
            screenShare: true,
          );
          _localScreenTrack = track;
          _session._emit(MediaTrackPublished(track));
        }
      } else {
        _stopScreenShareAnnouncements();
        // Announce while screen video is still published. Agora can reject
        // data-stream packets after the last AV track is unpublished.
        await _session._data._announceScreenShareState(false);
        if (_iosScreenCaptureSource != null) {
          await _stopIosScreenCapture(engine);
        } else {
          await _screenCapture.stop(engine);
        }
        _localScreenShareEnabled = false;
        final track = _localScreenTrack;
        _localScreenTrack = null;
        if (track != null) {
          _session._emit(
            MediaTrackUnpublished(
              trackId: track.id,
              participantId: track.participantId,
              wasScreenShare: true,
            ),
          );
        }
        await _updatePublishOptions();
        if (!_localVideoEnabled) {
          await engine.muteLocalVideoStream(true);
        }
      }
      _session._refreshSnapshot();
      // Metadata is separate from media publication. If data transport fails,
      // capture remains active and the failure is reported independently.
      if (enabled) unawaited(_session._data._announceScreenShareState(true));
    } catch (error, stack) {
      _session._refreshSnapshot();
      throw _session._mapError(error, 'screenShare', stack: stack);
    }
  }

  Future<List<MediaAudioDevice>> listAudioDevicesInternal() {
    throw const RealtimeException(
      code: RealtimeErrorCode.unsupportedFeature,
      message: 'Agora audio-device enumeration is not exposed yet.',
      providerId: _agoraProviderId,
    );
  }

  Future<void> selectAudioDeviceInternal(MediaAudioDevice device) {
    throw const RealtimeException(
      code: RealtimeErrorCode.unsupportedFeature,
      message: 'Agora audio-device selection is not exposed yet.',
      providerId: _agoraProviderId,
    );
  }

  Future<void> _updatePublishOptions() async {
    if (!_session._canPublish) return;
    await _session._requireEngine().updateChannelMediaOptions(
      _channelOptions(),
    );
  }

  void _ensurePublisherActive(String feature) {
    _session._ensureActive();
    if (!_session._canPublish) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'Agora viewer sessions cannot use $feature.',
        providerId: providerId,
      );
    }
  }
}
