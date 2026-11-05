import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, kIsWeb;
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';
import 'package:tencent_rtc_sdk/trtc_cloud.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_def.dart';
import 'package:tencent_rtc_sdk/trtc_cloud_listener.dart';
import 'package:tencent_rtc_sdk/tx_device_manager.dart';

import 'trtc_join_info.dart';

typedef TrtcEngineFactory = Future<TrtcEngine> Function();

/// Small internal boundary around the native SDK, also used by offline tests.
abstract interface class TrtcEngine {
  Future<int> enterRoom(TrtcJoinInfo joinInfo, TrtcEngineEvents events);

  Future<void> exitRoom();
  void startLocalAudio();
  void muteLocalAudio(bool muted);
  void muteLocalVideo(bool muted);
  void stopLocalPreview();
  void startLocalPreview(int viewId);
  void clearLocalView();
  void startRemoteView(String userId, int viewId);
  void stopRemoteView(String userId);
  void startRemoteSubStreamView(String userId, int viewId);
  void stopRemoteSubStreamView(String userId);
  void setRemoteFillMode(String userId, bool subStream, bool fit);
  int? remoteWidth(String userId, {required bool subStream});
  int? remoteHeight(String userId, {required bool subStream});
  void startScreenCapture();
  void stopScreenCapture();
  int switchCamera(bool frontCamera);
  bool sendCustomCmdMsg(int commandId, String data);
  Future<void> dispose();
}

/// Provider events translated from the native TRTC listener.
class TrtcEngineEvents {
  const TrtcEngineEvents({
    this.onError,
    this.onRemoteUserEnterRoom,
    this.onRemoteUserLeaveRoom,
    this.onUserVideoAvailable,
    this.onUserSubStreamAvailable,
    this.onUserAudioAvailable,
    this.onAudioLevels,
    this.onRecvCustomCmdMsg,
    this.onConnectionLost,
    this.onTryToReconnect,
    this.onConnectionRecovery,
    this.onStats,
  });

  final void Function(int code, String message)? onError;
  final void Function(String userId)? onRemoteUserEnterRoom;
  final void Function(String userId)? onRemoteUserLeaveRoom;
  final void Function(String userId, bool available)? onUserVideoAvailable;
  final void Function(String userId, bool available)? onUserSubStreamAvailable;
  final void Function(String userId, bool available)? onUserAudioAvailable;

  /// Per-user microphone volume, with the local participant identified by ''.
  final void Function(Map<String, int> volumes)? onAudioLevels;
  final void Function(String userId, int commandId, String data)?
  onRecvCustomCmdMsg;
  final void Function()? onConnectionLost;
  final void Function()? onTryToReconnect;
  final void Function()? onConnectionRecovery;
  final void Function(MediaConnectionStats stats)? onStats;
}

/// Factory used by production sessions.
Future<TrtcEngine> createNativeTrtcEngine() async => _NativeTrtcEngine();

class _NativeTrtcEngine implements TrtcEngine {
  TRTCCloud? _cloud;
  TRTCCloudListener? _listener;
  Completer<int>? _enterCompleter;
  Completer<void>? _exitCompleter;
  TrtcEngineEvents _events = const TrtcEngineEvents();
  bool _enterRequested = false;
  bool _registered = false;
  MediaConnectionStats? _connectionStats;
  TRTCStatistics? _lastStatistics;

  Future<TRTCCloud> _getCloud() async =>
      _cloud ??= await TRTCCloud.sharedInstance();

