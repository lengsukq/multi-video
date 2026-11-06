import 'dart:async';

import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_media_session.dart';
import 'support/fake_transport.dart';

void main() {
  late FakeTransport transport;
  late MediaRegistry registry;
  late FakeMediaSessionFactory factory;

  MediaClient clientFor(
    FutureOr<MediaBackendTransportResponse> Function(CapturedRequest) handler, {
    MediaRegistry? withRegistry,
    Duration heartbeatInterval = const Duration(seconds: 30),
  }) {
    transport = FakeTransport(handler);
    return MediaClient.withConfig(
      MediaBackendConfig.fromUrl(
        'http://127.0.0.1:3000',
        heartbeatInterval: heartbeatInterval,
      ),
      registry: withRegistry ?? registry,
      transport: transport,
    );
  }

  setUp(() {
    factory = FakeMediaSessionFactory();
    registry = MediaRegistry([factory]);
  });

  test(
    'a backend that ignores an explicit ordinary policy is rolled back before media joins',
    () async {
      final client = clientFor(
        (request) => request.uri.path.endsWith('/close')
            ? jsonResponse({'ok': true})
            : jsonResponse(
                liveKitJoinPayload(
                  provider: 'fake',
                  participantCredential: 'proof',
                  roomOwnerCredential: 'owner',
                ),
              ),
        heartbeatInterval: Duration.zero,
      );
      addTearDown(client.dispose);
      await expectLater(
        client.createRoomAndJoinIdentity(
          identity: const MediaIdentity(userId: 'host', displayName: 'Host'),
          meetingMode: MediaMeetingMode.standard,
        ),
        throwsA(
          isA<RealtimeException>().having(
            (e) => e.code,
            'code',
            RealtimeErrorCode.unsupportedFeature,
          ),
        ),
      );
      expect(transport.requests.map((r) => r.uri.path), [
        '/rooms',
        '/rooms/482913/close',
      ]);
    },
  );

  group('createRoomAndJoin', () {
    test(
      'identity avatars survive backend responses that omit profile fields',
      () async {
        final client = clientFor(
          (_) => jsonResponse(liveKitJoinPayload(provider: 'fake')),
          heartbeatInterval: Duration.zero,
        );
        addTearDown(client.dispose);
        const identity = MediaIdentity(
          userId: 'user',
          displayName: 'My name',
          avatarUrl: 'https://avatar.test/self.png',
        );
        for (final create in [true, false]) {
          final room = create
              ? await client.createRoomAndJoinIdentity(identity: identity)
              : await client.joinRoomIdentity(
                  roomCode: '482913',
                  identity: identity,
                );
          expect(room.snapshot.localParticipant?.avatarUrl, identity.avatarUrl);
          expect(
            room.snapshot.localParticipant?.displayName,
            identity.displayName,
          );
          await room.dispose();
        }
      },
    );

    test(
      'failed creator media join closes new room instead of reserving its code',
      () async {
        final failingFactory = FakeMediaSessionFactory(
          joinError: const RealtimeException(
            code: RealtimeErrorCode.providerError,
            message: 'fake.rtc.join',
          ),
        );
        final client = clientFor(
          (request) {
            if (request.uri.path.endsWith('/close')) {
              return jsonResponse({'ok': true});
            }
            return jsonResponse(
              liveKitJoinPayload(
                provider: 'fake',
                roomCode: 'retry-room',
                participantId: 'creator-1',
                role: 'participant',
                participantCredential: 'creator-proof',
                roomOwnerCredential: 'owner-proof',
              ),
            );
          },
          withRegistry: MediaRegistry([failingFactory]),
          heartbeatInterval: Duration.zero,
        );
        await expectLater(
          client.createRoomAndJoinIdentity(
            identity: const MediaIdentity(
              userId: 'creator',
              displayName: 'Creator',
            ),
            roomCode: 'retry-room',
          ),
          throwsA(isA<RealtimeException>()),
        );
        final close = transport.requestsTo('/rooms/retry-room/close').single;
        expect(close.json?['requesterParticipantId'], 'creator-1');
        expect(close.json?['participantCredential'], 'creator-proof');
        expect(close.json?['roomOwnerCredential'], 'owner-proof');
        expect(transport.requestsTo('/rooms/retry-room/leave'), isEmpty);
        expect(failingFactory.createdSessions.single.disposeCount, 1);
        client.dispose();
      },
    );

    test('a failed join of an existing room never closes that room', () async {
      final failingFactory = FakeMediaSessionFactory(
        joinError: const RealtimeException(
          code: RealtimeErrorCode.providerError,
          message: 'fake.rtc.join',
        ),
      );
      final client = clientFor(
        (_) => jsonResponse(
          liveKitJoinPayload(
            provider: 'fake',
            roomCode: 'existing-room',
            participantId: 'guest',
            role: 'participant',
            participantCredential: 'guest-proof',
          ),
        ),
        withRegistry: MediaRegistry([failingFactory]),
        heartbeatInterval: Duration.zero,
      );
      await expectLater(
        client.joinRoomIdentity(
          roomCode: 'existing-room',
          identity: const MediaIdentity(userId: 'guest', displayName: 'Guest'),
        ),
        throwsA(isA<RealtimeException>()),
      );
      expect(transport.requestsTo('/rooms/existing-room/close'), isEmpty);
      expect(transport.requestsTo('/rooms/existing-room/leave'), hasLength(1));
      client.dispose();
    });

    test(
      'refreshes credentials once for concurrent adapter requests',
      () async {
        final refreshResponse = Completer<MediaBackendTransportResponse>();
        var refreshRequests = 0;
        final client = clientFor((request) {
          if (request.uri.path.endsWith('/credentials/refresh')) {
            refreshRequests++;
            return refreshResponse.future;
          }
          return jsonResponse(
            liveKitJoinPayload(
              provider: 'fake',
              participantId: 'participant-1',
              role: 'host',
              participantCredential: 'proof-123',
            ),
          );
        }, heartbeatInterval: Duration.zero);

        final room = await client.createRoomAndJoin(
          nickname: 'Host',
          role: MediaRole.host,
        );
        final session = factory.createdSessions.single;
        final current = MediaJoinInfo(
          providerId: 'fake',
          roomCode: room.roomCode,
          participantId: room.participantId,
          role: MediaRole.host,
        );

        final first = session.refreshCredentials(current);
        final second = session.refreshCredentials(current);
        await Future<void>.delayed(Duration.zero);
        expect(refreshRequests, 1);
        final refreshRequest = transport.requests.firstWhere(
          (request) => request.uri.path.endsWith('/credentials/refresh'),
        );
        expect(refreshRequest.json?['participantCredential'], 'proof-123');
        refreshResponse.complete(
          jsonResponse(
            liveKitJoinPayload(
              provider: 'fake',
              participantId: 'participant-1',
              role: 'host',
            ),
          ),
        );
        final refreshed = await Future.wait([first, second]);

        expect(refreshed, hasLength(2));
        expect(refreshed.first.participantId, 'participant-1');
        expect(identical(refreshed.first, refreshed.last), isTrue);
        await room.dispose();
        client.dispose();
      },
    );

    test(
      'rejects refreshed credentials that change participant identity',
      () async {
        final client = clientFor((request) {
          final participantId =
              request.uri.path.endsWith('/credentials/refresh')
              ? 'different-participant'
              : 'participant-1';
          return jsonResponse(
            liveKitJoinPayload(
              provider: 'fake',
              participantId: participantId,
              role: 'host',
            ),
          );
        }, heartbeatInterval: Duration.zero);
        final room = await client.createRoomAndJoin(
          nickname: 'Host',
          role: MediaRole.host,
        );
        final current = MediaJoinInfo(
          providerId: 'fake',
          roomCode: room.roomCode,
          participantId: room.participantId,
          role: MediaRole.host,
        );

        await expectLater(
          factory.createdSessions.single.refreshCredentials(current),
          throwsA(
            isA<RealtimeException>().having(
              (error) => error.code,
              'code',
              RealtimeErrorCode.invalidArgument,
            ),
          ),
        );
        await room.dispose();
        client.dispose();
      },
    );

    test(
      'rejects refreshed credentials that change provider, room, or role',
      () async {
        final mismatches = <(String, Map<String, Object?>)>[
          ('provider', liveKitJoinPayload(provider: 'other-provider')),
          ('room', liveKitJoinPayload(provider: 'fake', roomCode: 'new-room')),
          ('role', liveKitJoinPayload(provider: 'fake', role: 'participant')),
        ];

        for (final mismatch in mismatches) {
          final client = clientFor((request) {
            if (request.uri.path.endsWith('/credentials/refresh')) {
              return jsonResponse(mismatch.$2);
            }
            return jsonResponse(
              liveKitJoinPayload(provider: 'fake', role: 'host'),
            );
          }, heartbeatInterval: Duration.zero);
          final room = await client.createRoomAndJoin(
            nickname: 'Host',
            role: MediaRole.host,
          );
          final current = MediaJoinInfo(
            providerId: 'fake',
            roomCode: room.roomCode,
            participantId: room.participantId,
            role: MediaRole.host,
          );

          await expectLater(
            factory.createdSessions.last.refreshCredentials(current),
            throwsA(
              isA<RealtimeException>().having(
                (error) => error.code,
                'code',
                RealtimeErrorCode.invalidArgument,
              ),
            ),
            reason: 'refresh response changed its ${mismatch.$1}',
          );
          await room.dispose();
          client.dispose();
        }
      },
    );

    test('preserves requested role when backend omits role', () async {
      final transport = FakeTransport(
        (_) => jsonResponse({
          'contractVersion': 1,
          'provider': 'fake',
          'roomCode': '482913',
          'participantId': 'viewer-a',
        }),
      );
      final factory = FakeMediaSessionFactory();
      final client = MediaClient(
        backendUrl: 'https://example.test',
        registry: MediaRegistry([factory]),
        transport: transport,
        heartbeatInterval: Duration.zero,
      );

      final room = await client.createRoomAndJoin(
        nickname: 'Viewer A',
        role: MediaRole.viewer,
      );

      expect(room.role, MediaRole.viewer);
      expect(factory.parsedPayloads.single['role'], 'viewer');
      await room.dispose();
      client.dispose();
    });

    test('normalizes reconnect and recovery for the logical room', () async {
      final client = clientFor(
        (_) => jsonResponse(
          liveKitJoinPayload(
            provider: 'fake',
            participantId: 'p1',
            role: 'participant',
          ),
        ),
        heartbeatInterval: Duration.zero,
      );
      final room = await client.createRoomAndJoin(nickname: 'Leo');
      final recoveries = <MediaRecoveryStatus>[];
      final subscription = room.recoveries.listen(recoveries.add);
      final session = factory.createdSessions.single;

      session.simulateState(
        MediaSessionState.reconnecting,
        reason: 'network-lost',
      );
      await Future<void>.delayed(Duration.zero);
      session.simulateState(
        MediaSessionState.connected,
        reason: 'network-restored',
      );
      await Future<void>.delayed(Duration.zero);

      expect(recoveries, isNotEmpty);
      expect(recoveries.first.phase, MediaRecoveryPhase.reconnecting);
      expect(recoveries.first.attempt, 1);
      expect(recoveries.last.phase, MediaRecoveryPhase.recovered);
      expect(recoveries.last.attempt, 1);
      expect(room.recoveryStatus?.phase, MediaRecoveryPhase.recovered);

      await subscription.cancel();
      await room.dispose();
      client.dispose();
    });

    test('reports standardized reconnect and recovery lifecycle', () async {
      final client = clientFor(
        (_) => jsonResponse(
          liveKitJoinPayload(
            provider: 'fake',
            participantId: 'p1',
            role: 'participant',
          ),
        ),
        heartbeatInterval: Duration.zero,
      );
      final room = await client.createRoomAndJoin(nickname: 'Leo');
      final session = factory.createdSessions.single;
      final recoveries = <MediaRecoveryStatus>[];
      final subscription = room.recoveries.listen(recoveries.add);

      session.simulateState(
        MediaSessionState.reconnecting,
        reason: 'network-lost',
      );
      await Future<void>.delayed(Duration.zero);
      session.simulateState(
        MediaSessionState.connected,
        reason: 'network-recovered',
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        recoveries.any(
          (item) =>
              item.phase == MediaRecoveryPhase.reconnecting &&
              item.reason == 'network-lost',
        ),
        isTrue,
      );
      expect(room.recoveryStatus?.phase, MediaRecoveryPhase.recovered);
      expect(room.recoveryStatus?.reason, 'network-recovered');
      expect(room.recoveryStatus?.attempt, 1);

      await subscription.cancel();
      await room.dispose();
      client.dispose();
    });

    test(
      'reports reconnect as failed when the provider ends the session',
      () async {
        final client = clientFor(
          (_) => jsonResponse(
            liveKitJoinPayload(
              provider: 'fake',
              participantId: 'p1',
              role: 'participant',
            ),
          ),
          heartbeatInterval: Duration.zero,
        );
        final room = await client.createRoomAndJoin(nickname: 'Leo');
        final session = factory.createdSessions.single;
        final recoveries = <MediaRecoveryStatus>[];
        final subscription = room.recoveries.listen(recoveries.add);

        session.simulateState(
          MediaSessionState.reconnecting,
          reason: 'network-lost',
        );
        await Future<void>.delayed(Duration.zero);
        session.simulateState(
          MediaSessionState.ended,
          reason: 'provider-disconnected',
        );
        await Future<void>.delayed(Duration.zero);

        expect(recoveries.last.phase, MediaRecoveryPhase.failed);
        expect(recoveries.last.attempt, 1);
        expect(recoveries.last.reason, 'provider-disconnected');
        expect(room.recoveryStatus?.phase, MediaRecoveryPhase.failed);

        await subscription.cancel();
        await room.dispose();
        client.dispose();
      },
    );

    test('registers, joins, and attaches backend presence', () async {
      final client = clientFor(
        (_) => jsonResponse(
          liveKitJoinPayload(
            provider: 'fake',
            participantId: 'host-a',
            role: 'host',
            roomOwnerCredential: 'owner-proof-123',
          ),
        ),
        heartbeatInterval: Duration.zero,
      );

      final room = await client.createRoomAndJoin(
        role: MediaRole.host,
        roomCode: '482913',
        nickname: 'Host A',
      );

      expect(room.providerId, 'fake');
      expect(room.roomCode, '482913');
      expect(room.participantId, 'host-a');
      expect(room.roomOwnerCredential, 'owner-proof-123');
      expect(room.session.state, MediaSessionState.connected);
      expect(factory.parsedPayloads.single['provider'], 'fake');
      expect(factory.parsedPayloads.single['role'], 'host');

      await room.dispose();
      expect(room.session.state, MediaSessionState.disposed);
      expect(
        transport.requestsTo('/rooms/482913/leave'),
        isNotEmpty,
        reason: 'dispose must send a best-effort leave',
      );
      client.dispose();
    });

    test('sends heartbeat while the room session is alive', () async {
      final client = clientFor(
        (_) => jsonResponse(
          liveKitJoinPayload(
            provider: 'fake',
            participantId: 'host-a',
            role: 'participant',
          ),
        ),
        heartbeatInterval: const Duration(milliseconds: 20),
      );

      final room = await client.createRoomAndJoin(nickname: 'Leo');
      await Future<void>.delayed(const Duration(milliseconds: 70));

      expect(
        transport.requestsTo('/rooms/482913/heartbeat').length,
        greaterThanOrEqualTo(2),
      );
      expect(transport.requestsTo('/rooms/482913/heartbeat').last.json, {
        'participantId': 'host-a',
      });

      await room.dispose();
      client.dispose();
    });

    test(
      'host close stops heartbeat and does not send a redundant leave',
      () async {
        final client = clientFor(
          (_) => jsonResponse(
            liveKitJoinPayload(
              provider: 'fake',
              participantId: 'host-a',
              role: 'host',
            ),
          ),
          heartbeatInterval: const Duration(milliseconds: 20),
        );

        final room = await client.createRoomAndJoin(
          nickname: 'Host',
          role: MediaRole.host,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        await room.closeRoom();
        final heartbeatCount = transport
            .requestsTo('/rooms/482913/heartbeat')
            .length;
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(transport.requestsTo('/rooms/482913/close'), hasLength(1));
        expect(
          transport.requestsTo('/rooms/482913/heartbeat').length,
          heartbeatCount,
        );
        expect(transport.requestsTo('/rooms/482913/leave'), isEmpty);
        expect(factory.createdSessions.single.leaveCount, 1);

        await room.dispose();
        expect(transport.requestsTo('/rooms/482913/leave'), isEmpty);
        client.dispose();
      },
    );

    test('room-not-found heartbeat stops polling and reports terminal end once', () async {
      var ended = false;
      final client = clientFor((request) {
        if (request.uri.path.endsWith('/heartbeat') && ended) {
          return MediaBackendTransportResponse(
            statusCode: 404,
            body: '{"error":{"code":"room-not-found"}}',
          );
        }
        return jsonResponse(liveKitJoinPayload(
          provider: 'fake',
          participantId: 'viewer-1',
          role: 'participant',
        ));
      }, heartbeatInterval: const Duration(milliseconds: 20));
      final room = await client.createRoomAndJoin(nickname: 'Viewer');
      final errors = <RealtimeException>[];
      final subscription = room.backendErrors.listen(errors.add);

      ended = true;
      await Future<void>.delayed(const Duration(milliseconds: 75));
      final heartbeats = transport.requestsTo('/rooms/482913/heartbeat').length;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(errors.where((e) => e.code == RealtimeErrorCode.roomNotFound), hasLength(1));
      expect(errors.single.operation, 'room.presence.heartbeat');
      expect(transport.requestsTo('/rooms/482913/heartbeat'), hasLength(heartbeats));
      expect(room.session.state, MediaSessionState.connected,
          reason: 'the host presentation owns final RTC disposal');
      await subscription.cancel();
      await room.dispose();
      client.dispose();
    });

    test('backend heartbeat failures do not stop healthy media', () async {
      var failHeartbeat = false;
      final client = clientFor((request) {
        if (request.uri.path.endsWith('/heartbeat') && failHeartbeat) {
          return MediaBackendTransportResponse(
            statusCode: 500,
            body: '{"error":{"code":"server-error","message":"boom"}}',
          );
        }
        return jsonResponse(
          liveKitJoinPayload(
            provider: 'fake',
            participantId: 'p1',
            role: 'participant',
          ),
        );
      }, heartbeatInterval: const Duration(milliseconds: 20));

      final room = await client.createRoomAndJoin(nickname: 'Leo');
      final errors = <RealtimeException>[];
      final subscription = room.backendErrors.listen(errors.add);

      failHeartbeat = true;
      await Future<void>.delayed(const Duration(milliseconds: 70));

      expect(errors, isNotEmpty);
      expect(errors.first.code, RealtimeErrorCode.serverError);
      expect(room.session.state, MediaSessionState.connected);

      await subscription.cancel();
      await room.dispose();
      client.dispose();
    });

    test('missing provider adapter fails before any media work', () async {
      final client = clientFor(
        (_) => jsonResponse(liveKitJoinPayload(provider: 'fake')),
        withRegistry: MediaRegistry(),
      );

      await expectLater(
        client.createRoomAndJoin(nickname: 'Leo'),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.providerNotRegistered,
          ),
        ),
      );
      expect(factory.createdSessions, isEmpty);
      client.dispose();
    });

    test('role the adapter rejects fails with unsupportedFeature', () async {
      final hostOnly = FakeMediaSessionFactory(
        supportedRoles: const {MediaRole.host},
      );
      final client = clientFor(
        (_) =>
            jsonResponse(liveKitJoinPayload(provider: 'fake', role: 'viewer')),
        withRegistry: MediaRegistry([hostOnly]),
      );

      await expectLater(
        client.createRoomAndJoin(role: MediaRole.viewer, nickname: 'Viewer'),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.unsupportedFeature,
          ),
        ),
      );
      client.dispose();
    });

    test('malformed join payload is reported as invalidJoinInfo', () async {
      final client = clientFor(
        (_) => jsonResponse({'provider': 'fake', 'roomCode': '482913'}),
      );

      await expectLater(
        client.createRoomAndJoin(nickname: 'Leo'),
        throwsA(
          isA<RealtimeException>().having(
            (error) => error.code,
            'code',
            RealtimeErrorCode.invalidArgument,
          ),
        ),
      );
      client.dispose();
    });

    test(
      'a failed join disposes the session and notifies the backend',
      () async {
        final joinError = RealtimeException(
          code: RealtimeErrorCode.permissionDenied,
          message: 'Camera denied.',
          providerId: 'fake',
        );
        final failing = FakeMediaSessionFactory(joinError: joinError);
        final client = clientFor(
          (_) => jsonResponse(
            liveKitJoinPayload(provider: 'fake', participantId: 'p1'),
          ),
          withRegistry: MediaRegistry([failing]),
        );

        await expectLater(
          client.createRoomAndJoin(nickname: 'Leo'),
          throwsA(
            isA<RealtimeException>().having(
              (e) => e.cause,
              'original failure',
              same(joinError),
            ),
          ),
        );

        expect(failing.createdSessions.single.disposeCount, greaterThan(0));
        expect(
          transport.requestsTo('/rooms/482913/leave'),
          isNotEmpty,
          reason: 'a failed join must still release the backend slot',
        );
        client.dispose();
      },
    );
  });

  group('joinRoom', () {
    test(
      'uses the room code from the response when the backend rewrites it',
      () async {
        final client = clientFor(
          (_) => jsonResponse(
            liveKitJoinPayload(
              provider: 'fake',
              roomCode: '999111',
              participantId: 'guest-1',
            ),
          ),
          heartbeatInterval: Duration.zero,
        );

        final room = await client.joinRoom(
          roomCode: '482913',
          nickname: 'Guest',
        );

        expect(room.roomCode, '999111');
        expect(transport.requests.single.uri.path, '/rooms/482913/join');
        await room.dispose();
        client.dispose();
      },
    );
  });
}
