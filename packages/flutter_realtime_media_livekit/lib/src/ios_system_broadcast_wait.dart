import 'dart:async';

/// User did not start the ReplayKit broadcast from Apple's picker.
class IosBroadcastNotStarted implements Exception {
  const IosBroadcastNotStarted();
}

/// ReplayKit started, but LiveKit never published its screen video track.
class IosBroadcastTrackMissing implements Exception {
  const IosBroadcastTrackMissing();
}

/// The picker is asynchronous: requesting it is NOT a successful screen share.
/// The extension's Darwin notification causes LiveKit to publish the track.
/// Commit shared-content mode only after the track really exists.
Future<void> awaitIosSystemBroadcastPublication({
  required Future<void> Function() requestActivation,
  required bool Function() broadcasting,
  required bool Function() published,
  required bool Function() sessionClosed,
  Duration timeout = const Duration(seconds: 45),
  Duration pollInterval = const Duration(milliseconds: 150),
}) async {
  if (sessionClosed()) throw StateError('Room closed before screen capture.');
  if (published()) return;
  await requestActivation();
  final deadline = DateTime.now().add(timeout);
  while (!published()) {
    if (sessionClosed()) {
      throw StateError('Room closed while starting screen capture.');
    }
    if (!DateTime.now().isBefore(deadline)) {
      if (!broadcasting()) throw const IosBroadcastNotStarted();
      throw const IosBroadcastTrackMissing();
    }
    await Future<void>.delayed(pollInterval);
  }
}
