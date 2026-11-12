import 'dart:convert';

import 'package:agora_rtc_engine/agora_rtc_engine.dart' as agora;
import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_media_agora/flutter_realtime_media_agora.dart';
import 'package:flutter_realtime_media_agora/src/agora_screen_share_signals.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_test/flutter_test.dart';

AgoraJoinInfo _credential() => AgoraJoinInfo(
  roomCode: 'r-android',
  participantId: '123',
  role: MediaRole.participant,
  appId: 'app-id',
  channelName: 'channel',
  token: 'token',
  uid: 123,
);

class _ScreenEngine extends Fake implements agora.RtcEngine {
  agora.RtcEngineEventHandler? handler;
  int startCount = 0;
  int stopCount = 0;
  int updates = 0;
  final List<bool> captureEnableCalls = [];
  final List<bool> audioMuteCalls = [];
  final List<bool> videoMuteCalls = [];
  bool failStart = false;
  final List<Uint8List> announcedMessages = [];
  final List<int> selectedDesktopDisplays = [];
  final List<int> selectedDesktopWindows = [];
  List<agora.ScreenCaptureSourceInfo> desktopSources = [];
  final List<agora.ChannelMediaOptions> mediaOptions = [];
  @override
  Future<void> initialize(agora.RtcEngineContext context) async {}
  @override
  void registerEventHandler(agora.RtcEngineEventHandler eventHandler) {
    handler = eventHandler;
  }

  @override
  Future<List<agora.ScreenCaptureSourceInfo>> getScreenCaptureSources({
    required agora.SIZE thumbSize,
    required agora.SIZE iconSize,
    required bool includeScreen,
  }) async {
    expect(includeScreen, isTrue);
    return desktopSources;
  }

  @override
  Future<void> startScreenCaptureByDisplayId({
    required int displayId,
    required agora.Rectangle regionRect,
    required agora.ScreenCaptureParameters captureParams,
  }) async {
    selectedDesktopDisplays.add(displayId);
  }

  @override
  Future<void> startScreenCaptureByWindowId({
    required int windowId,
    required agora.Rectangle regionRect,
    required agora.ScreenCaptureParameters captureParams,
  }) async {
    selectedDesktopWindows.add(windowId);
  }

  @override
  void unregisterEventHandler(agora.RtcEngineEventHandler eventHandler) {
    handler = null;
  }

  @override
  Future<void> enableAudio() async {}
  @override
  Future<void> enableLocalAudio(bool enabled) async {
    captureEnableCalls.add(enabled);
  }
  @override
  Future<void> muteLocalAudioStream(bool mute) async {
    audioMuteCalls.add(mute);
  }
  @override
  Future<void> muteLocalVideoStream(bool mute) async {
    videoMuteCalls.add(mute);
  }
  @override
  Future<void> enableVideo() async {}
  @override
  Future<void> enableAudioVolumeIndication({
    required int interval,
    required int smooth,
    required bool reportVad,
  }) async {}
  @override
  Future<void> joinChannel({
    required String token,
    required String channelId,
    required int uid,
    required agora.ChannelMediaOptions options,
  }) async {
    mediaOptions.add(options);
    await Future.microtask(() {
      handler?.onJoinChannelSuccess?.call(
        agora.RtcConnection(channelId: channelId, localUid: uid),
        1,
      );
    });
  }

  @override
  Future<void> updateChannelMediaOptions(
    agora.ChannelMediaOptions options,
  ) async {
    updates++;
    mediaOptions.add(options);
  }

  @override
  Future<void> startScreenCapture(agora.ScreenCaptureParameters2 params) async {
    startCount++;
    expect(params.captureVideo, isTrue);
    expect(params.captureAudio, isFalse);
    if (failStart) throw StateError('permission rejected');
  }

  @override
  Future<void> stopScreenCapture() async {
    stopCount++;
  }

  @override
  Future<int> createDataStream(agora.DataStreamConfig config) async => 6;

  @override
  Future<void> sendStreamMessage({
    required int streamId,
    required Uint8List data,
    required int length,
  }) async {
    expect(streamId, 6);
    expect(length, data.length);
    announcedMessages.add(data);
  }

