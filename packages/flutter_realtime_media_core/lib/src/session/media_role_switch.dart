import '../model/media_role.dart';
import 'media_join_info.dart';
import 'media_session.dart';

/// Fetches fresh provider join credentials for an authorized role transition.
typedef MediaRoleChangeCallback =
    Future<MediaJoinInfo> Function(MediaRole targetRole);

/// Optional capability for sessions that support live role transitions (such as
/// promoting a livestream viewer to co-host or returning to viewer).
abstract interface class MediaRoleSwitchable {
  void setRoleChangeCallback(MediaRoleChangeCallback? callback);

  /// Switches the active participant role and returns the active [MediaSession]
  /// matching the updated role (e.g. [InteractiveMediaSession] vs
  /// [BroadcastViewerSession]).
  Future<MediaSession> switchRole(MediaRole targetRole);
}

/// Acquires or revokes an auxiliary publishing token (e.g. a secondary `#content`
/// screen-share stream on single-track-per-token stages such as AWS IVS).
typedef MediaAuxiliaryTokenCallback =
    Future<Map<String, dynamic>> Function({required String action});

/// Optional capability for sessions that consume an auxiliary screen-share token.
abstract interface class MediaAuxiliaryTokenConsumer {
  void setAuxiliaryTokenCallback(MediaAuxiliaryTokenCallback? callback);
}
