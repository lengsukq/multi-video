/// Provider-neutral Flutter SDK core for realtime audio/video sessions.
///
/// This package contains no provider SDK dependency and does not require the
/// repository demo backend. Add an adapter package
/// (`flutter_realtime_media_livekit`, and later Chime/Agora/TRTC/...)
/// and register its `MediaSessionFactory` in a `MediaRegistry`.
library;

export 'src/client/media_backend_client.dart';
export 'src/client/media_backend_config.dart';
export 'src/client/media_backend_error.dart';
export 'src/client/media_backend_transport.dart';
export 'src/client/media_backend_transport_factory.dart';
export 'src/client/media_client.dart';
export 'src/client/media_room_services.dart';
export 'src/diagnostics/media_doctor.dart';
export 'src/diagnostics/media_permission_probe.dart';
export 'src/diagnostics/media_pre_join.dart';
export 'src/diagnostics/media_pre_join_probe.dart';
export 'src/model/media_audio_device.dart';
export 'src/model/media_background_effect.dart';
export 'src/model/media_capabilities.dart';
export 'src/model/media_connection_stats.dart';
export 'src/model/media_device.dart';
export 'src/model/media_error.dart';
export 'src/model/media_feature.dart';
export 'src/model/media_identity.dart';
export 'src/model/media_management_capability.dart';
export 'src/model/media_event.dart';
export 'src/model/media_message.dart';
export 'src/model/media_participant.dart';
export 'src/model/media_role.dart';
export 'src/model/media_room_mode.dart';
export 'src/model/media_meeting_mode.dart';
export 'src/model/media_room_participant_summary.dart';
export 'src/model/media_room_summary.dart';
export 'src/model/media_recovery_status.dart';
export 'src/model/media_send_options.dart';
export 'src/model/media_snapshot.dart';
export 'src/model/media_state.dart';
export 'src/model/media_track.dart';
export 'src/recording/cloud_recording_blueprints.dart';
export 'src/recording/cloud_recording_descriptor.dart';
export 'src/recording/media_recording_controller.dart';
export 'src/recording/media_cloud_recording_session.dart';
export 'src/recording/recording_options.dart';
export 'src/session/broadcast_sessions.dart';
export 'src/session/media_background_effects_controller.dart';
export 'src/session/media_credential_refresh.dart';
export 'src/session/interactive_media_session.dart';
export 'src/session/media_device_controller.dart';
export 'src/session/media_local_preview.dart';
export 'src/session/media_audio_engine_diagnostics.dart';
export 'src/session/media_microphone_signal_levels.dart';
export 'src/session/macos_microphone_levels.dart';
export 'src/session/media_data_controller.dart';
export 'src/session/media_stats_provider.dart';
export 'src/session/media_join_info.dart';
export 'src/session/media_room_session.dart';
export 'src/session/media_room_extensions.dart';
export 'src/session/media_session.dart';
export 'src/session/media_session_factory.dart';
export 'src/view/media_track_view.dart';

export 'package:flutter_realtime_foundation/flutter_realtime_foundation.dart';
export 'src/processed/processed_video_source.dart';
export 'src/processed/processed_video_sink.dart';
export 'src/processed/processed_video_track.dart';
export 'src/processed/processed_video_camera_device.dart';
