import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_diagnostics.dart';
import 'package:flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart';
import 'package:flutter_aws_chime/flutter_aws_chime.dart' as chime;
import 'package:flutter_realtime_media_chime/flutter_realtime_media_chime.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chime_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Windows Chime defaults on but fails closed when runtime is missing',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      // Windows WebView2 is enabled without an explicit dart-define, but
      // readiness must still depend on loading the real runtime.
      expect(
        const bool.fromEnvironment(
          'AWS_CHIME_WINDOWS_WEBVIEW2_EXPERIMENTAL',
          defaultValue: true,
        ),
        isTrue,
      );
      expect(await probeNativeChimeAvailability(), isFalse);
      final factory = ChimeSessionFactory();
      final report = await factory.runPreJoinProbe(
        const MediaPreJoinProbeRequest(
          providerId: 'chime',
          role: MediaRole.participant,
          requirements: MediaPreJoinRequirements(),
        ),
      );
      expect(report.checks.single.type, MediaPreJoinCheckType.provider);
      expect(report.checks.single.isBlocking, isTrue);
      // Keep injected probes testable without loading a real desktop browser.
      final ready =
          await ChimeSessionFactory(
            availabilityProbe: () async => true,
          ).runPreJoinProbe(
            const MediaPreJoinProbeRequest(
              providerId: 'chime',
              role: MediaRole.participant,
              requirements: MediaPreJoinRequirements(),
            ),
          );
      expect(
        ready.checks.where(
          (check) => check.type == MediaPreJoinCheckType.provider,
        ),
        isEmpty,
      );
    },
  );

  test(
    'Windows Chime reports SDK load failure rather than absent WebView2',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final report =
          await ChimeSessionFactory(
            availabilityProbe: () async => false,
            windowsDiagnosticProbe: () =>
                AwsWindowsRuntimeDiagnostic.providerSdkUnavailable('chime'),
          ).runPreJoinProbe(
            const MediaPreJoinProbeRequest(
              providerId: 'chime',
              role: MediaRole.participant,
              requirements: MediaPreJoinRequirements(),
            ),
          );
      final check = report.checks.single;
      expect(check.status, MediaPreJoinStatus.failed);
      expect(check.message, contains('JavaScript SDK did not initialize'));
      expect(check.message, isNot(contains('not installed')));
      expect(check.details, {'diagnosticCode': 'providerSdkUnavailable'});
    },
  );

  test(
    'Windows Chime distinguishes an inaccessible camera from WebView2',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final report =
          await ChimeSessionFactory(
            availabilityProbe: () async => true,
            windowsDeviceProbe: () async => (microphones: 1, cameras: 0),
          ).runPreJoinProbe(
            const MediaPreJoinProbeRequest(
              providerId: 'chime',
              role: MediaRole.participant,
              requirements: MediaPreJoinRequirements(
                microphone: MediaPreJoinRequirement.required,
                camera: MediaPreJoinRequirement.required,
              ),
            ),
          );
      final camera = report.checks.singleWhere(
        (check) => check.type == MediaPreJoinCheckType.cameraDevice,
      );
      expect(camera.status, MediaPreJoinStatus.failed);
      expect(camera.message, contains('Windows Settings'));
      expect(
        camera.message,
        isNot(contains('WebView2 Runtime was not detected')),
      );
    },
  );

  test(
    'Windows Chime prejoin uses actual browser device enumeration',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final factory = ChimeSessionFactory(
        availabilityProbe: () async => true,
        windowsDeviceProbe: () async => (microphones: 2, cameras: 1),
      );
      final report = await factory.runPreJoinProbe(
        const MediaPreJoinProbeRequest(
          providerId: 'chime',
          role: MediaRole.participant,
          requirements: MediaPreJoinRequirements(
            microphone: MediaPreJoinRequirement.required,
            camera: MediaPreJoinRequirement.required,
          ),
        ),
      );
      final deviceChecks = report.checks.where(
        (check) =>
            check.type == MediaPreJoinCheckType.microphoneDevice ||
            check.type == MediaPreJoinCheckType.cameraDevice,
      );
      expect(deviceChecks, hasLength(2));
      expect(
        deviceChecks.every(
          (check) => check.status == MediaPreJoinStatus.passed,
        ),
        isTrue,
      );
      expect(
        report.checks
            .singleWhere(
              (check) => check.type == MediaPreJoinCheckType.providerNetwork,
            )
            .isBlocking,
        isFalse,
      );
    },
  );

  test(
    'Chime pre-join still reports device and network limitations on iOS',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final report = await ChimeSessionFactory().runPreJoinProbe(
        const MediaPreJoinProbeRequest(
          providerId: 'chime',
          role: MediaRole.participant,
          requirements: MediaPreJoinRequirements(
            microphone: MediaPreJoinRequirement.required,
            camera: MediaPreJoinRequirement.recommended,
            network: MediaPreJoinRequirement.recommended,
          ),
        ),
      );
      expect(report.checks, hasLength(3));
      final mic = report.checks.singleWhere(
        (check) => check.type == MediaPreJoinCheckType.microphoneDevice,
      );
      expect(mic.status, MediaPreJoinStatus.unsupported);
      expect(mic.isBlocking, isTrue);
    },
  );
  Map<String, dynamic> backendJson({String role = 'participant'}) => {
    'contractVersion': 1,
    'provider': 'chime',
    'role': role,
    'roomCode': '482913',
    'participantId': 'attendee-local',
    'meeting': {
      'MeetingId': 'meeting-id',
      'ExternalMeetingId': 'room-482913',
      'MediaRegion': 'ap-southeast-1',
      'MediaPlacement': {
        'AudioHostUrl': 'https://audio.example',
        'AudioFallbackUrl': 'https://fallback.example',
        'SignalingUrl': 'wss://signal.example',
        'TurnControlUrl': 'https://turn.example',
      },
    },
    'attendee': {
      'AttendeeId': 'attendee-local',
      'ExternalUserId': 'Local User',
      'JoinToken': 'short-lived-token',
    },
  };

  test(
    'Chime retains the provider error code without exposing native payloads',
    () async {
      final provider = _FailingControlSession();
      final adapter = ChimeMediaSession(session: provider);
      addTearDown(adapter.dispose);
      await adapter.join(ChimeJoinInfo.fromBackendResponse(backendJson()));
      await expectLater(
        adapter.setMuted(false),
        throwsA(
          isA<RealtimeException>()
              .having(
                (error) => error.code,
                'code',
                RealtimeErrorCode.permissionDenied,
              )
              .having(
                (error) => error.message,
                'safe message',
                isNot(contains('native secret')),
              )
              .having((error) => error.cause, 'diagnostic cause', isNotNull),
        ),
      );
    },
  );

  test(
    'content modality retains its native ID and maps to its classroom owner',
    () {
      final track = ChimeMediaVideoTrack(
        const chime.MeetingVideoTile(
          tileId: 3,
          attendeeId: 'teacher#content',
          width: 1920,
          height: 1080,
          isLocal: false,
          isContentShare: true,
        ),
      );
      expect(track.participantId, 'teacher#content');
      expect((track as MediaVideoTrack).contentOwnerParticipantId, 'teacher');
      expect(track.isScreenShare, true);
    },
  );
  group('ChimeJoinInfo', () {
    test('wraps the existing Chime JoinInfo without changing its payload', () {
      final info = ChimeJoinInfo.fromBackendResponse(backendJson());

      expect(info.providerId, 'chime');
      expect(info.role, MediaRole.participant);
      expect(info.roomCode, '482913');
      expect(info.participantId, 'attendee-local');
      expect(info.chimeJoinInfo.meeting.meetingId, 'meeting-id');
      expect(info.chimeJoinInfo.attendee.joinToken, 'short-lived-token');
    });

    test('rejects broadcast roles until Chime can enforce them', () {
      expect(
        () => ChimeJoinInfo.fromBackendResponse(backendJson(role: 'viewer')),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.unsupportedFeature,
          ),
        ),
      );
    });
  });

  group('ChimeMediaSession', () {
    test(
      'iOS ScreenCaptureKit delegates actual content sharing to native Chime',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        const capture = MethodChannel(
          'flutter_realtime_processed_video/ios_system_screen_capture',
        );
        const chimeChannel = MethodChannel(
          'com.oneplusdream.aws.chime.methodChannel',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final calls = <String>[];
        messenger.setMockMethodCallHandler(capture, (call) async {
          calls.add(call.method);
          if (call.method == 'iosScreenCaptureKitAvailable') return true;
          if (call.method == 'iosScreenCaptureKitStart') {
            return {
              'id': 'screen-1',
              'kind': 'nativeFrameHub',
              'platform': 'ios',
              'width': 1170,
              'height': 2532,
              'frameRate': 30.0,
            };
          }
          return null;
        });
        messenger.setMockMethodCallHandler(chimeChannel, (call) async {
          calls.add(call.method);
          return {'success': true, 'data': null};
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(capture, null);
          messenger.setMockMethodCallHandler(chimeChannel, null);
        });
        final adapter = ChimeMediaSession(session: FakeChimeMeetingSession());
        await adapter.join(ChimeJoinInfo.fromBackendResponse(backendJson()));
        expect(adapter.capabilities.canScreenShare, isTrue);
        await adapter.setScreenShareEnabled(true);
        expect(adapter.snapshot.localScreenShareEnabled, isTrue);
        expect(calls, contains('attachIosScreenCaptureKitSource'));
        await adapter.setScreenShareEnabled(false);
        expect(adapter.snapshot.localScreenShareEnabled, isFalse);
        expect(calls, contains('detachIosScreenCaptureKitSource'));
        await adapter.dispose();
      },
    );

    test('repeated leave and dispose release Chime exactly once', () async {
      final provider = FakeChimeMeetingSession();
      final adapter = ChimeMediaSession(session: provider);
      final info = ChimeJoinInfo.fromBackendResponse(backendJson());
      await adapter.join(info);
      await adapter.leave();
      await adapter.leave();
      expect(
        provider.actions.where((action) => action == 'leave'),
        hasLength(1),
      );
      final first = adapter.dispose();
      final second = adapter.dispose();
      expect(identical(first, second), isTrue);
      await first;
      expect(
        provider.actions.where((action) => action == 'dispose'),
        hasLength(1),
      );
    });

    test('late provider join cannot revive a room after leave', () async {
      final pending = _PendingChimeSession();
      final adapter = ChimeMediaSession(session: pending);
      final info = ChimeJoinInfo.fromBackendResponse(backendJson());
      final joining = adapter.join(info);
      final failure = expectLater(
        joining,
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.cancelled,
          ),
        ),
      );
      await adapter.leave();
      expect(adapter.state, MediaSessionState.ended);
      pending.finishJoin();
      await failure;
      expect(adapter.state, MediaSessionState.ended);
      await adapter.dispose();
    });

    late FakeChimeMeetingSession providerSession;
    late ChimeMediaSession session;
    late ChimeJoinInfo joinInfo;

    setUp(() {
      providerSession = FakeChimeMeetingSession();
      session = ChimeMediaSession(session: providerSession);
      joinInfo = ChimeJoinInfo.fromBackendResponse(backendJson());
    });

    test(
      'processed input owns camera switching and is released on leave',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final commands = <MethodCall>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        for (final channel in [
          const MethodChannel('com.oneplusdream.aws.chime.methodChannel'),
          const MethodChannel('flutter_realtime_processed_video/sources'),
        ]) {
          messenger.setMockMethodCallHandler(channel, (call) async {
            commands.add(call);
            return null;
          });
          addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        }
        await session.join(joinInfo);
        const source = ProcessedVideoSource(
          id: 'shared-processed-frame-source',
          platform: ProcessedVideoPlatform.android,
          kind: ProcessedVideoSourceKind.nativeFrameHub,
          width: 1280,
          height: 720,
          frameRate: 24,
        );
        await session.attachProcessedVideoSource(source);
        await session.setVideoEnabled(true);
        await session.switchCamera(MediaCameraPosition.back);
        await session.selectMediaDevice(
          const MediaDevice(
            id: 'front',
            label: 'Front',
            kind: MediaDeviceKind.camera,
          ),
        );
        await session.setVideoEnabled(false);
        expect(providerSession.actions, isNot(contains('camera:back')));
        expect(
          commands
              .where((c) => c.method == 'selectCamera')
              .map((c) => (c.arguments as Map)['deviceId']),
          ['back', 'front'],
        );
        await session.leave();
        expect(
          commands.where((c) => c.method == 'detachProcessedVideoSource'),
          hasLength(1),
        );
        await session.dispose();
        expect(
          commands.where((c) => c.method == 'detachProcessedVideoSource'),
          hasLength(1),
        );
      },
    );

    test(
      'macOS declares effects only after a successful native input probe',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        const channel = MethodChannel(
          'com.oneplusdream.aws.chime.methodChannel',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'probeProcessedVideoInput',
        );
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        expect(session.capabilities.canBlurBackground, isFalse);
        await session.join(joinInfo);
        expect(session.capabilities.canBlurBackground, isTrue);
        expect(session.snapshot.capabilities.canReplaceBackgroundImage, isTrue);
        await session.dispose();
      },
    );

    test('maps join state and the local attendee', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await session.join(joinInfo);

      expect(session.state, MediaSessionState.connected);
      expect(session.snapshot.localParticipantId, 'attendee-local');
      expect(session.snapshot.localParticipant?.displayName, 'Local User');
      expect(session.capabilities.canPublishVideo, isTrue);
      expect(session.capabilities.canScreenShare, isTrue);
      expect(session.capabilities.canSelectAudioOutput, isTrue);
      expect(session.capabilities.canSendData, isTrue);
      expect(session.capabilities.canReceiveData, isTrue);
      expect(session.capabilities.maxDataMessageBytes, 2048);
      expect(session.capabilities.canReportNetworkStats, isFalse);
      await session.dispose();
    });

    test(
      'macOS supports desktop screen source selection and sharing',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await session.join(joinInfo);
        expect(session.capabilities.canScreenShare, isTrue);
        final sources = await session.listScreenShareSources();
        expect(sources, hasLength(2));
        await session.selectScreenShareSource(sources.last);
        await session.setScreenShareEnabled(true);
        expect(session.snapshot.localScreenShareEnabled, isTrue);
        await session.setScreenShareEnabled(false);
        expect(session.snapshot.localScreenShareEnabled, isFalse);
        expect(providerSession.actions, contains('listScreenShareSources'));
        expect(
          providerSession.actions,
          contains('selectScreenShareSource:window:42'),
        );
        expect(providerSession.actions, contains('screen:true'));
        expect(providerSession.actions, contains('screen:false'));
        await session.dispose();
      },
    );

    test(
      'maps remote participants, video tiles, speaking, and messages',
      () async {
        await session.join(joinInfo);
        final events = <MediaEvent>[];
        final subscription = session.events.listen(events.add);

        providerSession.emitRemoteParticipant(
          id: 'remote-a',
          name: 'Remote A',
          videoTile: const chime.MeetingVideoTile(
            tileId: 7,
            attendeeId: 'remote-a',
            width: 1280,
            height: 720,
            isLocal: false,
            isContentShare: false,
          ),
        );
        providerSession.emitVolume('remote-a', chime.MeetingVolumeLevel.high);
        await session.sendMessage('hello', topic: 'chat');
        await pumpEventQueue();

        final remote = session.snapshot.remoteParticipants.single;
        expect(remote.id, 'remote-a');
        expect(remote.videoTrack, isA<ChimeMediaVideoTrack>());
        expect(remote.isSpeaking, isTrue);
        expect(session.snapshot.messages.single.message, 'hello');
        expect(session.snapshot.messages.single.providerId, 'chime');
        expect(events.whereType<MediaParticipantJoined>(), isNotEmpty);
        expect(events.whereType<MediaTrackPublished>(), isNotEmpty);
        expect(events.whereType<MediaSpeakingChanged>(), isNotEmpty);
        expect(events.whereType<MediaMessageReceived>(), isNotEmpty);

        providerSession.removeParticipant('remote-a');
        await pumpEventQueue();
        expect(session.snapshot.remoteParticipants, isEmpty);
        expect(events.whereType<MediaParticipantLeft>(), isNotEmpty);

        await subscription.cancel();
        await session.dispose();
      },
    );

    test(
      'delegates controls and rejects unsupported outgoing screen share',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await session.join(joinInfo);

        await session.setMuted(false);
        await session.setVideoEnabled(true);
        await session.switchCamera(MediaCameraPosition.back);
        final devices = await session.listAudioDevices();
        await session.selectAudioDevice(devices.single);

        expect(providerSession.actions, contains('muted:false'));
        expect(providerSession.actions, contains('video:true'));
        expect(providerSession.actions, contains('camera:back'));
        expect(providerSession.actions, contains('audio:Speaker'));
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
        await session.dispose();
      },
    );

    test(
      'dispose is idempotent through the existing provider session',
      () async {
        await session.join(joinInfo);
        await session.dispose();
        await session.dispose();

        expect(session.state, MediaSessionState.disposed);
        expect(
          providerSession.actions.where((item) => item == 'dispose').length,
          1,
        );
      },
    );
  });

  test('factory registers only the role Chime currently guarantees', () {
    final fake = FakeChimeMeetingSession();
    final factory = ChimeSessionFactory(sessionFactory: () => fake);
    final info = ChimeJoinInfo.fromBackendResponse(backendJson());

    expect(factory.providerId, 'chime');
    expect(factory.supportedRoles, {MediaRole.participant});
    expect(factory.createSession(info).chimeSession, same(fake));
  });

  test('iOS supports Chime virtual background processed video input', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('com.oneplusdream.aws.chime.methodChannel');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {'success': true, 'data': null};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final session = ChimeMediaSession(session: FakeChimeMeetingSession());
    addTearDown(session.dispose);
    await session.join(ChimeJoinInfo.fromBackendResponse(backendJson()));
    expect(session.capabilities.canBlurBackground, isTrue);
    expect(session.capabilities.canReplaceBackgroundImage, isTrue);
    const source = ProcessedVideoSource(
      id: 'ios-effects',
      kind: ProcessedVideoSourceKind.nativeFrameHub,
      platform: ProcessedVideoPlatform.ios,
      width: 1280,
      height: 720,
      frameRate: 24,
    );
    expect(session.supportsProcessedVideoSource(source), isTrue);
    await session.attachProcessedVideoSource(source);
    expect(
      calls.any((call) => call.method == 'attachProcessedVideoSource'),
      isTrue,
    );
  });

  test(
    'Android Chime local processed video track uses processed dimensions',
    () {
      const source = ProcessedVideoSource(
        id: 'android-effects',
        kind: ProcessedVideoSourceKind.nativeFrameHub,
        platform: ProcessedVideoPlatform.android,
        width: 1280,
        height: 720,
        frameRate: 24,
      );
      const tile = chime.MeetingVideoTile(
        tileId: 1,
        attendeeId: 'attendee-local',
        width: 720,
        height: 1280,
        isLocal: true,
        isContentShare: false,
      );
      const track = ChimeMediaVideoTrack(tile, processedSource: source);
      expect(track.width, 1280);
      expect(track.height, 720);
    },
  );

  test(
    'Android screen capture delegates content sharing to native Chime',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const capture = MethodChannel(
        'flutter_realtime_processed_video/android_system_screen_capture',
      );
      const chimeChannel = MethodChannel(
        'com.oneplusdream.aws.chime.methodChannel',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(capture, (call) async {
        calls.add(call.method);
        if (call.method == 'androidScreenCaptureAvailable') return true;
        if (call.method == 'androidScreenCaptureStart') {
          return {
            'id': 'android-screen-1',
            'kind': 'nativeFrameHub',
            'platform': 'android',
            'width': 720,
            'height': 1280,
            'frameRate': 15.0,
          };
        }
        return null;
      });
      messenger.setMockMethodCallHandler(chimeChannel, (call) async {
        calls.add(call.method);
        return {'success': true, 'data': null};
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(capture, null);
        messenger.setMockMethodCallHandler(chimeChannel, null);
      });
      final adapter = ChimeMediaSession(session: FakeChimeMeetingSession());
      await adapter.join(ChimeJoinInfo.fromBackendResponse(backendJson()));
      expect(adapter.capabilities.canScreenShare, isTrue);
      await adapter.setScreenShareEnabled(true);
      expect(adapter.snapshot.localScreenShareEnabled, isTrue);
      expect(calls, contains('attachAndroidScreenCaptureSource'));
      await adapter.setScreenShareEnabled(false);
      expect(adapter.snapshot.localScreenShareEnabled, isFalse);
      expect(calls, contains('detachAndroidScreenCaptureSource'));
      await adapter.dispose();
    },
  );

  test(
    'macOS Chime enumerates and selects desktop cameras without video effects',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel('com.oneplusdream.aws.chime.methodChannel');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'probeProcessedVideoInput') return false;
        return {'success': true, 'data': null};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final fake = FakeChimeMeetingSession();
      final adapter = ChimeMediaSession(session: fake);
      addTearDown(adapter.dispose);
      await adapter.join(ChimeJoinInfo.fromBackendResponse(backendJson()));

      expect(adapter.capabilities.canBlurBackground, isFalse);
      expect(adapter.capabilities.canEnumerateCameras, isTrue);
      expect(adapter.capabilities.canSelectCamera, isTrue);
      expect(adapter.capabilities.canEnumerateMicrophones, isTrue);
      expect(adapter.capabilities.canSelectMicrophone, isTrue);

      final cameras = await adapter.listMediaDevices(
        kinds: const {MediaDeviceKind.camera},
      );
      expect(cameras.map((d) => d.id), ['cam-builtin', 'cam-usb']);
      await adapter.selectMediaDevice(cameras.last);
      expect(fake.actions, contains('selectDesktopMediaDevice:camera:cam-usb'));
    },
  );

  test(
    'macOS Chime selects camera without active effects and reconciles ID when effects attach',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const chimeChannel = MethodChannel(
        'com.oneplusdream.aws.chime.methodChannel',
      );
      const sourcesChannel = MethodChannel(
        'flutter_realtime_processed_video/sources',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sourceCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(chimeChannel, (call) async {
        if (call.method == 'probeProcessedVideoInput') return true;
        return null;
      });
      messenger.setMockMethodCallHandler(sourcesChannel, (call) async {
        sourceCalls.add(call);
        if (call.method == 'listCameras') {
          return [
            {
              'id': 'avcapture-builtin-id',
              'label': 'FaceTime HD Camera',
              'isFrontFacing': true,
            },
            {
              'id': 'avcapture-usb-id',
              'label': 'External 4K Webcam',
              'isFrontFacing': false,
            },
          ];
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(chimeChannel, null);
        messenger.setMockMethodCallHandler(sourcesChannel, null);
      });

      final fake = FakeChimeMeetingSession();
      final adapter = ChimeMediaSession(session: fake);
      addTearDown(adapter.dispose);
      await adapter.join(ChimeJoinInfo.fromBackendResponse(backendJson()));

      expect(adapter.capabilities.canBlurBackground, isTrue);
      expect(adapter.capabilities.canEnumerateCameras, isTrue);
      expect(adapter.capabilities.canSelectCamera, isTrue);

      final cameras = await adapter.listMediaDevices(
        kinds: const {MediaDeviceKind.camera},
      );
      expect(cameras.map((d) => d.id), ['cam-builtin', 'cam-usb']);
      await adapter.selectMediaDevice(cameras.last);
      expect(fake.actions, contains('selectDesktopMediaDevice:camera:cam-usb'));

      const source = ProcessedVideoSource(
        id: 'macos-blur-source',
        kind: ProcessedVideoSourceKind.nativeFrameHub,
        platform: ProcessedVideoPlatform.macos,
        width: 1280,
        height: 720,
        frameRate: 30,
      );
      await adapter.attachProcessedVideoSource(source);
      final selectCalls = sourceCalls
          .where((call) => call.method == 'selectCamera')
          .toList();
      expect(selectCalls, hasLength(1));
      expect(
        (selectCalls.single.arguments as Map)['deviceId'],
        'avcapture-usb-id',
      );
    },
  );

  test(
    'Windows Chime bridges virtual background processed video frames and releases on leave',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        AwsWindowsWebView2Runtime.debugResetWindowsChannelHandler();
      });
      const windowsChannel = MethodChannel(
        'com.oneplusdream.flutter_realtime_media_aws_desktop/windows',
      );
      const sourcesChannel = MethodChannel(
        'flutter_realtime_processed_video/sources',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final nativeCalls = <MethodCall>[];
      final sourceCalls = <MethodCall>[];
      final webMessages = <Map<String, dynamic>>[];

      late final AwsWindowsWebView2Runtime testRuntime;
      testRuntime = AwsWindowsWebView2Runtime.forTesting(
        'chime',
        probeOverride: () async => true,
        postWebMessageOverride: (encoded) async {
          final decoded = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
          webMessages.add(decoded);
          if (decoded['id'] != null) {
            testRuntime.debugHandleWebMessage({
              'channel': 'aws-windows-chime-v1',
              'kind': 'result',
              'id': decoded['id'],
              'success': true,
              'value': true,
            });
          }
        },
      );
      addTearDown(testRuntime.dispose);

      messenger.setMockMethodCallHandler(windowsChannel, (call) async {
        nativeCalls.add(call);
        if (call.method == 'probeProcessedVideoInput') return true;
        return null;
      });
      messenger.setMockMethodCallHandler(sourcesChannel, (call) async {
        sourceCalls.add(call);
        if (call.method == 'listCameras') {
          return [
            {
              'id': r'\\?\usb#vid_046d&pid_085e#front',
              'label': 'Integrated Camera',
              'isFrontFacing': true,
            },
            {
              'id': r'\\?\usb#vid_046d&pid_082d#ext',
              'label': 'External 4K Webcam (046d:082d)',
              'isFrontFacing': false,
            },
          ];
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowsChannel, null);
        messenger.setMockMethodCallHandler(sourcesChannel, null);
      });

      final fake = FakeChimeMeetingSession();
      final adapter = ChimeMediaSession(
        session: fake,
        windowsRuntime: testRuntime,
      );
      addTearDown(adapter.dispose);
      await adapter.join(ChimeJoinInfo.fromBackendResponse(backendJson()));

      expect(adapter.capabilities.canBlurBackground, isTrue);
      expect(adapter.capabilities.canReplaceBackgroundImage, isTrue);

      await adapter.selectMediaDevice(
        const MediaDevice(
          id: 'webview2-hashed-ext-cam',
          label: 'External 4K Webcam',
          kind: MediaDeviceKind.camera,
        ),
      );
      const source = ProcessedVideoSource(
        id: 'win_effects_1',
        kind: ProcessedVideoSourceKind.nativeFrameHub,
        platform: ProcessedVideoPlatform.windows,
        width: 1280,
        height: 720,
        frameRate: 24,
      );
      expect(adapter.supportsProcessedVideoSource(source), isTrue);
      await adapter.attachProcessedVideoSource(source);

      expect(
        webMessages.any((m) => m['operation'] == 'attachProcessedVideo'),
        isTrue,
      );
      expect(
        nativeCalls.map((c) => c.method),
        contains('subscribeProcessedVideo'),
      );
      expect(
        sourceCalls
            .where((c) => c.method == 'selectCamera')
            .map((c) => (c.arguments as Map)['deviceId']),
        [r'\\?\usb#vid_046d&pid_082d#ext'],
      );

      await messenger.handlePlatformMessage(
        windowsChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onProcessedFrame', {
            'sourceId': 'win_effects_1',
            'timestampNs': 987654321,
            'data': 'data:image/jpeg;base64,/9j/4AAQWinFrame',
          }),
        ),
        (_) {},
      );
      await pumpEventQueue();
      final pushedFrames = webMessages
          .where((m) => m['kind'] == 'processedFrame')
          .toList();
      expect(pushedFrames, hasLength(1));
      expect(pushedFrames.single['sourceId'], 'win_effects_1');
      expect(
        pushedFrames.single['data'],
        'data:image/jpeg;base64,/9j/4AAQWinFrame',
      );

      await adapter.switchCamera(MediaCameraPosition.front);
      expect(
        sourceCalls
            .where((c) => c.method == 'selectCamera')
            .map((c) => (c.arguments as Map)['deviceId'])
            .last,
        r'\\?\usb#vid_046d&pid_085e#front',
      );

      await adapter.leave();
      expect(
        webMessages.any((m) => m['operation'] == 'detachProcessedVideo'),
        isTrue,
      );
      expect(
        nativeCalls.map((c) => c.method),
        contains('unsubscribeProcessedVideo'),
      );
    },
  );
}

class _PendingChimeSession extends FakeChimeMeetingSession {
  final Completer<void> _pending = Completer<void>();

  @override
  Future<void> join(chime.JoinInfo info) async {
    await _pending.future;
    await super.join(info);
  }

  void finishJoin() => _pending.complete();
}

class _FailingControlSession extends FakeChimeMeetingSession {
  @override
  Future<void> setMuted(bool muted) async {
    throw const chime.RealtimeException(
      code: RealtimeErrorCode.permissionDenied,
      message: 'native secret',
    );
  }
}
