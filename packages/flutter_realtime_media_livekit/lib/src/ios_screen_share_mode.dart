/// How LiveKit captures screen video on an iPhone.
enum IosScreenShareMode {
  /// Share the entire display, including Safari and other apps.
  /// Requires a signed ReplayKit Broadcast Upload Extension + App Group.
  system,

  /// Capture only the Flutter host app (not other apps).
  application,
}
