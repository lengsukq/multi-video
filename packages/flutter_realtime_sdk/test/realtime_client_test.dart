import 'package:flutter/foundation.dart';
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_realtime_chat_rtc/flutter_realtime_chat_rtc.dart';
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';
import 'package:flutter_realtime_video_effects/flutter_realtime_video_effects.dart';
import 'package:flutter_realtime_video_effects/flutter_realtime_video_effects_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_media_session.dart';
import 'support/default_driver_catalog.dart';
import 'support/fake_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const permissionChannel = MethodChannel(
    'flutter.baseflow.com/permissions/methods',
  );
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          permissionChannel,
          (call) async => call.method == 'checkPermissionStatus' ? 1 : null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel, null);
  });

  group('Processed video source lifecycle', () {
    test(
      'plain Pre-Join camera settings do not attach a Web processed source',
      () async {
        for (final role in [MediaRole.participant, MediaRole.host]) {
          final platform = _FakeEffectsPlatform();
          final session = _FakeProcessedMediaSession(role: role);
          final room = _effectsRoom(platform, session);
          await room.prepareVideoEffects(
            const MediaLocalPreviewSettings(cameraEnabled: true),
          );
          await room.setBackgroundEffect(const MediaBackgroundEffect.none());
          await room.setCameraEnabled(true);
          expect(platform.createCalls, 0, reason: '$role');
          expect(session.attachedSources, isEmpty, reason: '$role');
          expect(session.snapshot.localVideoEnabled, isTrue, reason: '$role');
          await room.setCameraEnabled(false);
          await room.setCameraEnabled(true);
          expect(session.snapshot.localVideoEnabled, isTrue, reason: '$role');
          expect(platform.createCalls, 0, reason: '$role');
          // Effects remain available on demand in meetings and live rooms.
          await room.setBackgroundEffect(const MediaBackgroundEffect.blur());
          expect(platform.createCalls, 1, reason: '$role');
          expect(session.attachedSources, hasLength(1), reason: '$role');
          expect(session.snapshot.localVideoEnabled, isTrue, reason: '$role');
          await room.dispose();
        }
      },
    );
    test(
      'protected initialization suspends publishing and failure keeps it off',
      () async {
        final gate = Completer<void>();
        final platform = _FakeEffectsPlatform()..createGate = gate;
        final session = _FakeProcessedMediaSession();
        final room = _effectsRoom(platform, session);
        await session.setVideoEnabled(true);
        final operation = room.setBackgroundEffect(
          const MediaBackgroundEffect.blur(),
        );
        final failure = expectLater(
          operation,
          throwsA(
            isA<RealtimeException>().having(
              (e) => e.cause,
              'cause',
              isA<StateError>(),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(session.snapshot.localVideoEnabled, isFalse);
        gate.completeError(StateError('effects runtime unavailable'));
        await failure;
        expect(session.snapshot.localVideoEnabled, isFalse);
        expect(session.attachedSources, isEmpty);
        await room.dispose();
      },
    );

    test(
      'composable SDK camera button shares the headless effects pipeline',
      () async {
        final platform = _FakeEffectsPlatform();
        final session = _FakeProcessedMediaSession();
        await session.join(
          MediaJoinInfo(
            providerId: session.providerId,
            roomCode: 'effects',
            participantId: 'local',
            role: session.role,
          ),
        );
        final room = _effectsRoom(platform, session);
        final ui = RealtimeRoomUiController(room);
        await ui.setBackgroundEffect(const MediaBackgroundEffect.blur());
        await ui.toggleCamera();
        expect(platform.enabled.last, isTrue);
        expect(session.snapshot.localVideoEnabled, isTrue);
        ui.dispose();
        await room.dispose();
      },
    );

    test(
      'successful protection restores only a previously enabled camera',
      () async {
        final platform = _FakeEffectsPlatform();
        final session = _FakeProcessedMediaSession();
        final room = _effectsRoom(platform, session);
        await session.setVideoEnabled(true);
        await room.setBackgroundEffect(const MediaBackgroundEffect.blur());
        expect(session.snapshot.localVideoEnabled, isTrue);
        expect(session.actions, ['video:true', 'video:false', 'video:true']);
        await room.dispose();
      },
    );

    test('changing effects preserves a disabled camera', () async {
      final platform = _FakeEffectsPlatform();
      final room = _effectsRoom(platform, _FakeProcessedMediaSession());
      await room.setBackgroundEffect(const MediaBackgroundEffect.blur());
      expect(platform.enabled, [false, false]);
      expect(room.backgroundEffect, const MediaBackgroundEffect.blur());
      await room.dispose();
    });

    test(
      'headless camera-off background selection then camera-on enables capture',
      () async {
        final platform = _FakeEffectsPlatform();
        final session = _FakeProcessedMediaSession();
        final room = _effectsRoom(platform, session);
        expect(session.snapshot.localVideoEnabled, isFalse);

        await room.setBackgroundEffect(const MediaBackgroundEffect.blur());
        expect(platform.enabled.last, isFalse);
        expect(session.snapshot.localVideoEnabled, isFalse);

        await room.setCameraEnabled(true);
        expect(session.snapshot.localVideoEnabled, isTrue);
        expect(platform.enabled.last, isTrue);
        expect(session.attachedSources, hasLength(1));
        expect(room.backgroundEffect, const MediaBackgroundEffect.blur());

        await room.setCameraEnabled(false);
        expect(session.snapshot.localVideoEnabled, isFalse);
        expect(platform.enabled.last, isFalse);

        await room.setBackgroundEffect(const MediaBackgroundEffect.none());
        await room.setCameraEnabled(true);
        expect(session.snapshot.localVideoEnabled, isTrue);
        expect(platform.enabled.last, isTrue);
        expect(room.backgroundEffect, const MediaBackgroundEffect.none());
        await room.dispose();
      },
    );

    test(
      'camera-on waits for pending background creation before publication',
      () async {
        final gate = Completer<void>();
        final platform = _FakeEffectsPlatform()..createGate = gate;
        final session = _FakeProcessedMediaSession();
        final room = _effectsRoom(platform, session);

        final apply = room.setBackgroundEffect(
          const MediaBackgroundEffect.blur(),
        );
        final camera = room.setCameraEnabled(true);
        await Future<void>.delayed(Duration.zero);
        expect(session.snapshot.localVideoEnabled, isFalse);
        expect(session.attachedSources, isEmpty);

        gate.complete();
        await Future.wait([apply, camera]);
        expect(session.snapshot.localVideoEnabled, isTrue);
        expect(platform.enabled.last, isTrue);
        expect(session.attachedSources, hasLength(1));
        await room.dispose();
      },
    );

    test(
      'queued camera-off wins over a concurrent background switch',
      () async {
        final gate = Completer<void>();
        final platform = _FakeEffectsPlatform()..createGate = gate;
        final session = _FakeProcessedMediaSession();
        final room = _effectsRoom(platform, session);
        final apply = room.setBackgroundEffect(
          const MediaBackgroundEffect.blur(),
        );
        final start = room.setCameraEnabled(true);
        final stop = room.setCameraEnabled(false);
        await Future<void>.delayed(Duration.zero);
        gate.complete();
        await Future.wait([apply, start, stop]);
        expect(session.snapshot.localVideoEnabled, isFalse);
        expect(platform.enabled.last, isFalse);
        await room.dispose();
      },
    );

    test('unsupported effects preserve baseline camera when off', () async {
      final platform = _FakeEffectsPlatform();
      final room = _effectsRoom(
        platform,
        _FakeProcessedMediaSession(supportsBackground: false),
      );
      await room.prepareVideoEffects(const MediaLocalPreviewSettings());
      expect(platform.createCalls, 0);
      await expectLater(
        room.setBackgroundEffect(const MediaBackgroundEffect.blur()),
        throwsA(
          isA<RealtimeException>().having(
            (e) => e.code,
            'code',
            RealtimeErrorCode.unsupportedFeature,
          ),
        ),
      );
      await room.dispose();
    });

    test('an unavailable platform never creates an enabled effect', () async {
      final platform = _FakeEffectsPlatform()..supported = false;
      final room = _effectsRoom(platform, _FakeProcessedMediaSession());
      await room.prepareVideoEffects(const MediaLocalPreviewSettings());
      await expectLater(
        room.setBackgroundEffect(const MediaBackgroundEffect.blur()),
        throwsA(isA<RealtimeException>()),
      );
      expect(platform.createCalls, 0);
      await room.dispose();
    });

    test('an incompatible source is released and off keeps baseline', () async {
      final platform = _FakeEffectsPlatform();
      final session = _FakeProcessedMediaSession()..supportsSource = false;
      final room = _effectsRoom(platform, session);
      await room.prepareVideoEffects(const MediaLocalPreviewSettings());
      expect(platform.createCalls, 0);
      expect(session.attachedSources, isEmpty);
      await expectLater(
        room.setBackgroundEffect(const MediaBackgroundEffect.blur()),
        throwsA(isA<RealtimeException>()),
      );
      expect(platform.disposedSources, ['effects-source-1']);
      await room.setCameraEnabled(true);
      expect(session.snapshot.localVideoEnabled, isTrue);
      await room.dispose();
    });

    test(
      'an unavailable provider binding keeps the off camera path usable',
      () async {
        final platform = _FakeEffectsPlatform();
        final session = _FakeProcessedMediaSession()
          ..attachError = MissingPluginException('No provider input');
        final room = _effectsRoom(platform, session);
        await room.prepareVideoEffects(const MediaLocalPreviewSettings());
        expect(platform.createCalls, 0);
        await expectLater(
          room.setBackgroundEffect(const MediaBackgroundEffect.blur()),
          throwsA(
            isA<RealtimeException>().having(
              (e) => e.code,
              'code',
              RealtimeErrorCode.unsupportedFeature,
            ),
          ),
        );
        expect(platform.disposedSources, ['effects-source-1']);
        await room.dispose();
      },
    );

    test('attachment failure releases the source and permits retry', () async {
      final platform = _FakeEffectsPlatform();
      final session = _FakeProcessedMediaSession()
        ..attachError = StateError('attach');
      final room = _effectsRoom(platform, session);
      await expectLater(
        room.setBackgroundEffect(const MediaBackgroundEffect.blur()),
        throwsA(
          isA<RealtimeException>().having(
            (e) => e.cause,
            'cause',
            isA<StateError>(),
          ),
        ),
      );
      expect(platform.disposedSources, ['effects-source-1']);
      session.attachError = null;
      await room.setBackgroundEffect(const MediaBackgroundEffect.blur());
      expect(platform.createCalls, 2);
      await room.dispose();
      expect(platform.disposedSources, hasLength(2));
    });

    test('concurrent updates reuse one source in request order', () async {
      final platform = _FakeEffectsPlatform()..createGate = Completer<void>();
      final room = _effectsRoom(platform, _FakeProcessedMediaSession());
      final initial = room.prepareVideoEffects(
        const MediaLocalPreviewSettings(),
      );
      final update = room.setBackgroundEffect(
        const MediaBackgroundEffect.blur(),
      );
      await Future<void>.delayed(Duration.zero);
      platform.createGate!.complete();
      await Future.wait([initial, update]);
      expect(platform.createCalls, 1);
      expect(platform.lastConfig?.effect, const MediaBackgroundEffect.blur());
      expect(platform.effects, isEmpty);
      await room.dispose();
    });

    test(
      'dispose during creation releases the source before attaching',
      () async {
        final platform = _FakeEffectsPlatform()..createGate = Completer<void>();
        final session = _FakeProcessedMediaSession();
        final room = _effectsRoom(platform, session);
        final initial = room.prepareVideoEffects(
          const MediaLocalPreviewSettings(
            backgroundEffect: MediaBackgroundEffect.blur(),
          ),
        );
        final expectedFailure = expectLater(
          initial,
          throwsA(isA<RealtimeException>()),
        );
        await Future<void>.delayed(Duration.zero);
        final disposal = room.dispose();
        platform.createGate!.complete();
        await expectedFailure;
        await disposal;
        expect(session.attachedSources, isEmpty);
        expect(platform.disposedSources, ['effects-source-1']);
      },
    );

    test(
      'leaving releases the camera without waiting for room disposal',
      () async {
        final platform = _FakeEffectsPlatform();
        final session = _FakeProcessedMediaSession();
        await session.join(
          MediaJoinInfo(
            providerId: session.providerId,
            roomCode: 'effects',
            participantId: 'local',
            role: session.role,
          ),
        );
        final room = _effectsRoom(platform, session);
        await room.prepareVideoEffects(
          const MediaLocalPreviewSettings(
            backgroundEffect: MediaBackgroundEffect.blur(),
          ),
        );
        await session.leave();
        await Future<void>.delayed(Duration.zero);
        expect(session.detachCalls, 1);
        expect(platform.disposedSources, ['effects-source-1']);
        await room.dispose();
        expect(session.detachCalls, 1);
      },
    );

    test(
      'room attaches one SDK source to sink and disposes it safely',
      () async {
        final platform = _FakeEffectsPlatform();
        final bridge = VideoEffectsBridge(platform: platform);
        final session = _FakeProcessedMediaSession();
        final media = MediaRoomSession.direct(
          roomCode: 'room-effects',
          participantId: 'local-user',
          session: session,
        );
        final room = RealtimeRoom(
          media: media,
          renderer: const _FakeRenderer(),
          disposeClients: () {},
          effectsCapabilities: const MediaBackgroundCapabilities(
            canBlur: true,
            canReplaceImage: true,
          ),
          videoEffects: DefaultRealtimeVideoEffects(bridge: bridge),
        );

        await room.prepareVideoEffects(
          const MediaLocalPreviewSettings(
            cameraEnabled: true,
            backgroundEffect: MediaBackgroundEffect.blur(),
          ),
        );

        expect(platform.createCalls, 1);
        expect(platform.lastConfig?.effect, const MediaBackgroundEffect.blur());
        expect(platform.lastConfig?.frameRate, 30);
        expect(session.attachedSources, hasLength(1));
        expect(session.attachedSources.single.id, 'effects-source-1');

        await room.setBackgroundEffect(const MediaBackgroundEffect.none());
        expect(platform.createCalls, 1);
        expect(platform.effects, contains(const MediaBackgroundEffect.none()));

        await room.dispose();
        expect(session.detachCalls, 1);
        expect(platform.disposedSources, ['effects-source-1']);
      },
    );

    test(
      'asynchronous processed-source failures reach room event listeners',
      () async {
        final platform = _FakeEffectsPlatform();
        final session = _FakeProcessedMediaSession();
        final room = _effectsRoom(platform, session);
        await room.prepareVideoEffects(
          const MediaLocalPreviewSettings(
            cameraEnabled: true,
            backgroundEffect: MediaBackgroundEffect.blur(),
          ),
        );
        await room.setCameraEnabled(true);
        final eventFuture = room.events.firstWhere(
          (event) => event is RealtimeBackendFailure,
        );

        platform.emitFailure(
          const VideoEffectsFailure(
            sourceId: 'effects-source-1',
            message: 'frame processing failed',
          ),
        );

        final event = await eventFuture as RealtimeBackendFailure;
        expect(event.error.code, RealtimeErrorCode.providerError);
        expect(event.error.providerId, 'fake-effects-provider');
        expect(event.error.message, 'videoEffects.processFrame failed.');
        expect(event.error.cause, 'frame processing failed');
        expect(room.diagnostics.last.operation, 'processFrame');
        await Future<void>.delayed(Duration.zero);
        expect(session.snapshot.localVideoEnabled, isFalse);
        await room.dispose();
        await platform.close();
      },
    );
  });

  group('SDK processed-video capability probes', () {
    late FlutterRealtimeProcessedVideoPlatform originalEffectsPlatform;
    late _FakeEffectsPlatform effectsPlatform;

    setUp(() {
      originalEffectsPlatform = FlutterRealtimeProcessedVideoPlatform.instance;
      effectsPlatform = _FakeEffectsPlatform();
      FlutterRealtimeProcessedVideoPlatform.instance = effectsPlatform;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    });

    tearDown(() {
      FlutterRealtimeProcessedVideoPlatform.instance = originalEffectsPlatform;
      debugDefaultTargetPlatformOverride = null;
    });

    test('Mac Pre-Join gates effects on the provider input probe', () async {
      const channel = MethodChannel(
        'com.oneplusdream.flutter_realtime_media_artc/methods',
      );
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return false;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final sdk = _sdkWithProbeFactory(
        FakeMediaSessionFactory(providerId: 'artc'),
      );

      final result = await sdk.preJoin(providerId: 'artc');

      expect(calls, ['probeProcessedVideoInput']);
      expect(result.backgroundCapabilities.canBlur, isFalse);
      expect(result.backgroundCapabilities.canReplaceImage, isFalse);
    });

    test(
      'Mac Pre-Join advertises effects after a positive provider probe',
      () async {
        const channel = MethodChannel(
          'com.oneplusdream.flutter_realtime_media_artc/methods',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async => true);
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final sdk = _sdkWithProbeFactory(
          FakeMediaSessionFactory(providerId: 'artc'),
        );

        final result = await sdk.preJoin(providerId: 'artc');

        expect(result.backgroundCapabilities.canBlur, isTrue);
        expect(result.backgroundCapabilities.canReplaceImage, isTrue);
      },
    );

    test('AWS providers probe their own native video input channels', () async {
      const channels = {
        'chime': 'com.oneplusdream.aws.chime.methodChannel',
        'ivs': 'com.oneplusdream.flutter_realtime_media_ivs/methods',
      };
      for (final entry in channels.entries) {
        final channel = MethodChannel(entry.value);
        var probeCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'probeProcessedVideoInput') probeCalls++;
              return false;
            });
        try {
          final sdk = _sdkWithProbeFactory(
            FakeMediaSessionFactory(providerId: entry.key),
          );
          await sdk.preJoin(providerId: entry.key);
          expect(probeCalls, 1, reason: entry.key);
        } finally {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        }
      }
    });

    test(
      'local preview falls back when Mac provider input is unavailable',
      () async {
        const channel = MethodChannel(
          'com.oneplusdream.flutter_realtime_media_artc/methods',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async => false);
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final factory = _FakePreviewMediaSessionFactory(providerId: 'artc');
        final sdk = _sdkWithProbeFactory(factory);

        final preview = await sdk.createLocalPreview(
          providerId: 'artc',
          role: MediaRole.participant,
        );

        expect(identical(preview, factory.preview), isTrue);
        expect(factory.localPreviewCalls, 1);
        expect(effectsPlatform.createCalls, 0);
      },
    );
  }, skip: kIsWeb);

  group('Host-owned local device preview fallback', () {
    test('unsupported RTC adapter uses explicit hardware preview fallback',
        () async {
      final fallback = _FakePreviewMediaSessionFactory(providerId: 'livekit');
      String? requestedProvider;
      final sdk = RealtimeSdk(
        plugins: [
          RealtimeProviderPlugin(
            id: 'trtc',
            metadata: const RealtimeProviderMetadata(displayName: 'TRTC'),
            mediaFactory: FakeMediaSessionFactory(providerId: 'trtc'),
            renderer: const _FakeRenderer(),
          ),
        ],
        services: RealtimeRoomServices(
          localPreviewFallbackFactory: ({
            required String providerId,
            required MediaRole role,
          }) {
            requestedProvider = providerId;
            return fallback.createLocalPreview(role: role);
          },
        ),
      );
      final preview = await sdk.createLocalPreview(
        providerId: 'trtc',
        role: MediaRole.participant,
      );
      expect(requestedProvider, 'trtc');
      expect(preview, same(fallback.preview));
      expect(fallback.localPreviewCalls, 1);
    });

    test('native provider preview takes precedence over host fallback',
        () async {
      final native = _FakePreviewMediaSessionFactory(providerId: 'livekit');
      var fallbackCalls = 0;
      final sdk = RealtimeSdk(
        plugins: [
          RealtimeProviderPlugin(
            id: 'livekit',
            metadata: const RealtimeProviderMetadata(displayName: 'LiveKit'),
            mediaFactory: native,
            renderer: const _FakeRenderer(),
          ),
        ],
        services: RealtimeRoomServices(
          localPreviewFallbackFactory: ({
            required String providerId,
            required MediaRole role,
          }) {
            fallbackCalls++;
            return native.createLocalPreview(role: role);
          },
        ),
      );
      final preview = await sdk.createLocalPreview(
        providerId: 'livekit',
        role: MediaRole.participant,
      );
      expect(preview, same(native.preview));
      expect(native.localPreviewCalls, 1);
      expect(fallbackCalls, 0);
    });
  });

  group('RealtimeMediaAdapters', () {
    test('keeps session factory and renderer under one provider id', () {
      final factory = FakeMediaSessionFactory();
      const renderer = _FakeRenderer();
      final adapters = RealtimeMediaAdapters([
        RealtimeMediaAdapter(sessionFactory: factory, renderer: renderer),
      ]);

      expect(adapters.require('FAKE').renderer, same(renderer));
      expect(adapters.registry.require('fake'), same(factory));
      expect(
        () => adapters.require('missing'),
        throwsA(isA<RealtimeException>()),
      );
    });

    test('rejects duplicate provider registrations', () {
      expect(
        () => RealtimeMediaAdapters([
          RealtimeMediaAdapter(
            sessionFactory: FakeMediaSessionFactory(),
            renderer: const _FakeRenderer(),
          ),
          RealtimeMediaAdapter(
            sessionFactory: FakeMediaSessionFactory(),
            renderer: const _FakeRenderer(),
          ),
        ]),
        throwsArgumentError,
      );
    });

    test(
      'public vendor Pre-Join resolves the matching internal engine',
      () async {
        final meetingFactory = FakeMediaSessionFactory(
          providerId: 'meeting-sdk',
        );
        final liveFactory = FakeMediaSessionFactory(providerId: 'live-sdk');
        final sdk = RealtimeSdk.standard(
          platformResolver: () => RealtimeRuntimePlatform.macos,
          drivers: [
            RealtimeProviderDriver(
              platforms: const {RealtimeRuntimePlatform.macos},
              publicProviderId: 'vendor',
              mediaRoomModes: const {MediaRoomMode.meeting},
              plugin: RealtimeProviderPlugin(
                id: 'meeting-sdk',
                metadata: const RealtimeProviderMetadata(displayName: 'Vendor'),
                mediaFactory: meetingFactory,
                renderer: const _FakeRenderer(),
              ),
            ),
            RealtimeProviderDriver(
              platforms: const {RealtimeRuntimePlatform.macos},
              publicProviderId: 'vendor',
              mediaRoomModes: const {MediaRoomMode.broadcast},
              plugin: RealtimeProviderPlugin(
                id: 'live-sdk',
                metadata: const RealtimeProviderMetadata(displayName: 'Vendor'),
                mediaFactory: liveFactory,
                renderer: const _FakeRenderer(),
              ),
            ),
          ],
        );

        final meeting = await sdk.preJoin(
          providerId: 'vendor',
          role: MediaRole.participant,
        );
        final live = await sdk.preJoin(
          providerId: 'vendor',
          role: MediaRole.host,
        );

        expect(meeting.providerId, 'vendor');
        expect(
          meeting.check(MediaPreJoinCheckType.provider)?.status,
          MediaPreJoinStatus.passed,
        );
        expect(live.providerId, 'vendor');
        expect(
          live.check(MediaPreJoinCheckType.provider)?.status,
          MediaPreJoinStatus.passed,
        );
      },
    );

    test(
      'backend-selected public provider resolves by room mode before Pre-Join',
      () async {
        final meetingFactory = FakeMediaSessionFactory(
          providerId: 'meeting-sdk',
        );
        final liveFactory = FakeMediaSessionFactory(providerId: 'live-sdk');
        final adapters = RealtimeMediaAdapters([
          RealtimeMediaAdapter(
            sessionFactory: meetingFactory,
            renderer: const _FakeRenderer(),
          ),
          RealtimeMediaAdapter(
            sessionFactory: liveFactory,
            renderer: const _FakeRenderer(),
          ),
        ]);
        final advanced = RealtimeClient(
          backendUrl: 'https://example.test',
          mediaAdapters: adapters,
          mediaClientFactory: () => MediaClient(
            backendUrl: 'https://example.test',
            registry: adapters.registry,
            transport: FakeTransport(
              (_) => jsonResponse({
                'contractVersion': 1,
                'ok': true,
                'activeProvider': 'vendor',
              }),
            ),
            heartbeatInterval: Duration.zero,
          ),
        );
        final sdk = RealtimeSdk.standard(
          backendUrl: 'https://example.test',
          platformResolver: () => RealtimeRuntimePlatform.macos,
          clientFactory: () => advanced,
          drivers: [
            RealtimeProviderDriver(
              platforms: const {RealtimeRuntimePlatform.macos},
              publicProviderId: 'vendor',
              mediaRoomModes: const {MediaRoomMode.meeting},
              plugin: RealtimeProviderPlugin(
                id: 'meeting-sdk',
                metadata: const RealtimeProviderMetadata(displayName: 'Vendor'),
                mediaFactory: meetingFactory,
                renderer: const _FakeRenderer(),
              ),
            ),
            RealtimeProviderDriver(
              platforms: const {RealtimeRuntimePlatform.macos},
              publicProviderId: 'vendor',
              mediaRoomModes: const {MediaRoomMode.broadcast},
              plugin: RealtimeProviderPlugin(
                id: 'live-sdk',
                metadata: const RealtimeProviderMetadata(displayName: 'Vendor'),
                mediaFactory: liveFactory,
                renderer: const _FakeRenderer(),
              ),
            ),
          ],
        );

        final meeting = await sdk.preJoin(role: MediaRole.participant);
        final live = await sdk.preJoin(role: MediaRole.host);

        expect(meeting.providerId, 'vendor');
        expect(
          meeting.check(MediaPreJoinCheckType.provider)?.status,
          MediaPreJoinStatus.passed,
        );
        expect(live.providerId, 'vendor');
        expect(
          live.check(MediaPreJoinCheckType.provider)?.status,
          MediaPreJoinStatus.passed,
        );
      },
    );
  });

  group('RealtimeDriverRegistry', () {
    test('built-in media and chat catalogs cover the five public targets', () {
      const expected =
          <
            RealtimeRuntimePlatform,
            ({Set<String> media, Set<String> chat, Set<String> public})
          >{
            RealtimeRuntimePlatform.android: (
              media: {'livekit', 'agora', 'trtc', 'artc', 'chime', 'ivs'},
              chat: {'agora-chat', 'ivs-chat', 'tencent-chat'},
              public: {
                'livekit',
                'agora',
                'trtc',
                'artc',
                'aws',
                'agora-chat',
                'ivs-chat',
                'tencent-chat',
              },
            ),
            RealtimeRuntimePlatform.ios: (
              media: {'livekit', 'agora', 'trtc', 'artc', 'chime', 'ivs'},
              chat: {'agora-chat', 'ivs-chat', 'tencent-chat'},
              public: {
                'livekit',
                'agora',
                'trtc',
                'artc',
                'aws',
                'agora-chat',
                'ivs-chat',
                'tencent-chat',
              },
            ),
            RealtimeRuntimePlatform.macos: (
              media: {'livekit', 'agora', 'trtc', 'artc', 'chime', 'ivs'},
              chat: {'agora-chat', 'ivs-chat', 'tencent-chat'},
              public: {
                'livekit',
                'agora',
                'trtc',
                'artc',
                'aws',
                'agora-chat',
                'ivs-chat',
                'tencent-chat',
              },
            ),
            RealtimeRuntimePlatform.windows: (
              media: {'livekit', 'agora', 'trtc', 'artc', 'chime', 'ivs'},
              chat: {'agora-chat', 'ivs-chat', 'tencent-chat'},
              public: {
                'livekit',
                'agora',
                'trtc',
                'artc',
                'aws',
                'agora-chat',
                'ivs-chat',
                'tencent-chat',
              },
            ),
            RealtimeRuntimePlatform.web: (
              media: {'livekit', 'agora', 'trtc', 'artc', 'chime', 'ivs'},
              chat: {'agora-chat', 'ivs-chat', 'tencent-chat'},
              public: {
                'livekit',
                'agora',
                'trtc',
                'artc',
                'aws',
                'agora-chat',
                'ivs-chat',
                'tencent-chat',
              },
            ),
          };

      for (final entry in expected.entries) {
        final registry = RealtimeDriverRegistry(
          createDefaultRealtimeDrivers(),
          platformResolver: () => entry.key,
        );
        if (!registry.drivers.any((driver) => driver.supports(entry.key))) {
          // Native and Web catalogs are selected at compile time; the CI Web
          // test runs this same assertion against the Web implementation.
          continue;
        }
        final activeDrivers = registry.drivers
            .where((driver) => driver.supports(entry.key))
            .toList(growable: false);

        expect(
          activeDrivers
              .where((driver) => driver.plugin.mediaFactory != null)
              .map((driver) => driver.providerId)
              .toSet(),
          entry.value.media,
          reason: '${entry.key.name} media directory',
        );
        expect(
          activeDrivers
              .where((driver) => driver.plugin.chatFactory != null)
              .map((driver) => driver.providerId)
              .toSet(),
          entry.value.chat,
          reason: '${entry.key.name} chat directory',
        );
        expect(
          registry.supportedProviderIds().toSet(),
          entry.value.public,
          reason: '${entry.key.name} support listing',
        );
      }
    });

    test('selects the provider driver for the current runtime platform', () {
      final androidFactory = FakeMediaSessionFactory(providerId: 'fake');
      final webFactory = FakeMediaSessionFactory(providerId: 'fake');
      final registry = RealtimeDriverRegistry([
        RealtimeProviderDriver(
          platforms: const {RealtimeRuntimePlatform.android},
          plugin: RealtimeProviderPlugin(
            id: 'fake',
            metadata: const RealtimeProviderMetadata(displayName: 'Fake'),
            mediaFactory: androidFactory,
            renderer: const _FakeRenderer(),
          ),
        ),
        RealtimeProviderDriver(
          platforms: const {RealtimeRuntimePlatform.web},
          plugin: RealtimeProviderPlugin(
            id: 'fake',
            metadata: const RealtimeProviderMetadata(displayName: 'Fake'),
            mediaFactory: webFactory,
            renderer: const _FakeRenderer(),
          ),
        ),
      ], platformResolver: () => RealtimeRuntimePlatform.web);

      final plugins = RealtimePluginRegistry(registry.resolvePlugins());

      expect(plugins.media.registry.require('fake'), same(webFactory));
      expect(registry.supportedProviderIds(), contains('fake'));
    });

    test(
      'routes one public vendor to different media engines by room mode',
      () {
        final meetingFactory = FakeMediaSessionFactory(
          providerId: 'meeting-sdk',
        );
        final liveFactory = FakeMediaSessionFactory(providerId: 'live-sdk');
        final registry = RealtimeDriverRegistry([
          RealtimeProviderDriver(
            platforms: const {RealtimeRuntimePlatform.android},
            publicProviderId: 'vendor',
            mediaRoomModes: const {MediaRoomMode.meeting},
            plugin: RealtimeProviderPlugin(
              id: 'meeting-sdk',
              metadata: const RealtimeProviderMetadata(displayName: 'Vendor'),
              mediaFactory: meetingFactory,
              renderer: const _FakeRenderer(),
            ),
          ),
          RealtimeProviderDriver(
            platforms: const {RealtimeRuntimePlatform.android},
            publicProviderId: 'vendor',
            mediaRoomModes: const {MediaRoomMode.broadcast},
            plugin: RealtimeProviderPlugin(
              id: 'live-sdk',
              metadata: const RealtimeProviderMetadata(displayName: 'Vendor'),
              mediaFactory: liveFactory,
              renderer: const _FakeRenderer(),
            ),
          ),
        ], platformResolver: () => RealtimeRuntimePlatform.android);

        expect(registry.supportedProviderIds().toSet(), {'vendor'});
        expect(
          registry.resolveMediaEngine(
            providerId: 'vendor',
            roomMode: MediaRoomMode.meeting,
          ),
          'meeting-sdk',
        );
        expect(
          registry.resolveMediaEngine(
            providerId: 'vendor',
            roomMode: MediaRoomMode.broadcast,
          ),
          'live-sdk',
        );
        expect(registry.publicProviderForEngine('meeting-sdk'), 'vendor');
        expect(registry.publicProviderForEngine('live-sdk'), 'vendor');
      },
    );

    test('known provider without a platform driver fails as unsupported', () {
      final registry = RealtimeDriverRegistry([
        RealtimeProviderDriver(
          platforms: const {RealtimeRuntimePlatform.android},
          plugin: RealtimeProviderPlugin(
            id: 'fake',
            metadata: const RealtimeProviderMetadata(displayName: 'Fake'),
            mediaFactory: FakeMediaSessionFactory(providerId: 'fake'),
            renderer: const _FakeRenderer(),
          ),
        ),
      ], platformResolver: () => RealtimeRuntimePlatform.web);
      final plugins = RealtimePluginRegistry(registry.resolvePlugins());

      expect(registry.knowsProvider('fake'), isTrue);
      expect(registry.supportsProvider('fake'), isFalse);
      expect(
        () => plugins.media.registry.require('fake').parseJoinInfo(const {}),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.unsupportedPlatform,
          ),
        ),
      );
    });

    test('keeps media and product chat providers independently selectable', () {
      final registry = RealtimeDriverRegistry([
        RealtimeProviderDriver(
          platforms: const {RealtimeRuntimePlatform.web},
          plugin: RealtimeProviderPlugin(
            id: 'media-only',
            metadata: const RealtimeProviderMetadata(displayName: 'Media'),
            mediaFactory: FakeMediaSessionFactory(providerId: 'media-only'),
            renderer: const _FakeRenderer(),
          ),
        ),
        RealtimeProviderDriver(
          platforms: {RealtimeRuntimePlatform.web},
          plugin: RealtimeProviderPlugin(
            id: 'chat-only',
            metadata: RealtimeProviderMetadata(displayName: 'Chat'),
            chatFactory: _FakeChatFactory('chat-only'),
          ),
        ),
      ], platformResolver: () => RealtimeRuntimePlatform.web);
      final plugins = RealtimePluginRegistry(registry.resolvePlugins());

      expect(plugins.media.registry.lookup('media-only'), isNotNull);
      expect(plugins.chat.lookup('chat-only'), isNotNull);
      expect(plugins.chat.lookup('media-only'), isNull);
      expect(plugins.media.registry.lookup('chat-only'), isNull);
    });

    test('application plugin overrides a built-in platform driver', () {
      final builtIn = FakeMediaSessionFactory(providerId: 'fake');
      final custom = FakeMediaSessionFactory(providerId: 'fake');
      final registry = RealtimeDriverRegistry([
        RealtimeProviderDriver(
          platforms: const {RealtimeRuntimePlatform.android},
          plugin: RealtimeProviderPlugin(
            id: 'fake',
            metadata: const RealtimeProviderMetadata(displayName: 'Built-in'),
            mediaFactory: builtIn,
            renderer: const _FakeRenderer(),
          ),
        ),
      ], platformResolver: () => RealtimeRuntimePlatform.web);

      final plugins = RealtimePluginRegistry(
        registry.resolvePlugins(
          additionalPlugins: [
            RealtimeProviderPlugin(
              id: 'fake',
              metadata: const RealtimeProviderMetadata(displayName: 'Custom'),
              mediaFactory: custom,
              renderer: const _FakeRenderer(),
            ),
          ],
        ),
      );

      expect(plugins.media.registry.require('fake'), same(custom));
      expect(plugins.require('fake').metadata.displayName, 'Custom');
      expect(registry.supportsProvider('fake'), isTrue);
      expect(
        registry.supportsProvider('fake', RealtimeRuntimePlatform.web),
        isTrue,
      );
      expect(
        registry.supportsProvider('fake', RealtimeRuntimePlatform.ios),
        isFalse,
      );
      expect(
        registry.supportedProviderIds(RealtimeRuntimePlatform.web),
        contains('fake'),
      );
      expect(
        registry.supportedProviderIds(RealtimeRuntimePlatform.ios),
        isNot(contains('fake')),
      );
    });
  });

  group('RealtimeProviderPlugin', () {
    test('builds media registry from a self-describing plugin', () {
      final factory = FakeMediaSessionFactory();
      final registry = RealtimePluginRegistry([
        RealtimeProviderPlugin(
          id: 'fake',
          metadata: const RealtimeProviderMetadata(displayName: 'Fake'),
          mediaFactory: factory,
          renderer: const _FakeRenderer(),
        ),
      ]);

      expect(registry.require('FAKE').metadata.displayName, 'Fake');
      expect(registry.media.registry.require('fake'), same(factory));
    });

    test('rejects duplicate plugin ids', () {
      expect(
        () => RealtimePluginRegistry([
          RealtimeProviderPlugin(
            id: 'fake',
            metadata: const RealtimeProviderMetadata(displayName: 'Fake 1'),
            mediaFactory: FakeMediaSessionFactory(),
            renderer: const _FakeRenderer(),
          ),
          RealtimeProviderPlugin(
            id: 'FAKE',
            metadata: const RealtimeProviderMetadata(displayName: 'Fake 2'),
            mediaFactory: FakeMediaSessionFactory(),
            renderer: const _FakeRenderer(),
          ),
        ]),
        throwsArgumentError,
      );
    });
  });

  group('Realtime error mapping', () {
    test('preserves provider diagnostics and recovery hint', () {
      const source = RealtimeException(
        code: RealtimeErrorCode.timeout,
        message: 'chat timed out',
        providerId: 'ivs',
        details: {'request': 'token'},
      );

      final error = mapRealtimeException(source);

      expect(error.code, RealtimeErrorCode.timeout);
      expect(error.providerId, 'ivs');
      expect(error.recoverable, isTrue);
      expect(error.suggestedAction, 'retry');
      expect(error.cause, same(source));
      expect(error.details, {'request': 'token'});
    });

    test('maps structured driver and credential reasons', () {
      const webSource = RealtimeException(
        code: RealtimeErrorCode.unsupportedPlatform,
        message: 'bridge missing',
        providerId: 'agora',
        details: {'reason': 'web-sdk-unavailable'},
      );
      const credentialSource = RealtimeException(
        code: RealtimeErrorCode.unauthorized,
        message: 'expired',
        providerId: 'agora-chat',
        details: {'reason': 'credential-expired'},
      );
      const chatWebSource = RealtimeException(
        code: RealtimeErrorCode.unsupportedPlatform,
        message: 'chat bridge missing',
        providerId: 'agora-chat',
        details: {'reason': 'web-sdk-unavailable'},
      );

      final web = mapRealtimeException(webSource);
      final credential = mapRealtimeException(credentialSource);
      final chatWeb = mapRealtimeException(chatWebSource);

      expect(web.code, RealtimeErrorCode.webSdkUnavailable);
      expect(web.suggestedAction, 'load-web-provider-sdk');
      expect(credential.code, RealtimeErrorCode.credentialExpired);
      expect(credential.suggestedAction, 'refresh-provider-credentials');
      expect(chatWeb.code, RealtimeErrorCode.webSdkUnavailable);
    });

    test('maps UnsupportedError to the stable unsupported-feature code', () {
      final error = mapRealtimeException(UnsupportedError('not implemented'));

      expect(error.code, RealtimeErrorCode.unsupportedFeature);
      expect(error.suggestedAction, 'check-capabilities');
    });
  });

  group('RealtimeClient', () {
    test(
      'explicitly registered presets attach only to eligible meeting and live rooms',
      () async {
        for (final mode in ['meeting', 'broadcast']) {
          final factory = FakeMediaSessionFactory();
          final transport = FakeTransport(
            (request) => jsonResponse({
              ...liveKitJoinPayload(
                provider: 'fake',
                role: mode == 'meeting' ? 'participant' : 'host',
                participantCredential: 'proof',
                roomOwnerCredential: 'owner',
              ),
              'roomMode': mode,
              if (mode == 'broadcast') 'liveInteractions': true,
            }),
          );
          final adapters = RealtimeMediaAdapters([
            RealtimeMediaAdapter(
              sessionFactory: factory,
              renderer: const _FakeRenderer(),
            ),
          ]);
          final client = RealtimeClient(
            backendUrl: 'https://example.test',
            mediaAdapters: adapters,
            featurePlugins: const [ClassroomPreset(), LivePreset()],
            mediaClientFactory: () => MediaClient(
              backendUrl: 'https://example.test',
              registry: adapters.registry,
              transport: transport,
              heartbeatInterval: Duration.zero,
            ),
          );
          final room = await client.createRoomAndJoinIdentity(
            identity: const MediaIdentity(
              userId: 'owner',
              displayName: 'Owner',
            ),
            roomMode: mode == 'meeting'
                ? MediaRoomMode.meeting
                : MediaRoomMode.broadcast,
          );
          expect(room.classroom != null, mode == 'meeting');
          expect(room.liveInteractions != null, mode == 'broadcast');
          await room.dispose();
        }
      },
    );

    test('joins media-only room and resolves its renderer', () async {
      final factory = FakeMediaSessionFactory();
      const renderer = _FakeRenderer();
      final transport = FakeTransport(
        (_) => jsonResponse(liveKitJoinPayload(provider: 'fake')),
      );
      final mediaClient = MediaClient(
        backendUrl: 'https://example.test',
        registry: MediaRegistry([factory]),
        transport: transport,
        heartbeatInterval: Duration.zero,
      );
      final client = RealtimeClient(
        backendUrl: 'https://example.test',
        mediaAdapters: RealtimeMediaAdapters([
          RealtimeMediaAdapter(sessionFactory: factory, renderer: renderer),
        ]),
        mediaClientFactory: () => mediaClient,
      );

      final room = await client.createRoomAndJoinIdentity(
        identity: const MediaIdentity(userId: 'p1', displayName: 'P1'),
      );

      expect(room.providerId, 'fake');
      expect(room.renderer, same(renderer));
      expect(room.chat, isA<RtcDataChatSession>());
      expect(room.usesRtcDataChat, isTrue);
      expect(room.usesProductChat, isFalse);
      expect(room.state.isConnected, isTrue);
      expect(room.capabilities.canChat, isTrue);
      expect(factory.createdSessions.single.joinCount, 1);

      // Advanced RealtimeClient users retain the same backend cloud recording
      // capability as the high-level RealtimeSdk entry point.
      expect(
        room.recording.cloudRecordingSession,
        isA<HttpCloudRecordingSession>(),
      );

      final eventFuture = room.events.firstWhere(
        (event) => event is RealtimeMediaEvent,
      );
      factory.createdSessions.single.emitRemoteParticipant(
        id: 'remote',
        name: 'Remote',
      );
      expect(await eventFuture, isA<RealtimeMediaEvent>());
      expect(room.participants.map((value) => value.id), contains('remote'));

      await room.dispose();
      await room.dispose();
      expect(factory.createdSessions.single.disposeCount, 1);
    });

    test(
      'rejects backend-required capabilities the resolved room lacks',
      () async {
        final factory = FakeMediaSessionFactory();
        final payload = liveKitJoinPayload(provider: 'fake')
          ..['requiredCapabilities'] = ['remove-participants'];
        final mediaClient = MediaClient(
          backendUrl: 'https://example.test',
          registry: MediaRegistry([factory]),
          transport: FakeTransport((_) => jsonResponse(payload)),
          heartbeatInterval: Duration.zero,
        );
        final client = RealtimeClient(
          backendUrl: 'https://example.test',
          mediaAdapters: RealtimeMediaAdapters([
            RealtimeMediaAdapter(
              sessionFactory: factory,
              renderer: const _FakeRenderer(),
            ),
          ]),
          mediaClientFactory: () => mediaClient,
        );

        await expectLater(
          client.createRoomAndJoinIdentity(
            identity: const MediaIdentity(userId: 'p1', displayName: 'P1'),
          ),
          throwsA(
            isA<RealtimeException>().having(
              (error) => error.code,
              'code',
              RealtimeErrorCode.unsupportedFeature,
            ),
          ),
        );
        expect(factory.createdSessions.single.disposeCount, 1);
      },
    );

    test(
      'public vendor direct join resolves an internal engine and stays public',
      () async {
        final meetingFactory = FakeMediaSessionFactory(
          providerId: 'meeting-sdk',
        );
        final liveFactory = FakeMediaSessionFactory(providerId: 'live-sdk');
        final sdk = RealtimeSdk.standard(
          platformResolver: () => RealtimeRuntimePlatform.android,
          drivers: [
            RealtimeProviderDriver(
              platforms: const {RealtimeRuntimePlatform.android},
              publicProviderId: 'vendor',
              mediaRoomModes: const {MediaRoomMode.meeting},
              plugin: RealtimeProviderPlugin(
                id: 'meeting-sdk',
                metadata: const RealtimeProviderMetadata(displayName: 'Vendor'),
                mediaFactory: meetingFactory,
                renderer: const _FakeRenderer(),
              ),
            ),
            RealtimeProviderDriver(
              platforms: const {RealtimeRuntimePlatform.android},
              publicProviderId: 'vendor',
              mediaRoomModes: const {MediaRoomMode.broadcast},
              plugin: RealtimeProviderPlugin(
                id: 'live-sdk',
                metadata: const RealtimeProviderMetadata(displayName: 'Vendor'),
                mediaFactory: liveFactory,
                renderer: const _FakeRenderer(),
              ),
            ),
          ],
        );

        final room = await sdk.joinWithCredentials(
          mediaProviderId: 'vendor',
          mediaJoinPayload: {
            'provider': 'vendor',
            'engine': 'meeting-sdk',
            'roomMode': 'meeting',
            'roomCode': 'room-1',
            'participantId': 'user-1',
            'role': 'participant',
          },
        );

        expect(room.providerId, 'vendor');
        expect(room.engineProviderId, 'meeting-sdk');
        expect(meetingFactory.parsedPayloads.single['provider'], 'meeting-sdk');
        expect(meetingFactory.parsedPayloads.single['engine'], 'meeting-sdk');
        expect(liveFactory.parsedPayloads, isEmpty);
        await room.dispose();
      },
    );

    test('public vendor rejects a room mode and engine mismatch', () {
      final sdk = RealtimeSdk.standard(
        platformResolver: () => RealtimeRuntimePlatform.android,
        drivers: [
          RealtimeProviderDriver(
            platforms: const {RealtimeRuntimePlatform.android},
            publicProviderId: 'vendor',
            mediaRoomModes: const {MediaRoomMode.meeting},
            plugin: RealtimeProviderPlugin(
              id: 'meeting-sdk',
              metadata: const RealtimeProviderMetadata(displayName: 'Vendor'),
              mediaFactory: FakeMediaSessionFactory(providerId: 'meeting-sdk'),
              renderer: const _FakeRenderer(),
            ),
          ),
          RealtimeProviderDriver(
            platforms: const {RealtimeRuntimePlatform.android},
            publicProviderId: 'vendor',
            mediaRoomModes: const {MediaRoomMode.broadcast},
            plugin: RealtimeProviderPlugin(
              id: 'live-sdk',
              metadata: const RealtimeProviderMetadata(displayName: 'Vendor'),
              mediaFactory: FakeMediaSessionFactory(providerId: 'live-sdk'),
              renderer: const _FakeRenderer(),
            ),
          ),
        ],
      );

      expect(
        () => sdk.parseMediaCredentials(
          providerId: 'vendor',
          joinPayload: {
            'provider': 'vendor',
            'engine': 'meeting-sdk',
            'roomMode': 'broadcast',
            'roomCode': 'room-1',
            'participantId': 'user-1',
          },
        ),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.invalidArgument,
          ),
        ),
      );
    });

    test(
      'cleans up joined media when renderer registration is missing',
      () async {
        final joinedFactory = FakeMediaSessionFactory();
        final registeredFactory = FakeMediaSessionFactory(providerId: 'other');
        final transport = FakeTransport(
          (_) => jsonResponse(liveKitJoinPayload(provider: 'fake')),
        );
        final mediaClient = MediaClient(
          backendUrl: 'https://example.test',
          registry: MediaRegistry([joinedFactory]),
          transport: transport,
          heartbeatInterval: Duration.zero,
        );
        final client = RealtimeClient(
          backendUrl: 'https://example.test',
          mediaAdapters: RealtimeMediaAdapters([
            RealtimeMediaAdapter(
              sessionFactory: registeredFactory,
              renderer: const _FakeRenderer(),
            ),
          ]),
          mediaClientFactory: () => mediaClient,
        );

        await expectLater(
          client.createRoomAndJoinIdentity(
            identity: const MediaIdentity(userId: 'p1', displayName: 'P1'),
          ),
          throwsA(isA<RealtimeException>()),
        );

        expect(joinedFactory.createdSessions.single.disposeCount, 1);
      },
    );

    test('cleans up media when provider join fails', () async {
      final error = RealtimeException(
        code: RealtimeErrorCode.providerError,
        message: 'join failed',
        providerId: 'fake',
      );
      final factory = FakeMediaSessionFactory(joinError: error);
      final transport = FakeTransport(
        (_) => jsonResponse(liveKitJoinPayload(provider: 'fake')),
      );
      final mediaClient = MediaClient(
        backendUrl: 'https://example.test',
        registry: MediaRegistry([factory]),
        transport: transport,
        heartbeatInterval: Duration.zero,
      );
      final client = RealtimeClient(
        backendUrl: 'https://example.test',
        mediaAdapters: RealtimeMediaAdapters([
          RealtimeMediaAdapter(
            sessionFactory: factory,
            renderer: const _FakeRenderer(),
          ),
        ]),
        mediaClientFactory: () => mediaClient,
      );

      await expectLater(
        client.createRoomAndJoinIdentity(
          identity: const MediaIdentity(userId: 'p1', displayName: 'P1'),
        ),
        throwsA(
          isA<RealtimeException>().having(
            (e) => e.cause,
            'original failure',
            same(error),
          ),
        ),
      );
      expect(factory.createdSessions.single.disposeCount, 1);
    });

    test('does not downgrade configured Product Chat failure to RTC', () async {
      final factory = FakeMediaSessionFactory();
      final payload = liveKitJoinPayload(
        provider: 'fake',
        participantCredential: 'participant-proof',
        roomOwnerCredential: 'owner-proof',
      )..['chatProvider'] = 'ivs';
      final transport = FakeTransport((request) {
        if (request.uri.path.endsWith('/close')) {
          return jsonResponse({'ok': true});
        }
        return jsonResponse(payload);
      });
      final mediaClient = MediaClient(
        backendUrl: 'https://example.test',
        registry: MediaRegistry([factory]),
        transport: transport,
        heartbeatInterval: Duration.zero,
      );
      final client = RealtimeClient(
        backendUrl: 'https://example.test',
        mediaAdapters: RealtimeMediaAdapters([
          RealtimeMediaAdapter(
            sessionFactory: factory,
            renderer: const _FakeRenderer(),
          ),
        ]),
        mediaClientFactory: () => mediaClient,
        chatClientFactory: () => ChatClient.withConfig(
          ChatBackendConfig.fromUrl('https://example.test'),
          backend: _FailingChatBackend(),
        ),
      );

      await expectLater(
        client.createRoomAndJoinIdentity(
          identity: const MediaIdentity(userId: 'p1', displayName: 'P1'),
        ),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.network,
          ),
        ),
      );
      expect(factory.createdSessions.single.disposeCount, 1);
      expect(
        transport.requestsTo('/rooms/482913/close'),
        hasLength(1),
        reason:
            'optional Chat failure after media join must release newly created room',
      );
    });
  });

  group('RealtimeSdk facade', () {
    test(
      'standard facade rejects a known provider on an unsupported platform',
      () async {
        var webAssetLoadCount = 0;
        final sdk = RealtimeSdk.standard(
          platformResolver: () => RealtimeRuntimePlatform.web,
          webAssetsLoader:
              ({
                mediaProviderIds = const <String>[],
                includeProductChat = false,
                includeAllMediaProviders = false,
              }) async {
                webAssetLoadCount++;
              },
          drivers: [
            RealtimeProviderDriver(
              platforms: const {RealtimeRuntimePlatform.android},
              plugin: RealtimeProviderPlugin(
                id: 'fake',
                metadata: const RealtimeProviderMetadata(displayName: 'Fake'),
                mediaFactory: FakeMediaSessionFactory(providerId: 'fake'),
                renderer: const _FakeRenderer(),
              ),
            ),
          ],
        );

        await expectLater(
          sdk.joinDirect(
            MediaJoinInfo(
              providerId: 'fake',
              roomCode: 'room',
              participantId: 'p1',
              role: MediaRole.participant,
            ),
          ),
          throwsA(
            isA<RealtimeException>().having(
              (error) => error.code,
              'code',
              RealtimeErrorCode.unsupportedPlatform,
            ),
          ),
        );
        expect(webAssetLoadCount, 0);
      },
    );

    test(
      'standard Pre-Join blocks a known provider without a platform driver',
      () async {
        final sdk = RealtimeSdk.standard(
          platformResolver: () => RealtimeRuntimePlatform.web,
          drivers: [
            RealtimeProviderDriver(
              platforms: const {RealtimeRuntimePlatform.android},
              plugin: RealtimeProviderPlugin(
                id: 'fake',
                metadata: const RealtimeProviderMetadata(displayName: 'Fake'),
                mediaFactory: FakeMediaSessionFactory(providerId: 'fake'),
                renderer: const _FakeRenderer(),
              ),
            ),
          ],
        );

        final result = await sdk.preJoin(providerId: 'fake');

        expect(result.isReady, isFalse);
        expect(
          result.check(MediaPreJoinCheckType.provider)?.status,
          MediaPreJoinStatus.unsupported,
        );
        expect(
          result.check(MediaPreJoinCheckType.provider)?.severity,
          MediaPreJoinSeverity.blocking,
        );
      },
    );

    test(
      'parses and joins raw media credentials through the selected driver',
      () async {
        final webAssetLoads =
            <({Set<String> providers, bool chat, bool all})>[];
        final factory = FakeMediaSessionFactory(providerId: 'fake');
        final sdk = RealtimeSdk.standard(
          platformResolver: () => RealtimeRuntimePlatform.web,
          webAssetsLoader:
              ({
                mediaProviderIds = const <String>[],
                includeProductChat = false,
                includeAllMediaProviders = false,
              }) async {
                webAssetLoads.add((
                  providers: mediaProviderIds.toSet(),
                  chat: includeProductChat,
                  all: includeAllMediaProviders,
                ));
              },
          drivers: [
            RealtimeProviderDriver(
              platforms: const {RealtimeRuntimePlatform.web},
              plugin: RealtimeProviderPlugin(
                id: 'fake',
                metadata: const RealtimeProviderMetadata(displayName: 'Fake'),
                mediaFactory: factory,
                renderer: const _FakeRenderer(),
              ),
            ),
          ],
        );

        final room = await sdk.joinWithCredentials(
          mediaProviderId: 'fake',
          mediaJoinPayload: {
            'roomCode': 'room-1',
            'participantId': 'user-1',
            'role': 'participant',
            'payload': {'token': 'short-lived'},
          },
        );

        expect(room.providerId, 'fake');
        expect(factory.parsedPayloads.single['provider'], 'fake');
        expect(
          (factory.parsedPayloads.single['payload'] as Map)['token'],
          'short-lived',
        );
        expect(webAssetLoads, hasLength(1));
        expect(webAssetLoads.single.providers, unorderedEquals(['fake']));
        expect(webAssetLoads.single.chat, isFalse);
        expect(webAssetLoads.single.all, isFalse);
        await room.dispose();
      },
    );

    test(
      'custom plugin override is effective in SDK support checks and parsing',
      () {
        final builtinFactory = FakeMediaSessionFactory(providerId: 'fake');
        final customFactory = FakeMediaSessionFactory(providerId: 'fake');
        final sdk = RealtimeSdk.standard(
          platformResolver: () => RealtimeRuntimePlatform.web,
          drivers: [
            RealtimeProviderDriver(
              platforms: const {RealtimeRuntimePlatform.android},
              plugin: RealtimeProviderPlugin(
                id: 'fake',
                metadata: const RealtimeProviderMetadata(
                  displayName: 'Built-in',
                ),
                mediaFactory: builtinFactory,
                renderer: const _FakeRenderer(),
              ),
            ),
          ],
          additionalPlugins: [
            RealtimeProviderPlugin(
              id: 'fake',
              metadata: const RealtimeProviderMetadata(displayName: 'Custom'),
              mediaFactory: customFactory,
              renderer: const _FakeRenderer(),
            ),
          ],
        );

        expect(sdk.supportsProvider('fake'), isTrue);
        expect(sdk.supportedProviderIds, contains('fake'));
        final parsed = sdk.parseMediaCredentials(
          providerId: 'fake',
          joinPayload: {'roomCode': 'room-1', 'participantId': 'user-1'},
        );
        expect(parsed.providerId, 'fake');
        expect(customFactory.parsedPayloads, hasLength(1));
        expect(builtinFactory.parsedPayloads, isEmpty);
      },
    );

    test('parses raw chat credentials independently from media provider', () {
      final sdk = RealtimeSdk.standard(
        platformResolver: () => RealtimeRuntimePlatform.web,
        drivers: [
          RealtimeProviderDriver(
            platforms: {RealtimeRuntimePlatform.web},
            plugin: RealtimeProviderPlugin(
              id: 'chat-only',
              metadata: RealtimeProviderMetadata(displayName: 'Chat'),
              chatFactory: _FakeChatFactory('chat-only'),
            ),
          ),
        ],
      );

      final joinInfo = sdk.parseChatCredentials(
        providerId: 'chat-only',
        joinPayload: {
          'roomCode': 'room-1',
          'participantId': 'participant-1',
          'userId': 'user-1',
          'displayName': 'User',
          'role': 'participant',
        },
      );

      expect(joinInfo.providerId, 'chat-only');
      expect(joinInfo.roomCode, 'room-1');
      expect(joinInfo.userId, 'user-1');
    });

    test(
      'loads only the selected Product Chat Web runtime before connect',
      () async {
        final loads = <({bool chat, bool all, Set<String> media})>[];
        final sdk = RealtimeSdk.standard(
          platformResolver: () => RealtimeRuntimePlatform.web,
          webAssetsLoader:
              ({
                mediaProviderIds = const <String>[],
                includeProductChat = false,
                includeAllMediaProviders = false,
              }) async {
                loads.add((
                  chat: includeProductChat,
                  all: includeAllMediaProviders,
                  media: mediaProviderIds.toSet(),
                ));
              },
          drivers: [
            RealtimeProviderDriver(
              platforms: const {RealtimeRuntimePlatform.web},
              plugin: RealtimeProviderPlugin(
                id: 'agora-chat',
                metadata: const RealtimeProviderMetadata(
                  displayName: 'Agora Chat',
                ),
                chatFactory: _FakeChatFactory('agora-chat'),
              ),
            ),
          ],
        );

        final room = await sdk.connectChatWithCredentials(
          providerId: 'agora-chat',
          joinPayload: {
            'roomCode': 'room-1',
            'participantId': 'participant-1',
            'userId': 'user-1',
            'displayName': 'User',
            'role': 'participant',
          },
        );

        expect(loads, hasLength(1));
        expect(loads.single.chat, isTrue);
        expect(loads.single.all, isFalse);
        expect(loads.single.media, {'agora-chat'});
        await room.dispose();
      },
    );

    test('rejects credential payload that declares another provider', () {
      final sdk = RealtimeSdk.standard(
        platformResolver: () => RealtimeRuntimePlatform.web,
        drivers: [
          RealtimeProviderDriver(
            platforms: const {RealtimeRuntimePlatform.web},
            plugin: RealtimeProviderPlugin(
              id: 'fake',
              metadata: const RealtimeProviderMetadata(displayName: 'Fake'),
              mediaFactory: FakeMediaSessionFactory(providerId: 'fake'),
              renderer: const _FakeRenderer(),
            ),
          ),
        ],
      );

      expect(
        () => sdk.parseMediaCredentials(
          providerId: 'fake',
          joinPayload: {
            'provider': 'other',
            'roomCode': 'room-1',
            'participantId': 'user-1',
          },
        ),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.invalidArgument,
          ),
        ),
      );
    });

    test('runs provider-neutral Pre-Join through the facade', () async {
      final factory = FakeMediaSessionFactory();
      final transport = FakeTransport(
        (_) => jsonResponse({'contractVersion': 1, 'ok': true}),
      );
      final mediaClient = MediaClient(
        backendUrl: 'https://example.test',
        registry: MediaRegistry([factory]),
        transport: transport,
        heartbeatInterval: Duration.zero,
      );
      final advanced = RealtimeClient(
        backendUrl: 'https://example.test',
        mediaAdapters: RealtimeMediaAdapters([
          RealtimeMediaAdapter(
            sessionFactory: factory,
            renderer: const _FakeRenderer(),
          ),
        ]),
        mediaClientFactory: () => mediaClient,
      );
      final sdk = RealtimeSdk(
        backendUrl: 'https://example.test',
        webAssetsLoader: _skipWebAssets,
        plugins: [
          RealtimeProviderPlugin(
            id: 'fake',
            metadata: const RealtimeProviderMetadata(displayName: 'Fake'),
            mediaFactory: factory,
            renderer: const _FakeRenderer(),
          ),
        ],
        clientFactory: () => advanced,
      );

      final result = await sdk.preJoin(providerId: 'fake');

      expect(result.checks, isNotEmpty);
    });

    test('maps low-level join errors to RealtimeException', () async {
      final source = RealtimeException(
        code: RealtimeErrorCode.providerError,
        message: 'provider failed',
        providerId: 'fake',
      );
      final factory = FakeMediaSessionFactory(joinError: source);
      final transport = FakeTransport(
        (_) => jsonResponse(liveKitJoinPayload(provider: 'fake')),
      );
      final mediaClient = MediaClient(
        backendUrl: 'https://example.test',
        registry: MediaRegistry([factory]),
        transport: transport,
        heartbeatInterval: Duration.zero,
      );
      final advanced = RealtimeClient(
        backendUrl: 'https://example.test',
        mediaAdapters: RealtimeMediaAdapters([
          RealtimeMediaAdapter(
            sessionFactory: factory,
            renderer: const _FakeRenderer(),
          ),
        ]),
        mediaClientFactory: () => mediaClient,
      );
      final sdk = RealtimeSdk(
        backendUrl: 'https://example.test',
        webAssetsLoader: _skipWebAssets,
        plugins: [
          RealtimeProviderPlugin(
            id: 'fake',
            metadata: const RealtimeProviderMetadata(displayName: 'Fake'),
            mediaFactory: factory,
            renderer: const _FakeRenderer(),
          ),
        ],
        clientFactory: () => advanced,
      );

      await expectLater(
        sdk.createRoom(
          user: const MediaIdentity(userId: 'p1', displayName: 'P1'),
        ),
        throwsA(
          isA<RealtimeException>()
              .having(
                (error) => error.code,
                'code',
                RealtimeErrorCode.providerError,
              )
              .having((error) => error.providerId, 'providerId', 'fake')
              .having((error) => error.cause, 'cause', same(source)),
        ),
      );
    });

    test('maps incompatible backend contract to invalidResponse', () async {
      final factory = FakeMediaSessionFactory();
      final payload = liveKitJoinPayload(provider: 'fake')
        ..['contractVersion'] = 2;
      final mediaClient = MediaClient(
        backendUrl: 'https://example.test',
        registry: MediaRegistry([factory]),
        transport: FakeTransport((_) => jsonResponse(payload)),
        heartbeatInterval: Duration.zero,
      );
      final advanced = RealtimeClient(
        backendUrl: 'https://example.test',
        mediaAdapters: RealtimeMediaAdapters([
          RealtimeMediaAdapter(
            sessionFactory: factory,
            renderer: const _FakeRenderer(),
          ),
        ]),
        mediaClientFactory: () => mediaClient,
      );
      final sdk = RealtimeSdk(
        backendUrl: 'https://example.test',
        webAssetsLoader: _skipWebAssets,
        plugins: [
          RealtimeProviderPlugin(
            id: 'fake',
            metadata: const RealtimeProviderMetadata(displayName: 'Fake'),
            mediaFactory: factory,
            renderer: const _FakeRenderer(),
          ),
        ],
        clientFactory: () => advanced,
      );

      await expectLater(
        sdk.createRoom(
          user: const MediaIdentity(userId: 'p1', displayName: 'P1'),
        ),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.invalidResponse,
          ),
        ),
      );
    });
  });

  test(
    'RealtimeRoomView owns the resolved room as its single room input',
    () async {
      final factory = FakeMediaSessionFactory();
      final mediaClient = MediaClient(
        backendUrl: 'https://example.test',
        registry: MediaRegistry([factory]),
        transport: FakeTransport(
          (_) => jsonResponse(liveKitJoinPayload(provider: 'fake')),
        ),
        heartbeatInterval: Duration.zero,
      );
      final client = RealtimeClient(
        backendUrl: 'https://example.test',
        mediaAdapters: RealtimeMediaAdapters([
          RealtimeMediaAdapter(
            sessionFactory: factory,
            renderer: const _FakeRenderer(),
          ),
        ]),
        mediaClientFactory: () => mediaClient,
      );
      final room = await client.createRoomAndJoinIdentity(
        identity: const MediaIdentity(userId: 'p1', displayName: 'P1'),
      );

      final view = RealtimeRoomView(room: room);
      expect(view.room, same(room));
      await room.dispose();
    },
  );

  group('RealtimeChatModeration execution routing', () {
    test(
      'prefers provider client removal over the backend control plane',
      () async {
        final session = _ModerationChatSession(canDisconnectUser: true);
        final moderation = RealtimeChatModeration(session);

        expect(
          moderation.capabilities.removeMember.execution,
          ChatManagementExecution.client,
        );

        await moderation.removeMember('user-2');

        expect(session.disconnectedUsers, ['user-2']);
        await session.dispose();
      },
    );

    test(
      'falls back to backend removal when the client cannot enforce it',
      () async {
        final session = _ModerationChatSession();
        final backend = _ModerationControlPlane(
          capabilities: const ChatManagementCapabilities(
            removeMember: ChatManagementCapability.backend(),
          ),
        );
        final moderation = RealtimeChatModeration(session, backend);

        expect(
          moderation.capabilities.removeMember.execution,
          ChatManagementExecution.backend,
        );

        await moderation.removeMember('user-2');

        expect(session.disconnectedUsers, isEmpty);
        expect(backend.removedUsers, ['user-2']);
        await session.dispose();
      },
    );

    test(
      'uses hybrid removal when client enforcement and backend sync both exist',
      () async {
        final session = _ModerationChatSession(canDisconnectUser: true);
        final backend = _ModerationControlPlane(
          capabilities: const ChatManagementCapabilities(
            removeMember: ChatManagementCapability.backend(),
          ),
        );
        final moderation = RealtimeChatModeration(session, backend);

        expect(
          moderation.capabilities.removeMember.execution,
          ChatManagementExecution.hybrid,
        );

        await moderation.removeMember('user-2');

        expect(session.disconnectedUsers, ['user-2']);
        expect(backend.removedUsers, isEmpty);
        expect(backend.syncedUsers, ['user-2']);
        await session.dispose();
      },
    );
  });
}

