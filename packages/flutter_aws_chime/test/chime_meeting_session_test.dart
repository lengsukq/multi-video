import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_aws_chime/flutter_aws_chime.dart';
import 'package:flutter_aws_chime/src/chime_native_channel.dart';

const _channel = MethodChannel('com.oneplusdream.aws.chime.methodChannel');

JoinInfo _joinInfo() => JoinInfo.fromJson({
  'meeting': {
    'MeetingId': 'meeting-1',
    'ExternalMeetingId': 'external-meeting-1',
    'MediaRegion': 'us-east-1',
    'MediaPlacement': {
      'AudioHostUrl': 'https://audio.example.com',
      'AudioFallbackUrl': 'https://fallback.example.com',
      'SignalingUrl': 'wss://signal.example.com',
      'TurnControlUrl': 'https://turn.example.com',
    },
  },
  'attendee': {
    'ExternalUserId': 'user-1',
    'AttendeeId': 'attendee-1',
    'JoinToken': 'short-lived-token',
  },
});

Map<String, Object?> _success([Object? data]) => {
  'success': true,
  'code': null,
  'message': null,
  'data': data,
  'details': null,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  ChimeMeetingSession? activeSession;

  setUp(() {
    // ignore: deprecated_member_use
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'listAudioDevices' => _success([
              'Built-in Speaker',
              'Bluetooth Headset',
            ]),
            'initialAudioSelection' => _success('Built-in Speaker'),
            _ => _success('ok'),
          };
        });
  });

  tearDown(() async {
    if (activeSession != null) {
      await activeSession!.dispose();
      activeSession = null;
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    // ignore: deprecated_member_use
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'parses AWS meeting and attendee data and flattens the native payload',
    () {
      final joinInfo = _joinInfo();
      joinInfo.validate();
      expect(joinInfo.toJson(), {
        'MeetingId': 'meeting-1',
        'ExternalMeetingId': 'external-meeting-1',
        'MediaRegion': 'us-east-1',
        'AudioHostUrl': 'https://audio.example.com',
        'AudioFallbackUrl': 'https://fallback.example.com',
        'SignalingUrl': 'wss://signal.example.com',
        'TurnControlUrl': 'https://turn.example.com',
        'ExternalUserId': 'user-1',
        'AttendeeId': 'attendee-1',
        'JoinToken': 'short-lived-token',
      });
    },
  );

  test('Windows Chime transport is registered by default', () {
    // Enabling the transport never grants camera/microphone permissions;
    // availability is checked separately by ChimeSessionFactory.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(const bool.fromEnvironment(
      'AWS_CHIME_WINDOWS_WEBVIEW2_EXPERIMENTAL',
      defaultValue: true,
    ), isTrue);
    final owner = Object();
    ChimeNativeChannel.instance.reserve(owner, (_) {});
    ChimeNativeChannel.instance.release(owner);
  });

  test('macOS may join Chime as a listener when both media permissions are denied', () async {
    // ignore: deprecated_member_use
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final session = activeSession = ChimeMeetingSession();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (call.method == 'manageAudioPermissions' ||
          call.method == 'manageVideoPermissions') {
        return {
          'success': false,
          'code': 'permission_denied',
          'message': 'Device unavailable on macOS.',
          'data': null,
          'details': null,
        };
      }
      return _success();
    });

    await session.join(_joinInfo());
    expect(session.state, MeetingState.connecting);
    expect(calls.map((call) => call.method), contains('join'));
    expect(calls.map((call) => call.method), contains('manageAudioPermissions'));
    expect(calls.map((call) => call.method), contains('manageVideoPermissions'));
  });

  test(
    'rejects malformed join info as a typed exception before platform calls',
    () async {
      final session = activeSession = ChimeMeetingSession();
      await expectLater(
        session.join(
          const JoinInfo(
            meeting: MeetingInfo(
              meetingId: '',
              externalMeetingId: '',
              mediaRegion: '',
              mediaPlacement: MediaPlacement(
                audioHostUrl: '',
                audioFallbackUrl: '',
                signalingUrl: '',
                turnControlUrl: '',
              ),
            ),
            attendee: AttendeeInfo(
              externalUserId: '',
              attendeeId: '',
              joinToken: '',
            ),
          ),
        ),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'error code',
            RealtimeErrorCode.invalidArgument,
          ),
        ),
      );
      expect(calls, isEmpty);
    },
  );

  test(
    'joins with a stable method-channel payload and exposes state and events',
    () async {
      final session = activeSession = ChimeMeetingSession();
      final stateChanges = <MeetingState>[];
      final events = <ChimeEvent>[];
      final stateSubscription = session.states.listen(stateChanges.add);
      final eventSubscription = session.events.listen(events.add);

      await session.join(_joinInfo());

      expect(session.state, MeetingState.connecting);
      expect(session.snapshot.localAttendee?.attendeeId, 'attendee-1');
      expect(session.snapshot.audioDevices.map((device) => device.type), [
        ChimeAudioDeviceType.speaker,
        ChimeAudioDeviceType.bluetooth,
      ]);
      expect(session.snapshot.selectedAudioDevice?.label, 'Built-in Speaker');
      expect(calls.map((call) => call.method), [
        'manageAudioPermissions',
        'manageVideoPermissions',
        'join',
        'listAudioDevices',
        'initialAudioSelection',
      ]);
      expect(calls[2].arguments, _joinInfo().toJson());

      await ChimeNativeChannel.instance.debugDispatchNativeCall(
        const MethodCall('meetingEvent', {'type': 'audioSessionStarted'}),
      );
      await ChimeNativeChannel.instance.debugDispatchNativeCall(
        const MethodCall('join', {
          'attendeeId': 'attendee-2',
          'externalUserId': 'user-2',
        }),
      );
      await ChimeNativeChannel.instance.debugDispatchNativeCall(
        const MethodCall('videoTileAdd', {
          'tileId': 8,
          'attendeeId': 'attendee-2',
          'videoStreamContentWidth': 640,
          'videoStreamContentHeight': 360,
          'isLocalTile': false,
          'isContent': false,
        }),
      );
      await ChimeNativeChannel.instance.debugDispatchNativeCall(
        const MethodCall('videoTileAdd', {
          'tileId': 9,
          'attendeeId': 'share-1',
          'videoStreamContentWidth': 1280,
          'videoStreamContentHeight': 720,
          'isLocalTile': false,
          'isContent': true,
        }),
      );
      await ChimeNativeChannel.instance.debugDispatchNativeCall(
        const MethodCall('messageReceived', {
          'attendeeId': 'attendee-2',
          'externalUserId': 'user-2',
          'message': 'hello',
          'topic': 'chat',
          'timestampMs': 10,
        }),
      );

      expect(session.state, MeetingState.connected);
      expect(stateChanges, [
        MeetingState.joining,
        MeetingState.connecting,
        MeetingState.connected,
      ]);
      expect(events.single, isA<MeetingSessionEvent>());
      expect(session.snapshot.attendees, hasLength(2));
      expect(session.snapshot.attendees.last.videoTile?.tileId, 8);
      expect(session.snapshot.contentShareTile?.tileId, 9);
      expect(session.snapshot.messages.single.message, 'hello');

      await session.setMuted(false);
      await session.setVideoEnabled(true);
      await session.switchCamera(CameraPosition.back);
      await session.selectAudioDevice(session.snapshot.audioDevices.last);
      await session.sendMessage('outgoing');
      expect(calls.map((call) => call.method).toList().sublist(5), [
        'unmute',
        'startLocalVideo',
        'setCameraPosition',
        'updateAudioDevice',
        'sendMessage',
      ]);
      expect(calls[7].arguments, {'position': 'back'});
      expect(calls[8].arguments, 'Bluetooth Headset');
      expect(calls[9].arguments, {
        'topic': 'chat',
        'message': 'outgoing',
        'lifetimeMs': 300000,
      });

      await session.leave();
      expect(session.state, MeetingState.ended);
      await stateSubscription.cancel();
      await eventSubscription.cancel();
    },
  );

  test(
    'requests camera as well as microphone when one permission is denied',
    () async {
      final session = activeSession = ChimeMeetingSession();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            if (call.method == 'manageAudioPermissions') {
              return {
                'success': false,
                'code': 'permission_denied',
                'message': 'Microphone permission denied.',
                'data': null,
                'details': null,
              };
            }
            return _success();
          });

      await expectLater(
        session.join(_joinInfo()),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'error code',
            RealtimeErrorCode.permissionDenied,
          ),
        ),
      );
      expect(calls.map((call) => call.method), [
        'manageAudioPermissions',
        'manageVideoPermissions',
      ]);
      expect(session.state, MeetingState.failed);
    },
  );

  test('maps native response errors to stable typed exceptions', () async {
    final session = activeSession = ChimeMeetingSession();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          if (call.method == 'manageAudioPermissions') {
            return {
              'success': false,
              'code': 'permission_denied',
              'message': 'No microphone permission.',
              'data': null,
              'details': {'source': 'native'},
            };
          }
          return _success();
        });

    try {
      await session.join(_joinInfo());
      fail('Expected join to fail.');
    } on RealtimeException catch (error) {
      expect(error.code, RealtimeErrorCode.permissionDenied);
      expect(error.message, 'No microphone permission.');
      expect(error.details, {'source': 'native'});
    }
  });

  test(
    'enforces one active session and idempotent leave and dispose',
    () async {
      final first = activeSession = ChimeMeetingSession();
      final second = ChimeMeetingSession();
      await first.join(_joinInfo());

      await expectLater(
        first.join(_joinInfo()),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'error code',
            RealtimeErrorCode.invalidState,
          ),
        ),
      );

      await expectLater(
        second.join(_joinInfo()),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'error code',
            RealtimeErrorCode.invalidState,
          ),
        ),
      );
      await first.leave();
      await first.leave();
      await Future.wait([first.dispose(), first.dispose()]);
      expect(first.state, MeetingState.disposed);
      await second.dispose();
    },
  );

  test(
    'dispose prevents a late permission result from starting native join',
    () async {
      final session = activeSession = ChimeMeetingSession();
      final permissionResult = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            if (call.method == 'manageAudioPermissions') {
              return permissionResult.future;
            }
            return switch (call.method) {
              'listAudioDevices' => _success([]),
              _ => _success('ok'),
            };
          });

      final joining = session.join(_joinInfo());
      final disposing = session.dispose();
      final rejected = expectLater(joining, throwsA(isA<RealtimeException>()));
      permissionResult.complete(_success());
      await Future.wait([rejected, disposing]);

      expect(session.state, MeetingState.disposed);
      expect(calls.any((call) => call.method == 'join'), isFalse);
    },
  );

  test(
    'native stop failure still closes streams and reuses the same result',
    () async {
      final session = activeSession = ChimeMeetingSession();
      var stopAttempts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            if (call.method == 'stop' && stopAttempts++ == 0) {
              return {
                'success': false,
                'code': 'native_error',
                'message': 'Could not leave the meeting.',
                'data': null,
                'details': null,
              };
            }
            return switch (call.method) {
              'listAudioDevices' => _success([]),
              _ => _success('ok'),
            };
          });
      await session.join(_joinInfo());

      final first = session.dispose(), second = session.dispose();
      expect(identical(first, second), true);
      await expectLater(
        first,
        throwsA(
          isA<RealtimeException>()
              .having(
                (error) => error.code,
                'code',
                RealtimeErrorCode.cleanupFailed,
              )
              .having(
                (error) =>
                    (error.details as List<CleanupFailure>).map((f) => f.stage),
                'stage',
                contains('chime.native.stop'),
              ),
        ),
      );
      expect(session.state, MeetingState.disposed);
      expect(identical(session.dispose(), first), true);
      expect(stopAttempts, 1);
      expect(await session.states.isEmpty, true);
      activeSession = null;
    },
  );

  test(
    'rejects unsupported platforms and controls outside an active session',
    () async {
      final session = activeSession = ChimeMeetingSession();
      await expectLater(
        session.setMuted(true),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'error code',
            RealtimeErrorCode.invalidState,
          ),
        ),
      );
      // ignore: deprecated_member_use
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await expectLater(
        session.join(_joinInfo()),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'error code',
            RealtimeErrorCode.unsupportedPlatform,
          ),
        ),
      );
    },
  );

  test('maps typed session, attendee, camera, and video events', () {
    final event =
        ChimeEvent.fromJson({
              'type': 'videoTileSizeChanged',
              'videoTile': {
                'tileId': 7,
                'attendeeId': 'attendee-1',
                'videoStreamContentWidth': 640,
                'videoStreamContentHeight': 360,
                'isLocalTile': false,
                'isContent': false,
              },
            })!
            as VideoTileEvent;
    expect(event.videoTile.width, 640);
    expect(event.videoTile.aspectRatio, closeTo(16 / 9, 0.001));
    expect(
      ChimeEvent.fromJson({
        'type': 'attendeeSignalStrengthChanged',
        'signalStrength': 'SignalStrength.high',
      }),
      isA<AttendeeSignalStrengthEvent>(),
    );
    expect(
      ChimeEvent.fromJson({
        'type': 'cameraAvailabilityChanged',
        'available': true,
      }),
      isA<CameraAvailabilityEvent>(),
    );
    expect(ChimeEvent.fromJson({'type': 'futureEvent'}), isNull);
  });
}