  TRTCCloudListener _createListener() => TRTCCloudListener(
    onEnterRoom: (result) {
      final completer = _enterCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete(result);
      }
    },
    onExitRoom: (_) {
      final completer = _exitCompleter;
      if (completer != null && !completer.isCompleted) completer.complete();
    },
    onError: (code, message) => _events.onError?.call(code, message),
    onRemoteUserEnterRoom: (userId) =>
        _events.onRemoteUserEnterRoom?.call(userId),
    onRemoteUserLeaveRoom: (userId, _) =>
        _events.onRemoteUserLeaveRoom?.call(userId),
    onUserVideoAvailable: (userId, available) =>
        _events.onUserVideoAvailable?.call(userId, available),
    onUserSubStreamAvailable: (userId, available) =>
        _events.onUserSubStreamAvailable?.call(userId, available),
    onUserAudioAvailable: (userId, available) =>
        _events.onUserAudioAvailable?.call(userId, available),
    onUserVoiceVolume: (volumes, _) => _events.onAudioLevels?.call({
      for (final info in volumes) info.userId: info.volume,
    }),
    onRecvCustomCmdMsg: (userId, commandId, _, data) =>
        _events.onRecvCustomCmdMsg?.call(userId, commandId, data),
    onConnectionLost: () => _events.onConnectionLost?.call(),
    onTryToReconnect: () => _events.onTryToReconnect?.call(),
    onConnectionRecovery: () => _events.onConnectionRecovery?.call(),
    onNetworkQuality: (localInfo, _) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final quality = _mapQuality(localInfo.quality);
      final next = (_connectionStats ?? MediaConnectionStats(timestampMs: now))
          .copyWith(
            timestampMs: now,
            upstreamQuality: quality,
            downstreamQuality: quality,
          );
      _connectionStats = next;
      _events.onStats?.call(next);
    },
    onStatistics: (statistics) {
      _lastStatistics = statistics;
      final now = DateTime.now().millisecondsSinceEpoch;
      final uploadKbps = statistics.localStatisticsArray?.fold<int>(
        0,
        (sum, value) =>
            sum +
            (value.audioBitrate > 0 ? value.audioBitrate : 0) +
            (value.videoBitrate > 0 ? value.videoBitrate : 0),
      );
      final downloadKbps = statistics.remoteStatisticsArray?.fold<int>(
        0,
        (sum, value) =>
            sum +
            (value.audioBitrate > 0 ? value.audioBitrate : 0) +
            (value.videoBitrate > 0 ? value.videoBitrate : 0),
      );
      final next = (_connectionStats ?? MediaConnectionStats(timestampMs: now))
          .copyWith(
            timestampMs: now,
            rttMs: statistics.rtt >= 0 ? statistics.rtt : null,
            uplinkPacketLossPercent: statistics.upLoss >= 0
                ? statistics.upLoss.toDouble()
                : null,
            downlinkPacketLossPercent: statistics.downLoss >= 0
                ? statistics.downLoss.toDouble()
                : null,
            uploadKbps: uploadKbps,
            downloadKbps: downloadKbps,
          );
      _connectionStats = next;
      _events.onStats?.call(next);
    },
  );

  MediaNetworkQuality _mapQuality(TRTCQuality quality) => switch (quality) {
    TRTCQuality.excellent => MediaNetworkQuality.excellent,
    TRTCQuality.good => MediaNetworkQuality.good,
    TRTCQuality.poor => MediaNetworkQuality.fair,
    TRTCQuality.bad => MediaNetworkQuality.poor,
    TRTCQuality.vBad => MediaNetworkQuality.bad,
    TRTCQuality.down => MediaNetworkQuality.down,
    _ => MediaNetworkQuality.unknown,
  };

  @override
  Future<int> enterRoom(TrtcJoinInfo joinInfo, TrtcEngineEvents events) async {
    final cloud = await _getCloud();
    _events = events;
    _listener ??= _createListener();
    if (!_registered) {
      cloud.registerListener(_listener!);
      _registered = true;
    }
    cloud.setDefaultStreamRecvMode(true, true);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      // iOS can switch from the loudspeaker to the quiet receiver when
      // microphone capture begins. TRTC owns its audio session; use its
      // device manager rather than mutating AVAudioSession in the host.
      final routeResult = cloud.getDeviceManager().setAudioRoute(
        TXAudioRoute.speakerPhone,
      );
      if (routeResult != 0) {
        // A routing failure must not prevent RTC room entry.
        // The audio route is also reported by the Demo's iOS diagnostics.
        // ignore: avoid_print
        print('[TRTC_IOS_AUDIO] speaker route failed: $routeResult');
      }
    }
    // Vendor documentation: enable volume callbacks before starting audio.
    // This also measures remote speakers when the local microphone is off.
    cloud.enableAudioVolumeEvaluation(
      true,
      TRTCAudioVolumeEvaluateParams(interval: 300),
    );
    final completer = Completer<int>();
    _enterCompleter = completer;
    _enterRequested = true;
    cloud.enterRoom(
      TRTCParams(
        sdkAppId: joinInfo.sdkAppId,
        userId: joinInfo.userId,
        userSig: joinInfo.userSig,
        roomId: 0,
        strRoomId: joinInfo.strRoomId,
        privateMapKey: joinInfo.privateMapKey,
        role: joinInfo.role == MediaRole.viewer
            ? TRTCRoleType.audience
            : TRTCRoleType.anchor,
      ),
      joinInfo.scene == TrtcRoomScene.videoCall
          ? TRTCAppScene.videoCall
          : TRTCAppScene.live,
    );
    try {
      return await completer.future.timeout(const Duration(seconds: 25));
    } finally {
      _enterCompleter = null;
    }
  }

  @override
  Future<void> exitRoom() async {
    final cloud = _cloud;
    if (cloud == null || !_enterRequested) return;
    final completer = Completer<void>();
    _exitCompleter = completer;
    try {
      cloud.exitRoom();
      await completer.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      // Permit cleanup and re-entry even when the SDK misses the exit callback.
    } finally {
      cloud.enableAudioVolumeEvaluation(
        false,
        TRTCAudioVolumeEvaluateParams(interval: 0),
      );
      _enterRequested = false;
      _exitCompleter = null;
    }
  }

  @override
  void startLocalAudio() {
    _cloud!.startLocalAudio(TRTCAudioQuality.defaultMode);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      final result = _cloud!.getDeviceManager().setAudioRoute(
        TXAudioRoute.speakerPhone,
      );
      if (result != 0) {
        // ignore: avoid_print
        print('[TRTC_IOS_AUDIO] speaker route after start failed: $result');
      }
    }
  }

  @override
  void muteLocalAudio(bool muted) => _cloud!.muteLocalAudio(muted);

  @override
  void muteLocalVideo(bool muted) =>
      _cloud!.muteLocalVideo(TRTCVideoStreamType.big, muted);

  @override
  void stopLocalPreview() => _cloud!.stopLocalPreview();

  @override
  void startLocalPreview(int viewId) {
    _cloud!.setLocalRenderParams(
      TRTCRenderParams(fillMode: TRTCVideoFillMode.fit),
    );
    _cloud!.startLocalPreview(true, viewId);
  }

  @override
  void clearLocalView() => _cloud?.updateLocalView(null);

  @override
  void startRemoteView(String userId, int viewId) {
    setRemoteFillMode(userId, false, true);
    _cloud!.startRemoteView(userId, TRTCVideoStreamType.big, viewId);
  }

  @override
  void stopRemoteView(String userId) =>
      _cloud?.stopRemoteView(userId, TRTCVideoStreamType.big);

  @override
  void startRemoteSubStreamView(String userId, int viewId) =>
      _cloud!.startRemoteView(userId, TRTCVideoStreamType.sub, viewId);

  @override
  void stopRemoteSubStreamView(String userId) =>
      _cloud?.stopRemoteView(userId, TRTCVideoStreamType.sub);

  @override
  void setRemoteFillMode(String userId, bool subStream, bool fit) =>
      _cloud?.setRemoteRenderParams(
        userId,
        subStream ? TRTCVideoStreamType.sub : TRTCVideoStreamType.big,
        TRTCRenderParams(
          fillMode: fit ? TRTCVideoFillMode.fit : TRTCVideoFillMode.fill,
        ),
      );

  @override
  int? remoteWidth(String userId, {required bool subStream}) => _remoteFrame(
    userId,
    subStream: subStream,
    select: (value) => value.width,
  );

  @override
  int? remoteHeight(String userId, {required bool subStream}) => _remoteFrame(
    userId,
    subStream: subStream,
    select: (value) => value.height,
  );

  int? _remoteFrame(
    String userId, {
    required bool subStream,
    required int Function(TRTCRemoteStatistics value) select,
  }) {
    final streamType = subStream
        ? TRTCVideoStreamType.sub
        : TRTCVideoStreamType.big;
    for (final entry
        in _lastStatistics?.remoteStatisticsArray ??
            const <TRTCRemoteStatistics>[]) {
      if (entry.userId != userId || entry.streamType != streamType) continue;
      final value = select(entry);
      if (value > 0) return value;
    }
    return null;
  }

  @override
  void startScreenCapture() {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows)) {
      // Desktop TRTC requires an explicit source selection before starting
      // the substream. The main display is the default for this first version;
      // source picking can later be provided via an optional SDK controller.
      final sources = _cloud!
          .getScreenCaptureSources(
            TRTCSize(width: 120, height: 72),
            TRTCSize(width: 24, height: 24),
          )
          ?.sourceList;
      if (sources == null || sources.isEmpty) {
        throw const RealtimeException(
          code: RealtimeErrorCode.unsupportedFeature,
          providerId: 'trtc',
          message:
              'TRTC cannot find a shareable desktop display. '
              'Check screen recording permissions and the native SDK.',
        );
      }
      final displays = sources.where(
        (source) => source.type == TRTCScreenCaptureSourceType.screen,
      );
      if (displays.isEmpty) {
        throw const RealtimeException(
          code: RealtimeErrorCode.unsupportedFeature,
          providerId: 'trtc',
          message: 'TRTC did not report any desktop display to share.',
        );
      }
      final preferred = displays.where((source) => source.isMainScreen);
      _cloud!.selectScreenCaptureTarget(
        preferred.isNotEmpty ? preferred.first : displays.first,
        TRTCRect(),
        TRTCScreenCaptureProperty(
          enableCaptureMouse: true,
          enableHighLight: false,
        ),
      );
    }
    final param = TRTCVideoEncParam(
      videoResolution: TRTCVideoResolution.res_1280_720,
      videoResolutionMode: TRTCVideoResolutionMode.landscape,
      videoBitrate: 1600,
      videoFps: 10,
      enableAdjustRes: false,
    );
    _cloud!.startScreenCapture(0, TRTCVideoStreamType.sub, param);
    _cloud!.setSubStreamEncoderParam(param);
  }

  @override
  void stopScreenCapture() => _cloud?.stopScreenCapture();

  @override
  int switchCamera(bool frontCamera) =>
      _cloud!.getDeviceManager().switchCamera(frontCamera);

  @override
  bool sendCustomCmdMsg(int commandId, String data) =>
      _cloud!.sendCustomCmdMsg(commandId, data, true, true);

  @override
  Future<void> dispose() async {
    await exitRoom();
    final cloud = _cloud;
    final listener = _listener;
    if (cloud != null && listener != null && _registered) {
      cloud.unRegisterListener(listener);
    }
    _cloud = null;
    _listener = null;
    _registered = false;
    if (cloud != null) TRTCCloud.destroySharedInstance();
  }
}