class _FakeChatFactory implements ChatSessionFactory {
  const _FakeChatFactory(this.providerId);

  @override
  final String providerId;

  @override
  ChatJoinInfo parseJoinInfo(Map<String, dynamic> json) => ChatJoinInfo(
    providerId: providerId,
    roomCode: json['roomCode']?.toString() ?? '',
    participantId: json['participantId']?.toString() ?? '',
    userId: json['userId']?.toString() ?? '',
    displayName: json['displayName']?.toString() ?? '',
    role: ChatRole.tryParse(json['role']) ?? ChatRole.participant,
    json: json,
  );

  @override
  ChatSession createSession(ChatJoinInfo joinInfo) =>
      _StubChatSession(providerId, joinInfo.role);
}

class _StubChatSession implements ChatSession {
  const _StubChatSession(this.providerId, this.role);

  @override
  final String providerId;

  @override
  final ChatRole role;

  @override
  ChatCapabilities get capabilities => const ChatCapabilities();

  @override
  ChatConnectionState get state => ChatConnectionState.connected;

  @override
  List<ChatMessage> get messages => const [];

  @override
  Stream<ChatConnectionState> get states => const Stream.empty();

  @override
  Stream<List<ChatMessage>> get messageSnapshots => const Stream.empty();

  @override
  Stream<ChatEvent> get events => const Stream.empty();

