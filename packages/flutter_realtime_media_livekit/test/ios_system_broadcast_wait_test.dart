import 'dart:async';

import 'package:flutter_realtime_media_livekit/src/ios_system_broadcast_wait.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const tick = Duration(milliseconds: 1);
  const shortTimeout = Duration(milliseconds: 25);

  test(
    'requesting picker alone is not treated as successful capture',
    () async {
      var activated = 0;
      await expectLater(
        awaitIosSystemBroadcastPublication(
          requestActivation: () async => activated++,
          broadcasting: () => false,
          published: () => false,
          sessionClosed: () => false,
          timeout: shortTimeout,
          pollInterval: tick,
        ),
        throwsA(isA<IosBroadcastNotStarted>()),
      );
      expect(activated, 1);
    },
  );

  test(
    'broadcast started but no actual video track remains an error',
    () async {
      await expectLater(
        awaitIosSystemBroadcastPublication(
          requestActivation: () async {},
          broadcasting: () => true,
          published: () => false,
          sessionClosed: () => false,
          timeout: shortTimeout,
          pollInterval: tick,
        ),
        throwsA(isA<IosBroadcastTrackMissing>()),
      );
    },
  );

  test(
    'success waits for the screen video publication after broadcast',
    () async {
      var broadcasting = false;
      var published = false;
      final result = awaitIosSystemBroadcastPublication(
        requestActivation: () async {
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              broadcasting = true;
              published = true;
            }),
          );
        },
        broadcasting: () => broadcasting,
        published: () => published,
        sessionClosed: () => false,
        timeout: const Duration(seconds: 1),
        pollInterval: tick,
      );
      expect(published, isFalse);
      await result;
      expect(published, isTrue);
    },
  );

  test('an existing published track needs no extra picker', () async {
    var activated = false;
    await awaitIosSystemBroadcastPublication(
      requestActivation: () async => activated = true,
      broadcasting: () => true,
      published: () => true,
      sessionClosed: () => false,
      timeout: shortTimeout,
      pollInterval: tick,
    );
    expect(activated, isFalse);
  });

  test('room closure aborts the pending broadcast picker promptly', () async {
    var closed = false;
    await expectLater(
      awaitIosSystemBroadcastPublication(
        requestActivation: () async => closed = true,
        broadcasting: () => false,
        published: () => false,
        sessionClosed: () => closed,
        timeout: const Duration(seconds: 1),
        pollInterval: tick,
      ),
      throwsA(isA<StateError>()),
    );
  });
}
