part of 'livekit_media_session.dart';

class _LiveKitScreenShare {
  _LiveKitScreenShare(this._session);

  Future<void> _systemScreenCaptureEnded() async {
    final track = _screenCaptureKitTrack;
    if (track == null) return;
    _screenCaptureKitTrack = null;
    final source = _screenCaptureKitSource;
    _screenCaptureKitSource = null;
    try {
      final participant = _session._room?.localParticipant;
      final publication = participant?.getTrackPublicationBySource(
        lk.TrackSource.screenShareVideo,
      );
      if (publication != null) {
        await participant?.removePublishedTrack(publication.sid);
      }
    } finally {
      try {
        if (source != null) await disposeProcessedLiveKitTrack(source);
      } finally {
        await IosSystemScreenCapture.instance.stop();
        await track.dispose();
      }
      _session._mapper._refreshSnapshot();
    }
  }

  final LiveKitMediaSessionBase _session;
  MediaScreenShareSource? selectedSource;

  Future<List<MediaScreenShareSource>> listSources() async {
    _session._ensureActive();
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.windows &&
            defaultTargetPlatform != TargetPlatform.macOS)) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        providerId: _session.providerId,
        message: 'Desktop capture source selection is unavailable here.',
      );
    }
    final sources = await rtc.desktopCapturer.getSources(
      types: [rtc.SourceType.Screen, rtc.SourceType.Window],
    );
    return [
      for (final source in sources)
        MediaScreenShareSource(
          id: source.id,
          name: source.name,
          kind: source.type == rtc.SourceType.Window
              ? MediaScreenShareSourceKind.window
              : MediaScreenShareSourceKind.display,
        ),
    ];
  }

  Future<void> selectSource(MediaScreenShareSource source) async {
    final available = await listSources();
    if (!available.any((item) =>
        item.id == source.id && item.kind == source.kind)) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        providerId: _session.providerId,
        message: 'The selected screen or window is no longer available.',
      );
    }
    selectedSource = source;
  }
  bool _androidScreenShareServiceStarted = false;
  lk.LocalVideoTrack? _screenCaptureKitTrack;
  ProcessedVideoSource? _screenCaptureKitSource;

  static const _iosChannel = MethodChannel(
    'flutter_realtime_media_livekit/ios_broadcast',
  );

  /// Check real host configuration and entitlements before requesting the
  /// system picker. Missing .appex or invalid App Group must not silently
  /// fall back to an in-app recording which freezes after app switching.
  Future<void> _requireIosBroadcastExtension() async {
    Map<Object?, Object?>? config;
    try {
      config = await _iosChannel.invokeMapMethod<Object?, Object?>(
        'configuration',
      );
    } on PlatformException catch (error) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message:
            'Cannot check the iOS Broadcast Upload Extension: ${error.message}',
        providerId: _session.providerId,
        operation: 'screenShare',
        recoverable: true,
        suggestedAction: 'configure-ios-broadcast-extension',
        cause: error,
      );
    } on MissingPluginException catch (error) {
      throw RealtimeException(
        code: RealtimeErrorCode.unsupportedFeature,
        message: 'The iOS broadcast configuration plugin is missing.',
        providerId: _session.providerId,
        operation: 'screenShare',
        recoverable: true,
        suggestedAction: 'rebuild-ios-host',
        cause: error,
      );
    }
    if (config?['configured'] == true) return;
    throw RealtimeException(
      code: RealtimeErrorCode.unsupportedFeature,
      message:
          'To share other iPhone apps, embed a signed ReplayKit Broadcast '
          'Upload Extension and enable the same App Group in both targets.',
      providerId: _session.providerId,
      operation: 'screenShare',
      recoverable: true,
      suggestedAction: 'configure-ios-broadcast-extension',
      details: config?.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  Future<void> _stopIosBroadcastOnRoomTeardown() async {
    if (_screenCaptureKitTrack != null) {
      final track = _screenCaptureKitTrack;
      _screenCaptureKitTrack = null;
      try {
        final source = _screenCaptureKitSource;
        _screenCaptureKitSource = null;
        if (source != null) await disposeProcessedLiveKitTrack(source);
      } finally {
        await IosSystemScreenCapture.instance.stop();
        await track?.dispose();
      }
    }
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.iOS ||
        _session.iosScreenShareMode != IosScreenShareMode.system ||
        !lkb.BroadcastManager().isBroadcasting) {
      return;
    }
    await lkb.BroadcastManager().requestStop();
  }

  Future<void> _setIosSystemScreenShareEnabled(bool enabled) async {
    final participant = _session._requireLocalParticipant();
    if (!enabled && _screenCaptureKitTrack != null) {
      final track = _screenCaptureKitTrack;
      _screenCaptureKitTrack = null;
      final source = _screenCaptureKitSource;
      _screenCaptureKitSource = null;
      try {
        final existing = participant.getTrackPublicationBySource(
          lk.TrackSource.screenShareVideo,
        );
        if (existing != null) {
          await participant.removePublishedTrack(existing.sid);
        }
      } finally {
        try {
          if (source != null) await disposeProcessedLiveKitTrack(source);
        } finally {
          await IosSystemScreenCapture.instance.stop();
          await track?.dispose();
        }
      }
      return;
    }
    if (enabled && _screenCaptureKitTrack != null) return;

    // ScreenCaptureKit on iOS 27+ captures the entire display inside the
    // application process: no ReplayKit extension, App Group or extra
    // provisioning profile. Reuse the SDK's existing native WebRTC source.
    if (enabled && await IosSystemScreenCapture.instance.isAvailable) {
      lk.LocalVideoTrack? track;
      ProcessedVideoSource? source;
      try {
        source = await IosSystemScreenCapture.instance.start();
        track = await createProcessedLiveKitTrack(source, screenShare: true);
        await participant.publishVideoTrack(track);
        if (participant
                .getTrackPublicationBySource(lk.TrackSource.screenShareVideo)
                ?.track ==
            null) {
          throw StateError('The ScreenCaptureKit video was not published.');
        }
        _screenCaptureKitTrack = track;
        _screenCaptureKitSource = source;
        // Register only for the active provider. Constructing an unrelated
        // LiveKit session must not override another RTC provider's callback.
        IosSystemScreenCapture.instance.onSystemStopped(
          _systemScreenCaptureEnded,
        );
      } catch (error) {
        try {
          if (source != null) await disposeProcessedLiveKitTrack(source);
        } finally {
          await IosSystemScreenCapture.instance.stop();
          await track?.dispose();
        }
        rethrow;
      }
      return;
    }
    final manager = lkb.BroadcastManager();
    if (!enabled) {
      // Do not keep recording the user's other apps after the SDK is told
      // to stop. The extension also ends when the video socket is closed.
      if (manager.isBroadcasting) await manager.requestStop();
      if (participant.getTrackPublicationBySource(
            lk.TrackSource.screenShareVideo,
          ) !=
          null) {
        await participant.setScreenShareEnabled(false);
      }
      return;
    }
    await _requireIosBroadcastExtension();
    try {
      await awaitIosSystemBroadcastPublication(
        requestActivation: manager.requestActivation,
        broadcasting: () => manager.isBroadcasting,
        published: () =>
            participant
                .getTrackPublicationBySource(lk.TrackSource.screenShareVideo)
                ?.track !=
            null,
        sessionClosed: () =>
            _session._disposed ||
            _session.state == MediaSessionState.leaving ||
            _session.state == MediaSessionState.ended ||
            _session.state == MediaSessionState.disposed,
      );
    } on IosBroadcastNotStarted catch (error) {
      throw RealtimeException(
        code: RealtimeErrorCode.cancelled,
        message:
            'Screen broadcast was not started. Choose this app in the '
            'iOS broadcast picker and tap Start Broadcast.',
        providerId: _session.providerId,
        operation: 'screenShare',
        recoverable: true,
        suggestedAction: 'retry-screen-sharing',
        cause: error,
      );
    } on IosBroadcastTrackMissing catch (error) {
      throw RealtimeException(
        code: RealtimeErrorCode.timeout,
        message:
            'ReplayKit broadcast started but LiveKit did not publish '
            'a screen video track. Check App Group and extension logs.',
        providerId: _session.providerId,
        operation: 'screenShare',
        recoverable: true,
        suggestedAction: 'check-ios-broadcast-extension',
        cause: error,
      );
    }
  }

  /// LiveKit Flutter 2.4+ returns before capture when
  /// LocalParticipant.setScreenShareEnabled(true) is called on iOS without
  /// a Broadcast Upload Extension, even if useiOSBroadcastExtension is false.
  /// Capture the current app directly through flutter_webrtc instead and
  /// publish a real screenShareVideo track before reporting success.
  ///
  /// This captures only our app's contents. Sharing the entire iOS display
  /// (including other apps) requires a separately signed ReplayKit Broadcast
  /// Upload Extension and a matching App Group in the host application.
  Future<void> _setIosInAppScreenShareEnabled(bool enabled) async {
    final participant = _session._requireLocalParticipant();
    final existing = participant.getTrackPublicationBySource(
      lk.TrackSource.screenShareVideo,
    );
    if (!enabled) {
      if (existing != null) {
        await participant.setScreenShareEnabled(false);
      }
      return;
    }
    if (existing != null) return;

    final track = await captureAndPublishIosInAppScreen<lk.LocalVideoTrack>(
      capture: () => lk.LocalVideoTrack.createScreenShareTrack(
        const lk.ScreenShareCaptureOptions(useiOSBroadcastExtension: false),
      ),
      publish: (track) async {
        await participant.publishVideoTrack(track);
      },
      release: (track) => track.stop(),
    );
    if (participant.getTrackPublicationBySource(
          lk.TrackSource.screenShareVideo,
        ) ==
        null) {
      try {
        await track.stop();
      } catch (_) {
        // Report the missing publication, not the subsequent cleanup error.
      }
      throw RealtimeException(
        code: RealtimeErrorCode.providerError,
        message: 'iOS app screen capture did not publish a LiveKit track.',
        providerId: _session.providerId,
        operation: 'screenShare',
        recoverable: true,
        suggestedAction: 'retry-screen-sharing',
      );
    }
  }

  Future<void> _prepareAndroidScreenShare() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;

    // System annotation windows must be visible in the shared display; an
    // Android single-app projection excludes windows belonging to other apps.
    final permissionGranted = await rtc.Helper.requestCapturePermission(
      fullScreenOnly: true,
    );
    if (!permissionGranted) {
      throw RealtimeException(
        code: RealtimeErrorCode.permissionDenied,
        message: 'Screen-capture permission was denied.',
        providerId: _session.providerId,
      );
    }

    await _androidScreenShareChannel.invokeMethod<void>('start');
    _androidScreenShareServiceStarted = true;
  }

  Future<void> _prepareMacOsScreenShare() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return;

    final permissionGranted = await rtc.Helper.requestCapturePermission();
    if (!permissionGranted) {
      throw RealtimeException(
        code: RealtimeErrorCode.permissionDenied,
        message:
            'LiveKit screen sharing needs macOS Screen Recording permission. '
            'Allow it in System Settings > Privacy & Security > Screen Recording, '
            'then restart the app.',
        providerId: _session.providerId,
      );
    }
  }

  Future<void> _stopAndroidScreenShareService() async {
    if (!_androidScreenShareServiceStarted ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _androidScreenShareServiceStarted = false;
    await _androidScreenShareChannel.invokeMethod<void>('stop');
  }
}