  @override
  Future<void> connect(
    ChatJoinInfo joinInfo, {
    ChatCredentialProvider? credentialProvider,
  }) async {}

  @override
  Future<void> sendMessage(String message) async {}

  @override
  Future<void> deleteMessage(String messageId) async {}

  @override
  Future<void> disconnectUser(String userId) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {}
}

class _ModerationChatSession implements ChatSession, ChatSessionIdentity {
  _ModerationChatSession({this.canDisconnectUser = false});

  final bool canDisconnectUser;
  final List<String> disconnectedUsers = <String>[];
  final StreamController<ChatConnectionState> _states =
      StreamController<ChatConnectionState>.broadcast();
  final StreamController<List<ChatMessage>> _messages =
      StreamController<List<ChatMessage>>.broadcast();
  final StreamController<ChatEvent> _events =
      StreamController<ChatEvent>.broadcast();

  @override
  String get providerId => 'moderation-fake';
  @override
  String get localParticipantId => 'participant-host';
  @override
  String get localUserId => 'host-user';
  @override
  String get localDisplayName => 'Host';
  @override
  ChatRole get role => ChatRole.host;
  @override
  ChatCapabilities get capabilities => ChatCapabilities(
    canSendMessage: true,
    canDisconnectUser: canDisconnectUser,
  );
  @override
  ChatConnectionState get state => ChatConnectionState.connected;
  @override
  List<ChatMessage> get messages => const [];
  @override
  Stream<ChatConnectionState> get states => _states.stream;
  @override
  Stream<List<ChatMessage>> get messageSnapshots => _messages.stream;
  @override
  Stream<ChatEvent> get events => _events.stream;

