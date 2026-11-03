/// Capture and publish a screen track as one transaction.
///
/// A failed publication must stop the locally captured track; otherwise
/// ReplayKit can continue recording after the SDK reports a failed share.
Future<T> captureAndPublishIosInAppScreen<T>({
  required Future<T> Function() capture,
  required Future<void> Function(T track) publish,
  required Future<void> Function(T track) release,
}) async {
  final track = await capture();
  try {
    await publish(track);
  } catch (_) {
    try {
      await release(track);
    } catch (_) {
      // Preserve the initial failure rather than masking it with cleanup.
    }
    rethrow;
  }
  return track;
}