  @override
  Future<void> leaveChannel({agora.LeaveChannelOptions? options}) async {}
  @override
  Future<void> release({bool sync = false}) async {}
}

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('muting audio never restarts native capture or receiver', () async {
    final engine = _ScreenEngine();
    final session = AgoraInteractiveSession(engineFactory: () => engine);
    await session.join(_credential());
    await session.setMuted(false);
    await session.setMuted(true);
    await session.setMuted(false);
    expect(engine.audioMuteCalls, [false, true, false]);
    expect(engine.captureEnableCalls, isEmpty,
        reason: 'enableLocalAudio restarts the native capture/audio route');
    expect(session.snapshot.localMuted, isFalse);
    expect(engine.mediaOptions.last.publishMicrophoneTrack, isTrue);
    await session.dispose();
  });

  test(
    'native error payload stays in diagnostics rather than the public message',
    () async {
      final engine = _ScreenEngine();
      final session = AgoraInteractiveSession(engineFactory: () => engine);
      await session.join(_credential());
      engine.handler!.onError!(
        agora.ErrorCodeType.errFailed,
        'secret native payload',
      );
      expect(session.snapshot.lastError!.code, RealtimeErrorCode.providerError);
      expect(
        session.snapshot.lastError!.message,
        isNot(contains('secret native payload')),
      );
      await session.dispose();
    },
  );

  test('remote screen share appears when camera is stopped before screen arrives',
      () async {
    final engine = _ScreenEngine();
    final session = AgoraInteractiveSession(engineFactory: () => engine);
    await session.join(_credential());
    const remoteUid = 998;
    const connection = agora.RtcConnection(channelId: 'channel', localUid: 123);
    engine.handler!.onUserJoined?.call(connection, remoteUid, 0);
    engine.handler!.onUserMuteVideo?.call(connection, remoteUid, true);
    // Screen capture is announced independently of the camera's state.
    final data = encodeAgoraScreenShareSignal(AgoraScreenShareSignal.started);
    engine.handler!.onStreamMessage?.call(
      connection, remoteUid, 6, data, data.length, 0,
    );
    expect(session.snapshot.contentShareTrack?.isScreenShare, isTrue);
    expect(session.snapshot.contentShareTrack?.participantId, '$remoteUid');
    expect(session.snapshot.remoteParticipants.single.videoTrack, isNull);
    engine.handler!.onRemoteVideoStateChanged?.call(
      connection,
      remoteUid,
      agora.RemoteVideoState.remoteVideoStateStopped,
      agora.RemoteVideoStateReason.values.first,
      0,
    );
    expect(session.snapshot.contentShareTrack?.isScreenShare, isTrue,
        reason: 'Camera stop must not remove an active screen video source');
    final stopped = encodeAgoraScreenShareSignal(AgoraScreenShareSignal.stopped);
    engine.handler!.onStreamMessage?.call(
      connection, remoteUid, 6, stopped, stopped.length, 0,
    );
    expect(session.snapshot.contentShareTrack, isNull);
    await session.dispose();
  });

  test('active desktop share periodically refreshes state for receivers',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final engine = _ScreenEngine()
      ..desktopSources = const [
        agora.ScreenCaptureSourceInfo(
          sourceId: 42,
          primaryMonitor: true,
          type: agora.ScreenCaptureSourceType.screencapturesourcetypeScreen,
        ),
      ];
    final session = AgoraInteractiveSession(engineFactory: () => engine);
    await session.join(_credential());
    await session.setScreenShareEnabled(true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final initial = engine.announcedMessages.length;
    await Future<void>.delayed(const Duration(milliseconds: 4250));
    expect(engine.announcedMessages.length, greaterThan(initial));
    await session.setScreenShareEnabled(false);
    final stoppedAt = engine.announcedMessages.length;
    await Future<void>.delayed(const Duration(milliseconds: 4200));
    expect(engine.announcedMessages.length, stoppedAt);
    await session.dispose();
  });

  test('Windows explicitly selects and publishes an application window',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final engine = _ScreenEngine()
      ..desktopSources = [
        const agora.ScreenCaptureSourceInfo(
          sourceId: 9,
          sourceName: 'Primary display',
          primaryMonitor: true,
          type: agora.ScreenCaptureSourceType.screencapturesourcetypeScreen,
        ),
        const agora.ScreenCaptureSourceInfo(
          sourceId: 1204,
          sourceTitle: 'Editor',
          type: agora.ScreenCaptureSourceType.screencapturesourcetypeWindow,
        ),
      ];
    final session = AgoraInteractiveSession(engineFactory: () => engine);
    await session.join(_credential());
    final chooser = session as MediaScreenShareSourceSelector;
    final sources = await chooser.listScreenShareSources();
    expect(sources.length, 2);
    expect(sources.last.name, 'Editor');
    expect(sources.last.kind, MediaScreenShareSourceKind.window);
    await chooser.selectScreenShareSource(sources.last);
    await session.setScreenShareEnabled(true);
    expect(engine.selectedDesktopWindows, [1204]);
    expect(engine.selectedDesktopDisplays, isEmpty);
    expect(engine.mediaOptions.last.publishScreenTrack, isTrue,
        reason: 'Windows must publish the desktop track, not mobile capture');
    expect(engine.mediaOptions.last.publishScreenCaptureVideo, isFalse);
    await session.setScreenShareEnabled(false);
    expect(engine.mediaOptions.last.publishScreenTrack, isFalse);
    expect(engine.videoMuteCalls, [false, true],
        reason: 'Unmute video publication only during screen share');
    await session.dispose();
  });

  test('macOS publishes a desktop screen track, not mobile capture', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final engine = _ScreenEngine()
      ..desktopSources = [
        const agora.ScreenCaptureSourceInfo(
          sourceId: 33,
          primaryMonitor: true,
          type: agora.ScreenCaptureSourceType.screencapturesourcetypeScreen,
        ),
      ];
    final session = AgoraInteractiveSession(engineFactory: () => engine);
    await session.join(_credential());
    await session.setScreenShareEnabled(true);
    expect(engine.mediaOptions.last.publishScreenTrack, isTrue);
    expect(engine.mediaOptions.last.publishScreenCaptureVideo, isFalse);
    await session.setScreenShareEnabled(false);
    expect(engine.mediaOptions.last.publishScreenTrack, isFalse);
    expect(engine.videoMuteCalls, [false, true]);
    await session.dispose();
  });

  test(
    'Agora Android publishes the captured screen and restores camera options on stop',
    () async {
      final engine = _ScreenEngine();
      final session = AgoraInteractiveSession(engineFactory: () => engine);
      await session.join(_credential());
      expect(session.capabilities.canScreenShare, isTrue);
      expect(session.snapshot.localScreenShareEnabled, isFalse);
      final published = <MediaTrackPublished>[];
      final subscription = session.events.listen((event) {
        if (event is MediaTrackPublished) published.add(event);
      });
      await session.setScreenShareEnabled(true);
      expect(engine.startCount, 1);
      expect(session.snapshot.localScreenShareEnabled, isTrue);
      expect(session.snapshot.contentShareTrack?.isScreenShare, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(published.any((event) => event.track.isScreenShare), isTrue);
      expect(engine.mediaOptions.last.publishScreenCaptureVideo, isTrue);
      expect(engine.mediaOptions.last.publishScreenTrack, isFalse);
      expect(engine.mediaOptions.last.publishCameraTrack, isFalse);
      await session.setScreenShareEnabled(true);
      expect(engine.startCount, 1);
      await session.setScreenShareEnabled(false);
      expect(engine.stopCount, 1);
      expect(engine.mediaOptions.last.publishScreenCaptureVideo, isFalse);
      expect(engine.videoMuteCalls, [false, true],
          reason: 'Restore camera-off state after screen share ends');
      expect(
        jsonDecode(utf8.decode(engine.announcedMessages.last))['message'],
        'stopped',
      );
      expect(session.snapshot.localScreenShareEnabled, isFalse);
      expect(session.snapshot.contentShareTrack, isNull);
      await subscription.cancel();
      await session.dispose();
    },
  );

  test(
    'Agora Android screen capture errors do not create phantom active screens',
    () async {
      final engine = _ScreenEngine()..failStart = true;
      final session = AgoraInteractiveSession(engineFactory: () => engine);
      await session.join(_credential());
      await expectLater(
        session.setScreenShareEnabled(true),
        throwsA(isA<RealtimeException>()),
      );
      expect(session.snapshot.localScreenShareEnabled, isFalse);
      expect(session.snapshot.contentShareTrack, isNull);
      expect(engine.updates, 0);
      await session.dispose();
    },
  );

  test(
    'Agora Android session disposal stops an ongoing MediaProjection capture',
    () async {
      final engine = _ScreenEngine();
      final session = AgoraInteractiveSession(engineFactory: () => engine);
      await session.join(_credential());
      await session.setScreenShareEnabled(true);
      await session.dispose();
      expect(engine.stopCount, 1);
    },
  );

  test(
    'remote video migrates from camera to screen and back via RTC data',
    () async {
      final engine = _ScreenEngine();
      final session = AgoraInteractiveSession(engineFactory: () => engine);
      await session.join(_credential());
      const remoteUid = 998;
      final connection = agora.RtcConnection(
        channelId: 'channel',
        localUid: 123,
      );
      engine.handler?.onRemoteVideoStateChanged?.call(
        connection,
        remoteUid,
        agora.RemoteVideoState.remoteVideoStateDecoding,
        agora.RemoteVideoStateReason.values.first,
        0,
      );
      expect(
        session.snapshot.remoteParticipants.single.videoTrack?.isScreenShare,
        false,
      );

      void signal(String state) {
        final data = Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'version': 1,
              'topic': '_flutter_realtime.screen_share.v1',
              'message': state,
            }),
          ),
        );
        engine.handler?.onStreamMessage?.call(
          connection,
          remoteUid,
          6,
          data,
          data.length,
          0,
        );
      }

      signal('started');
      expect(session.snapshot.contentShareTrack?.isScreenShare, true);
      expect(session.snapshot.contentShareTrack?.participantId, '$remoteUid');
      expect(session.snapshot.remoteParticipants.single.videoTrack, isNull);
      expect(session.snapshot.messages, isEmpty);

      signal('stopped');
      expect(session.snapshot.contentShareTrack, isNull);
      expect(
        session.snapshot.remoteParticipants.single.videoTrack?.isScreenShare,
        false,
      );
      expect(session.snapshot.messages, isEmpty);

      signal('started');
      engine.handler?.onUserOffline?.call(
        connection,
        remoteUid,
        agora.UserOfflineReasonType.userOfflineQuit,
      );
      expect(session.snapshot.contentShareTrack, isNull);
      expect(session.snapshot.remoteParticipants, isEmpty);
      await session.dispose();
    },
  );

  test('late joiner receives the active screen-share announcement', () async {
    final engine = _ScreenEngine();
    final session = AgoraInteractiveSession(engineFactory: () => engine);
    await session.join(_credential());
    await session.setScreenShareEnabled(true);
    await Future<void>.delayed(Duration.zero);
    final before = engine.announcedMessages.length;
    engine.handler?.onUserJoined?.call(
      agora.RtcConnection(channelId: 'channel', localUid: 123),
      88,
      0,
    );
    await Future<void>.delayed(Duration.zero);
    expect(engine.announcedMessages.length, before + 1);
    final decoded = jsonDecode(utf8.decode(engine.announcedMessages.last));
    expect(decoded['topic'], '_flutter_realtime.screen_share.v1');
    expect(decoded['message'], 'started');
    await session.dispose();
  });

  test(
    'Agora macOS selects the primary display and releases it on stop',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final engine = _ScreenEngine()
        ..desktopSources = [
          const agora.ScreenCaptureSourceInfo(
            sourceId: 11,
            type: agora.ScreenCaptureSourceType.screencapturesourcetypeScreen,
          ),
          const agora.ScreenCaptureSourceInfo(
            sourceId: 42,
            primaryMonitor: true,
            type: agora.ScreenCaptureSourceType.screencapturesourcetypeScreen,
          ),
        ];
      final session = AgoraInteractiveSession(engineFactory: () => engine);
      await session.join(_credential());
      expect(session.capabilities.canScreenShare, isTrue);
      await session.setScreenShareEnabled(true);
      expect(engine.selectedDesktopDisplays, [42]);
      expect(session.snapshot.localScreenShareEnabled, isTrue);
      await session.setScreenShareEnabled(false);
      expect(engine.stopCount, 1);
      await session.dispose();
    },
  );

  test(
    'Agora desktop with no shareable display reports unsupported and preserves state',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final engine = _ScreenEngine();
      final session = AgoraInteractiveSession(engineFactory: () => engine);
      await session.join(_credential());
      await expectLater(
        session.setScreenShareEnabled(true),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.unsupportedFeature,
          ),
        ),
      );
      expect(session.snapshot.localScreenShareEnabled, isFalse);
      await session.dispose();
    },
  );
}