  @override
  Future<void> connect(
    ChatJoinInfo joinInfo, {
    ChatCredentialProvider? credentialProvider,
  }) async {}
  @override
  Future<void> sendMessage(String message) async {}
  @override
  Future<void> deleteMessage(String messageId) async {}
  @override
  Future<void> disconnectUser(String userId) async {
    disconnectedUsers.add(userId);
  }

  @override
  Future<void> disconnect() async {}
  @override
  Future<void> dispose() async {
    await _states.close();
    await _messages.close();
    await _events.close();
  }
}

class _ModerationControlPlane
    implements
        ChatModeration,
        ChatModerationCapabilitySource,
        ChatModerationStateSync {
  _ModerationControlPlane({required this.capabilities});

  final ChatManagementCapabilities capabilities;
  final List<String> removedUsers = <String>[];
  final List<String> syncedUsers = <String>[];

  @override
  ChatManagementCapabilities get moderationCapabilities => capabilities;
  @override
  Future<List<ChatMember>> listMembers() async => const [];
  @override
  Future<void> removeMember(String userId) async {
    removedUsers.add(userId);
  }

  @override
  Future<void> syncRemovedMember(String userId) async {
    syncedUsers.add(userId);
  }

  @override
  Future<void> muteMember(String userId, {required bool muted}) async {}
  @override
  Future<void> banMember(String userId, {required bool banned}) async {}
  @override
  Future<void> recallMessage(String messageId) async {}
  @override
  Future<void> changeMemberRole(String userId, ChatRole role) async {}
  @override
  Future<void> closeRoom() async {}
}

