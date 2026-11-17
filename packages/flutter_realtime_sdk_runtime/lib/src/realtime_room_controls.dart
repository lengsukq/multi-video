part of 'realtime_room.dart';

/// Unified room-level media, device, data, and lifecycle command facade.
///
/// Lifts high-frequency controls and domain guardrails onto [RealtimeRoom] so
/// neither UI controllers nor headless integrators need to pierce
/// `room.media.session` or downcast `InteractiveMediaSession`.
extension RealtimeRoomControls on RealtimeRoom {
  InteractiveMediaSession? get _interactiveSession =>
      media.session is InteractiveMediaSession
      ? media.session as InteractiveMediaSession
      : null;

  /// Latest immutable room media snapshot.
  MediaSnapshot get snapshot => media.snapshot;

  /// Stream of room media snapshot updates.
  Stream<MediaSnapshot> get snapshots => media.snapshots;

  /// Active media role for the local participant.
  MediaRole get role => media.role;

  /// Authoritative meeting policy when operating in meeting mode.
  MediaMeetingMode? get meetingMode => media.meetingMode;

  /// Whether the local participant owns logical-room lifecycle authority.
  bool get isLogicalOwner => media.isLogicalOwner;

  /// Whether an explicit room-owner credential was provisioned for this join.
  bool get hasOwnerCredential => media.roomOwnerCredential != null;

  /// Backend/provider management capabilities available to this participant.
  MediaManagementCapabilities get managementCapabilities =>
      media.managementCapabilities;

  /// Incoming provider-neutral RTC data messages.
  Stream<MediaMessage> get rtcDataMessages => media.session.dataMessages;

  bool get _canControlActiveSession => !_disposed && !snapshot.state.isTerminal;

  bool get canUseMicrophone =>
      _canControlActiveSession &&
      _interactiveSession != null &&
      snapshot.capabilities.canPublishAudio;

  bool get canUseCamera =>
      _canControlActiveSession &&
      _interactiveSession != null &&
      snapshot.capabilities.canPublishVideo;

  bool get canShareScreen =>
      _canControlActiveSession &&
      _interactiveSession != null &&
      snapshot.capabilities.canScreenShare;

  bool get canSelectScreenShareSource =>
      canShareScreen && media.session is MediaScreenShareSourceSelector;

  bool get canSwitchCamera =>
      _canControlActiveSession &&
      _interactiveSession != null &&
      snapshot.capabilities.canSwitchCamera;

  bool get canListAudioOutputs =>
      _canControlActiveSession &&
      _interactiveSession != null &&
      snapshot.capabilities.canEnumerateAudioDevices;

  bool get canSelectAudioOutput =>
      canListAudioOutputs && snapshot.capabilities.canSelectAudioOutput;

  bool get canSendRtcData =>
      _canControlActiveSession && snapshot.capabilities.canSendData;

  bool canListMediaDevices(MediaDeviceKind kind) => switch (kind) {
    MediaDeviceKind.microphone => snapshot.capabilities.canEnumerateMicrophones,
    MediaDeviceKind.camera => snapshot.capabilities.canEnumerateCameras,
    MediaDeviceKind.audioOutput =>
      snapshot.capabilities.canEnumerateAudioDevices,
  };

  bool canSelectMediaDevice(MediaDeviceKind kind) => switch (kind) {
    MediaDeviceKind.microphone => snapshot.capabilities.canSelectMicrophone,
    MediaDeviceKind.camera => snapshot.capabilities.canSelectCamera,
    MediaDeviceKind.audioOutput => snapshot.capabilities.canSelectAudioOutput,
  };

  Never _throwDisposed() => throw const RealtimeException(
    code: RealtimeErrorCode.invalidState,
    message: 'The room has been disposed.',
  );

