import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_realtime_chat_ivs/src/ivs_chat_engine_windows.dart';
import 'package:flutter_realtime_chat_ivs/flutter_realtime_chat_ivs.dart';
import 'package:flutter_test/flutter_test.dart';

IvsChatJoinInfo _joinInfo({String token = 'one-use-token'}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return IvsChatJoinInfo.fromJson({
    'chatProvider': 'ivs-chat',
    'roomCode': 'room-1',
    'participantId': 'participant-1',
    'userId': 'logical-user',
    'displayName': 'Local User',
    'role': 'host',
    'chat': {
      'roomArn': 'arn:aws:ivschat:us-west-2:123456789012:room/room-1',
      'token': token,
      'region': 'us-west-2',
      'capabilities': [
        'SEND_MESSAGE', 'DELETE_MESSAGE', 'DISCONNECT_USER',
      ],
      'tokenExpirationTimeMs': now + 60000,
      'sessionExpirationTimeMs': now + 3600000,
    },
  });
}

void main() {
  test('Windows IVS Chat endpoint rejects invalid regions', () {
    expect(WindowsIvsChatEngine.endpointForRegion('us-west-2').toString(),
        'wss://edge.ivschat.us-west-2.amazonaws.com');
    expect(() => WindowsIvsChatEngine.endpointForRegion('us-west-2/evil'),
        throwsArgumentError);
  });

  test('Windows IVS native socket sends, receives and moderates messages', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    addTearDown(() async {
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });
    final wireActions = <String>[];
    final serverListener = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: (protocols) => protocols.first,
      );
      sockets.add(socket);
      socket.listen((dynamic data) {
        final incoming = Map<String, dynamic>.from(jsonDecode(data as String) as Map);
        final action = incoming['Action'] as String;
        wireActions.add(action);
        final requestId = incoming['RequestId'];
        final reply = switch (action) {
          'SEND_MESSAGE' => {
            'Type': 'MESSAGE',
            'Id': 'server-1',
            'RequestId': requestId,
            'Sender': {
              'UserId': 'provider-user',
              'Attributes': incoming['Attributes'],
            },
            'Content': incoming['Content'],
            'SendTime': '2026-11-12T01:00:00Z',
          },
          'DELETE_MESSAGE' => {
            'Type': 'EVENT',
            'EventName': 'DELETE_MESSAGE',
            'RequestId': requestId,
            'Attributes': {'MessageID': incoming['Id']},
          },
          'DISCONNECT_USER' => {
            'Type': 'EVENT',
            'EventName': 'DISCONNECT_USER',
            'RequestId': requestId,
            'Attributes': {'UserId': incoming['UserId']},
          },
          _ => <String, Object?>{},
        };
        socket.add(jsonEncode(reply));
      });
    });
    addTearDown(serverListener.cancel);

    final tokens = <String>[];
    final events = <String>[];
    final engine = WindowsIvsChatEngine(
      connector: (url, token) {
        expect(url.host, 'edge.ivschat.us-west-2.amazonaws.com');
        tokens.add(token);
        return WebSocket.connect(
          'ws://127.0.0.1:${server.port}',
          protocols: [token],
        );
      },
    );
    addTearDown(engine.dispose);
    await engine.connect(
      _joinInfo(),
      IvsChatEngineEvents(
        onConnected: () => events.add('connected'),
        onMessage: (msg) => events.add('message:${msg['id']}:${msg['message']}'),
        onMessageDeleted: (id) => events.add('deleted:$id'),
        onUserDisconnected: (id) => events.add('removed:$id'),
      ),
    );
    await engine.sendMessage('hello from windows');
    await engine.deleteMessage('server-1');
    await engine.disconnectUser('bad-user');
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(tokens, ['one-use-token']);
    expect(wireActions, [
      'SEND_MESSAGE', 'DELETE_MESSAGE', 'DISCONNECT_USER',
    ]);
    expect(events, containsAll([
      'connected',
      'message:server-1:hello from windows',
      'deleted:server-1',
      'removed:bad-user',
    ]));
    await engine.disconnect();
    await expectLater(engine.sendMessage('after disconnect'), throwsStateError);
  });

  test('Windows IVS reconnects with a fresh token, not a reused token', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final sockets = <WebSocket>[];
    final listen = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request,
          protocolSelector: (protocols) => protocols.first);
      sockets.add(socket);
    });
    addTearDown(listen.cancel);
    final tokens = <String>[];
    final secondConnection = Completer<void>();
    final engine = WindowsIvsChatEngine(
      connector: (endpoint, token) {
        tokens.add(token);
        return WebSocket.connect(
          'ws://127.0.0.1:${server.port}', protocols: [token]);
      },
    );
    addTearDown(engine.dispose);
    await engine.connect(
      _joinInfo(),
      IvsChatEngineEvents(onConnected: () {
        if (tokens.length == 2 && !secondConnection.isCompleted) {
          secondConnection.complete();
        }
      }),
      tokenProvider: () async => _joinInfo(token: 'fresh-second-token'),
    );
    // WebSocket.connect may complete just before the server's upgrade
    // callback records the accepted socket.
    for (var i = 0; i < 20 && sockets.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(sockets, hasLength(1));
    await sockets.first.close();
    await secondConnection.future.timeout(const Duration(seconds: 8));
    expect(tokens, ['one-use-token', 'fresh-second-token']);
    await engine.disconnect();
  });
}