class _FailingChatBackend extends ChatBackendClient {
  _FailingChatBackend()
    : super(ChatBackendConfig.fromUrl('https://example.test'));

  @override
  Future<ChatBackendJoinResponse> issueToken({
    required String roomCode,
    required String participantId,
    String? participantCredential,
    String? roomOwnerCredential,
  }) => throw const RealtimeException(
    code: RealtimeErrorCode.network,
    message: 'chat backend unavailable',
    providerId: 'ivs',
  );
}

class _FakeRenderer extends MediaTrackRenderer {
  const _FakeRenderer();

  @override
  Widget buildView(BuildContext context, MediaVideoTrack track) =>
      const SizedBox.shrink();
}

Future<void> _skipWebAssets({
  Iterable<String> mediaProviderIds = const [],
  bool includeProductChat = false,
  bool includeAllMediaProviders = false,
}) async {}

class _FakeProcessedMediaSession extends FakeMediaSession
    implements ProcessedVideoSink {
  _FakeProcessedMediaSession({
    bool supportsBackground = true,
    super.role = MediaRole.participant,
  }) : super(
         providerId: 'fake-effects-provider',
         capabilities: MediaCapabilities(
           canPublishAudio: true,
           canPublishVideo: true,
           canBlurBackground: supportsBackground,
           canSwitchCamera: true,
           canSubscribeVideo: true,
         ),
       );

  final List<ProcessedVideoSource> attachedSources = [];
  int detachCalls = 0;
  bool supportsSource = true;
  Object? attachError;

  @override
  bool supportsProcessedVideoSource(ProcessedVideoSource source) =>
      supportsSource;

  @override
  Future<void> attachProcessedVideoSource(ProcessedVideoSource source) async {
    if (attachError != null) throw attachError!;
    attachedSources.add(source);
  }

  @override
  Future<void> detachProcessedVideoSource() async {
    detachCalls++;
  }
}

