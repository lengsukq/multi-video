import 'dart:convert';

import 'package:flutter_realtime_classroom_preset/flutter_realtime_classroom_preset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Web classroom commands generate valid unique event IDs', () async {
    final ids = <String>[];
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/rooms/class-1/classroom/action');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['requesterParticipantId'], 'participant-1');
      expect(body['participantCredential'], 'test-credential');
      expect(body['action'], 'tool.content.mode');
      final id = body['eventId'] as String;
      expect(id, matches(RegExp(r'^[a-zA-Z0-9_-]{8,128}$')));
      ids.add(id);
      return http.Response(
        jsonEncode({
          'roomCode': 'class-1',
          'role': 'teacher',
          'revision': ids.length,
          'students': <Object>[],
          'questions': <Object>[],
          'stats': <String, Object>{},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final repo = HttpClassroomRepository(
      backendUrl: 'https://api.example.invalid',
      roomCode: 'class-1',
      participantId: 'participant-1',
      participantCredential: 'test-credential',
      client: client,
    );
    addTearDown(repo.close);
    for (var i = 0; i < 5; i++) {
      final state = await repo.action(
        ClassroomCommand.tool(ClassroomToolAction.contentMode, {
          'mode': 'whiteboard',
          'expectedRevision': i,
        }),
      );
      expect(state.revision, i + 1);
    }
    expect(ids, hasLength(5));
    expect(ids.toSet(), hasLength(5));
  });
}