  /// Mutes or unmutes the local microphone, confirming provider snapshot sync
  /// by default so unapplied commands never masquerade as open audio.
  Future<void> setMicrophoneMuted(
    bool muted, {
    bool verifySnapshot = true,
  }) async {
    if (_disposed) _throwDisposed();
    final session = _interactiveSession;
    if (session == null || !snapshot.capabilities.canPublishAudio) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'Microphone publishing is unavailable for this room.',
        providerId: providerId,
      );
    }
    await session.setMuted(muted);
    if (verifySnapshot && media.snapshot.localMuted != muted) {
      throw RealtimeException(
        code: RealtimeErrorCode.providerError,
        domain: 'media',
        providerId: engineProviderId,
        operation: 'setMuted',
        recoverable: true,
        message: 'Microphone state was not confirmed by the RTC provider.',
      );
    }
  }

  /// Toggles the local microphone based on the authoritative room [snapshot].
  Future<void> toggleMicrophone({bool verifySnapshot = true}) =>
      setMicrophoneMuted(!snapshot.localMuted, verifySnapshot: verifySnapshot);

  /// Toggles the local camera through the coordinated video-effects pipeline.
  Future<void> toggleCamera() => setCameraEnabled(!snapshot.localVideoEnabled);

  /// Lists selectable desktop displays and windows when supported.
  Future<List<MediaScreenShareSource>> listScreenShareSources() {
    if (_disposed) {
      return Future<List<MediaScreenShareSource>>.error(
        const RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'The room has been disposed.',
        ),
      );
    }
    final session = media.session;
    if (session is! MediaScreenShareSourceSelector) {
      return Future<List<MediaScreenShareSource>>.value(
        const <MediaScreenShareSource>[],
      );
    }
    return (session as MediaScreenShareSourceSelector).listScreenShareSources();
  }

  /// Selects a desktop display or window prior to enabling screen sharing.
  Future<void> selectScreenShareSource(MediaScreenShareSource source) async {
    if (_disposed) _throwDisposed();
    final session = media.session;
    if (session is! MediaScreenShareSourceSelector) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'This RTC provider does not support selecting screen sources.',
        providerId: providerId,
      );
    }
    await (session as MediaScreenShareSourceSelector).selectScreenShareSource(
      source,
    );
  }

  /// Starts or stops local screen sharing with remote-occupancy protection and
  /// provider snapshot confirmation.
  Future<void> setScreenShareEnabled(
    bool enabled, {
    MediaScreenShareSource? source,
    bool checkOccupancy = true,
    bool verifySnapshot = true,
  }) async {
    if (_disposed) _throwDisposed();
    final session = _interactiveSession;
    if (session == null || !snapshot.capabilities.canScreenShare) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'Screen sharing is unavailable for this room.',
        providerId: providerId,
      );
    }
    if (enabled && checkOccupancy && !snapshot.localScreenShareEnabled) {
      final occupied = snapshot.contentShareTrack?.isLocal == false;
      if (occupied) {
        throw const RealtimeException(
          code: RealtimeErrorCode.roomConflict,
          domain: 'sharedContent',
          operation: 'screenShare',
          message: 'Another participant is already sharing their screen.',
          recoverable: true,
          suggestedAction: 'wait-for-screen-sharing-to-end',
        );
      }
    }
    if (enabled && source != null) {
      await selectScreenShareSource(source);
    }
    await session.setScreenShareEnabled(enabled);
    if (verifySnapshot && media.snapshot.localScreenShareEnabled != enabled) {
      throw RealtimeException(
        code: RealtimeErrorCode.providerError,
        providerId: engineProviderId,
        operation: 'screenShare',
        message: 'RTC provider did not confirm screen-share state.',
      );
    }
  }

  /// Toggles local screen sharing based on the authoritative room [snapshot].
  Future<void> toggleScreenShare({
    MediaScreenShareSource? source,
    bool checkOccupancy = true,
    bool verifySnapshot = true,
  }) => setScreenShareEnabled(
    !snapshot.localScreenShareEnabled,
    source: source,
    checkOccupancy: checkOccupancy,
    verifySnapshot: verifySnapshot,
  );

  /// Switches between front and back cameras.
  Future<void> switchCamera(MediaCameraPosition position) async {
    if (_disposed) _throwDisposed();
    final session = _interactiveSession;
    if (session == null || !snapshot.capabilities.canSwitchCamera) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'Camera switching is unavailable for this room.',
        providerId: providerId,
      );
    }
    await session.switchCamera(position);
  }

  /// Lists local media devices matching [kinds].
  Future<List<MediaDevice>> listMediaDevices({Set<MediaDeviceKind>? kinds}) {
    if (_disposed) {
      return Future<List<MediaDevice>>.error(
        const RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'The room has been disposed.',
        ),
      );
    }
    return media.session.listMediaDevices(kinds: kinds);
  }

  /// Selects a previously enumerated local media device.
  Future<void> selectMediaDevice(MediaDevice device) {
    if (_disposed) {
      return Future<void>.error(
        const RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'The room has been disposed.',
        ),
      );
    }
    return media.session.selectMediaDevice(device);
  }

  /// Lists audio output routes exposed by interactive mobile/desktop sessions.
  Future<List<MediaAudioDevice>> listAudioOutputs() {
    if (_disposed) {
      return Future<List<MediaAudioDevice>>.error(
        const RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'The room has been disposed.',
        ),
      );
    }
    final session = _interactiveSession;
    if (session == null || !snapshot.capabilities.canEnumerateAudioDevices) {
      return Future<List<MediaAudioDevice>>.error(
        RealtimeException(
          code: RealtimeErrorCode.unsupportedFeature,
          message: 'Audio output enumeration is unavailable for this room.',
          providerId: providerId,
        ),
      );
    }
    return session.listAudioDevices();
  }

  /// Selects an audio output route returned by [listAudioOutputs].
  Future<void> selectAudioOutput(MediaAudioDevice device) {
    if (_disposed) {
      return Future<void>.error(
        const RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'The room has been disposed.',
        ),
      );
    }
    final session = _interactiveSession;
    if (session == null || !canSelectAudioOutput) {
      return Future<void>.error(
        RealtimeException(
          code: RealtimeErrorCode.unsupportedFeature,
          message: 'Audio output selection is unavailable for this room.',
          providerId: providerId,
        ),
      );
    }
    return session.selectAudioDevice(device);
  }

  /// Sends a realtime RTC data message on the room's media data channel.
  Future<void> sendRtcData(
    String message, {
    MediaSendOptions options = const MediaSendOptions(),
  }) {
    if (_disposed) {
      return Future<void>.error(
        const RealtimeException(
          code: RealtimeErrorCode.invalidState,
          message: 'The room has been disposed.',
        ),
      );
    }
    return media.session.sendData(message, options: options);
  }

  /// Applies pre-join device, virtual-background, microphone, and camera
  /// choices safely without callers piercing `media.session`.
  Future<void> applyInitialMediaSettings(
    MediaLocalPreviewSettings settings, {
    bool backgroundAlreadyPrepared = false,
    required bool Function() isCurrent,
    required bool Function() canEnableMicrophone,
    required void Function(RealtimeException error) onError,
  }) async {
    final session = media.session;
    if (session is MediaDeviceController) {
      final devices = session as MediaDeviceController;
      for (final device in [
        settings.microphone,
        settings.camera,
        settings.audioOutput,
      ]) {
        if (!isCurrent()) return;
        if (device == null || !canSelectMediaDevice(device.kind)) continue;
        try {
          await devices.selectMediaDevice(device);
        } catch (error, stack) {
          if (isCurrent()) {
            onError(
              normalizeRealtimeException(
                error,
                domain: 'media',
                operation: 'selectDevice',
                providerId: providerId,
                stackTrace: stack,
              ),
            );
          }
        }
      }
    }
    if (!isCurrent()) return;
    var allowVideo = true;
    if (!backgroundAlreadyPrepared) {
      try {
        await setBackgroundEffect(settings.backgroundEffect);
      } catch (error, stack) {
        allowVideo = !settings.backgroundEffect.enabled;
        if (isCurrent()) {
          onError(
            normalizeRealtimeException(
              error,
              domain: 'videoEffects',
              operation: 'setBackgroundEffect',
              providerId: providerId,
              stackTrace: stack,
            ),
          );
        }
      }
    }
    final interactive = _interactiveSession;
    if (!isCurrent() || interactive == null) return;
    var stage = 'initialSettings.setMuted';
    try {
      await interactive.setMuted(
        !settings.microphoneEnabled || !canEnableMicrophone(),
      );
      if (!isCurrent()) return;
      stage = 'initialSettings.setVideoEnabled';
      final targetVideo = settings.cameraEnabled && allowVideo;
      if (snapshot.localVideoEnabled != targetVideo) {
        await setCameraEnabled(targetVideo);
      }
    } catch (error, stack) {
      if (isCurrent()) {
        onError(
          normalizeRealtimeException(
            error,
            domain: 'media',
            operation: stage,
            providerId: providerId,
            stackTrace: stack,
          ),
        );
      }
    }
  }

  /// Leaves the room—or authoritatively closes it for everyone when the caller
  /// is the logical owner (or [closeForEveryone] is true)—stopping active cloud
  /// recordings before room teardown.
  ///
  /// Concurrent callers share the same in-flight Future; failures prior to
  /// teardown clear the latch so the caller can retry safely.
  Future<void> leaveRoom({
    bool? closeForEveryone,
    Future<void> Function()? beforeDispose,
  }) {
    final pending = _leaveRoomFuture;
    if (pending != null) return pending;
    return _leaveRoomFuture = _leaveRoomOnce(
      closeForEveryone: closeForEveryone,
      beforeDispose: beforeDispose,
    );
  }

  Future<void> _leaveRoomOnce({
    bool? closeForEveryone,
    Future<void> Function()? beforeDispose,
  }) async {
    final alreadyTerminal = _disposed || snapshot.state.isTerminal;
    try {
      var remoteRoomClosed = false;
      final endsRoom = closeForEveryone ?? isLogicalOwner;
      if (endsRoom) {
        if (alreadyTerminal) {
          if (managementCapabilities.closeRoom.supported) {
            try {
              await media.closeRoom();
              remoteRoomClosed = true;
            } on RealtimeException catch (error) {
              if (error.code != RealtimeErrorCode.roomNotFound &&
                  error.code != RealtimeErrorCode.invalidState &&
                  error.statusCode != 404) {
                rethrow;
              }
              remoteRoomClosed = true;
            }
          }
        } else {
          final state = recordingStatus;
          if (state == RecordingStatus.starting ||
              state == RecordingStatus.stopping) {
            throw const RealtimeException(
              code: RealtimeErrorCode.invalidState,
              message:
                  'Wait for the cloud recording operation to finish before ending the room.',
            );
          }
          var roomGoneOnBackend = false;
          RecordingTaskState? remote;
          if (state == RecordingStatus.unknown && recording.isConfigured) {
            try {
              remote = (await queryCloudRecording()).taskState;
            } on RealtimeException catch (error) {
              if (error.code == RealtimeErrorCode.roomNotFound ||
                  error.statusCode == 404) {
                roomGoneOnBackend = true;
              } else {
                rethrow;
              }
            }
          }
          if (!roomGoneOnBackend &&
              (state == RecordingStatus.recording ||
                  remote == RecordingTaskState.recording)) {
            try {
              await stopRecording();
            } on RealtimeException catch (error) {
              if (error.code == RealtimeErrorCode.roomNotFound ||
                  error.statusCode == 404) {
                roomGoneOnBackend = true;
              } else {
                rethrow;
              }
            }
          }
          if (roomGoneOnBackend) {
            remoteRoomClosed = true;
          } else {
            await media.closeRoom();
            remoteRoomClosed = true;
          }
        }
      }
      if (beforeDispose != null) {
        await beforeDispose();
      }
      try {
        await dispose();
      } catch (error, stack) {
        if (!remoteRoomClosed && !alreadyTerminal) rethrow;
        assert(() {
          debugPrint(
            '[room/close] room closed or terminal; local cleanup reported: $error',
          );
          debugPrint('[room/close] $stack');
          return true;
        }());
      }
    } catch (_) {
      _leaveRoomFuture = null;
      rethrow;
    }
  }
}