class _FakeEffectsPlatform extends FlutterRealtimeProcessedVideoPlatform {
  int createCalls = 0;
  bool supported = true;
  Completer<void>? createGate;
  final StreamController<VideoEffectsFailure> _failureController =
      StreamController<VideoEffectsFailure>.broadcast();
  final List<bool> enabled = [];
  VideoEffectsSourceConfig? lastConfig;
  final List<MediaBackgroundEffect> effects = [];
  final List<String> disposedSources = [];

  @override
  Stream<VideoEffectsFailure> get failures => _failureController.stream;

  void emitFailure(VideoEffectsFailure failure) =>
      _failureController.add(failure);

  Future<void> close() => _failureController.close();

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<ProcessedVideoSource> createSource(
    VideoEffectsSourceConfig config,
  ) async {
    createCalls++;
    await createGate?.future;
    lastConfig = config;
    return const ProcessedVideoSource(
      id: 'effects-source-1',
      platform: ProcessedVideoPlatform.web,
      kind: ProcessedVideoSourceKind.mediaStreamTrack,
      width: 1280,
      height: 720,
      frameRate: 24,
    );
  }

  @override
  Future<void> setEffect(String sourceId, MediaBackgroundEffect effect) async {
    effects.add(effect);
  }

  @override
  Future<void> setEnabled(String sourceId, bool value) async {
    enabled.add(value);
  }

  @override
  Future<void> selectCamera(String sourceId, String? deviceId) async {}

  @override
  Future<List<ProcessedVideoCameraDevice>> listCameras() async => const [];

  @override
  Future<void> disposeSource(String sourceId) async {
    disposedSources.add(sourceId);
  }
}

RealtimeSdk _sdkWithProbeFactory(FakeMediaSessionFactory factory) =>
    RealtimeSdk.standard(
      services: RealtimeRoomServices(
        videoEffectsFactory: DefaultRealtimeVideoEffects.new,
      ),
      platformResolver: () => RealtimeRuntimePlatform.macos,
      drivers: [
        RealtimeProviderDriver(
          platforms: const {RealtimeRuntimePlatform.macos},
          plugin: RealtimeProviderPlugin(
            id: factory.providerId,
            metadata: const RealtimeProviderMetadata(displayName: 'Test'),
            mediaFactory: factory,
            renderer: const _FakeRenderer(),
            effectsProbe: createDefaultRealtimeDrivers()
                .firstWhere((d) => d.providerId == factory.providerId)
                .plugin
                .effectsProbe,
          ),
        ),
      ],
    );

class _FakePreviewMediaSessionFactory extends FakeMediaSessionFactory
    implements MediaLocalPreviewFactory {
  _FakePreviewMediaSessionFactory({required super.providerId});

  final _FakeLocalPreviewSession preview = _FakeLocalPreviewSession();
  int localPreviewCalls = 0;

  @override
  Future<MediaLocalPreviewSession> createLocalPreview({
    required MediaRole role,
  }) async {
    localPreviewCalls++;
    return preview;
  }
}

class _FakeLocalPreviewSession implements MediaLocalPreviewSession {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RealtimeRoom _effectsRoom(
  _FakeEffectsPlatform platform,
  _FakeProcessedMediaSession session,
) => RealtimeRoom(
  media: MediaRoomSession.direct(
    roomCode: 'effects',
    participantId: 'local',
    session: session,
  ),
  renderer: const _FakeRenderer(),
  disposeClients: () {},
  effectsCapabilities: const MediaBackgroundCapabilities(
    canBlur: true,
    canReplaceImage: true,
  ),
  videoEffects: DefaultRealtimeVideoEffects(
    bridge: VideoEffectsBridge(platform: platform),
  ),
);
