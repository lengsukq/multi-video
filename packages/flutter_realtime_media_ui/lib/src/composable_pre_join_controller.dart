import 'realtime_pre_join_state.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

import 'pre_join_media_setup_controller.dart';
import 'pre_join_permission_coordinator.dart';
import 'pre_join_preview_owner.dart';

typedef RealtimePreJoinCheck = Future<MediaPreJoinResult> Function();
typedef RealtimePreJoinOpenPreview =
    Future<MediaLocalPreviewSession?> Function(
      String providerId,
      MediaRole role,
    );

/// Owns Pre-Join state and camera/microphone preview, independent of layout.
///
/// The app owns the route, navigation and confirmation. Failed entry restores
/// preview on the same screen; async work is invalidated on retry/dispose.
class RealtimePreJoinController extends ChangeNotifier {
  RealtimePreJoinController({
    required this.runCheck,
    required this.openPreview,
    this.onError,
    MediaPermissionRequester permissionRequester =
        const DefaultMediaPermissionProbe(),
  }) : _permissions = PreJoinPermissionCoordinator(permissionRequester);

  final RealtimePreJoinCheck runCheck;
  final RealtimePreJoinOpenPreview openPreview;
  final void Function(RealtimeException error)? onError;
  final List<RealtimeException> _diagnostics = [];
  List<RealtimeException> get diagnostics => List.unmodifiable(_diagnostics);
  final PreJoinPermissionCoordinator _permissions;
  final _owner = PreJoinPreviewOwner();
  final _setup = PreJoinMediaSetupController();

  MediaPreJoinResult? _result;
  Map<MediaPermissionKind, MediaPermissionState> _permissionStates = const {};
  RealtimeException? _error;
  RealtimeException? _previewError;
  RealtimeException? _joinError;
  MediaLocalPreviewSettings? _retrySettings;
  RealtimePreJoinState _state = const RealtimePreJoinIdle();
  RealtimePreJoinState get state => _state;
  bool get _loading => _state is RealtimePreJoinChecking;
  bool get _joining => _state is RealtimePreJoinEntering;
  bool get cancelling => _state is RealtimePreJoinCancelling;
  bool _disposed = false;
  int _generation = 0;

  MediaPreJoinResult? get result => _result;
  MediaLocalPreviewSession? get preview => _owner.session;
  Map<MediaPermissionKind, MediaPermissionState> get permissions =>
      Map.unmodifiable(_permissionStates);
  List<MediaDevice> get devices => _setup.devices;
  MediaBackgroundEffect get backgroundEffect => _setup.backgroundEffect;
  RealtimeException? get error => _error;
  Object? get previewError => _previewError ?? _setup.deviceError;
  RealtimeException? get joinError => _joinError;
  bool get loading => _loading;
  bool get joining => _joining;
  bool get busy => _loading || _joining || cancelling;
  bool get canEnter => !_disposed && !busy && _result?.isReady == true;
  bool get updatingBackground => _setup.updatingBackground;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _valid(int generation) => !_disposed && generation == _generation;

  Future<void> initialize() async {
    if (_disposed || _joining) return;
    final generation = ++_generation;
    _state = const RealtimePreJoinChecking();
    _result = null;
    _error = _previewError = _joinError = null;
    _retrySettings = null;
    _setup.resetDevices();
    _permissionStates = const {};
    _notify();
    try {
      await _owner.release();
      if (!_valid(generation)) return;
      final check = await runCheck();
      if (!_valid(generation)) return;
      final statuses = await _permissions.readStatuses();
      if (!_valid(generation)) return;
      _result = _withPermissionStates(check, statuses);
      _setup.applyCapabilities(check.backgroundCapabilities);
      _permissionStates = statuses;
      _notify();
      await _openLocalPreview(check, generation);
    } catch (error, stack) {
      final failure = _recordFailure(error, stack);
      if (_valid(generation)) _error = failure;
    } finally {
      if (_valid(generation)) {
        _state = _error == null
            ? const RealtimePreJoinReady()
            : RealtimePreJoinFailed(_error!);
        _notify();
      }
    }
  }

  Future<void> _openLocalPreview(
    MediaPreJoinResult check,
    int generation,
  ) async {
    if (check.role == MediaRole.viewer || check.providerId == null) return;
    try {
      final preview = await openPreview(check.providerId!, check.role);
      if (!_valid(generation)) {
        await preview?.dispose();
        return;
      }
      _owner.bind(
        preview,
        onFailure: (error) {
          final failure = _recordFailure(error, StackTrace.current);
          if (!_valid(generation)) return;
          _previewError = failure;
          _notify();
        },
      );
      if (preview != null) {
        if (preview.settings.microphoneEnabled) {
          await preview.setMicrophoneEnabled(false);
        }
        if (preview.settings.cameraEnabled) {
          await preview.setCameraEnabled(false);
        }
      }
      if (!_valid(generation)) return;
      await _setup.loadDevices(preview);
      if (_valid(generation)) _notify();
    } catch (error, stack) {
      final failure = _recordFailure(error, stack);
      if (_valid(generation)) {
        _previewError = failure;
        _notify();
      }
    }
  }

  Future<void> retryPreview() async {
    if (_disposed || busy || _result == null) return;
    final generation = ++_generation;
    _previewError = null;
    _setup.resetDevices();
    _notify();
    await _owner.release();
    if (_valid(generation)) await _openLocalPreview(_result!, generation);
  }

  Future<void> refreshPermissions() async {
    final generation = _generation;
    final permissions = await _permissions.readStatuses();
    if (_valid(generation)) {
      _permissionStates = permissions;
      if (_result case final result?) {
        _result = _withPermissionStates(result, permissions);
      }
      _notify();
    }
  }

  Future<void> requestPermission(MediaPermissionKind kind) async {
    if (_disposed || busy) return;
    final generation = _generation;
    try {
      final status = await _permissions.request(kind);
      if (!_valid(generation)) return;
      _permissionStates = {..._permissionStates, kind: status};
      if (_result case final result?) {
        _result = _withPermissionStates(result, _permissionStates);
      }
      _notify();
      if (kind == MediaPermissionKind.camera &&
          status == MediaPermissionState.granted &&
          preview == null) {
        await retryPreview();
      }
    } catch (error, stack) {
      final failure = _recordFailure(error, stack);
      if (_valid(generation)) {
        _previewError = failure;
        _notify();
      }
    }
  }

  /// When a switch is tapped, permission granting should immediately turn on
  /// the requested capture track without requiring a second click.
  Future<void> requestPermissionAndEnable(MediaPermissionKind kind) async {
    await requestPermission(kind);
    if (_disposed || busy) return;
    final permission = _permissionStates[kind];
    if (permission != MediaPermissionState.granted &&
        permission != MediaPermissionState.unknown) {
      return;
    }
    if (preview == null) await retryPreview();
    // Some iOS SPM hosts cannot query permission_handler status although the
    // underlying AVFoundation capture can still request/confirm permission.
    // Allow that native capture to decide; failure remains visible to the UI.
    if (kind == MediaPermissionKind.microphone) {
      await setMicrophoneEnabled(true);
    } else {
      await setCameraEnabled(true);
    }
  }

  bool get canOpenAppSettings => _permissions.canOpenAppSettings;
  Future<bool> openAppSettings() async {
    try {
      return await _permissions.openAppSettings();
    } catch (error, stack) {
      _recordFailure(error, stack);
      return false;
    }
  }

  RealtimeException _recordFailure(Object error, StackTrace stack) {
    final failure = normalizeRealtimeException(
      error,
      domain: 'media.prejoin',
      stackTrace: stack,
    );
    if (_diagnostics.length == 32) _diagnostics.removeAt(0);
    _diagnostics.add(failure);
    onError?.call(failure);
    return failure;
  }

  Future<bool> cancel() async {
    if (_disposed || _joining || cancelling) return false;
    ++_generation;
    _state = const RealtimePreJoinCancelling();
    _notify();
    try {
      await _owner.release();
      if (!_disposed) {
        _state = const RealtimePreJoinIdle();
        _notify();
      }
      return true;
    } catch (error, stack) {
      final failure = _recordFailure(error, stack);
      if (!_disposed) {
        _error = failure;
        _state = RealtimePreJoinFailed(failure);
        _notify();
      }
      return false;
    }
  }

  MediaPreJoinResult _withPermissionStates(
    MediaPreJoinResult result,
    Map<MediaPermissionKind, MediaPermissionState> states,
  ) {
    MediaPreJoinStatus permissionStatus(MediaPermissionState? permission) =>
        switch (permission) {
          MediaPermissionState.granted => MediaPreJoinStatus.passed,
          MediaPermissionState.denied ||
          MediaPermissionState.permanentlyDenied ||
          MediaPermissionState.restricted => MediaPreJoinStatus.failed,
          MediaPermissionState.unsupported => MediaPreJoinStatus.unsupported,
          _ => MediaPreJoinStatus.unknown,
        };
    return MediaPreJoinResult(
      role: result.role,
      providerId: result.providerId,
      meetingMode: result.meetingMode,
      backgroundCapabilities: result.backgroundCapabilities,
      checks: [
        for (final check in result.checks)
          if (check.type == MediaPreJoinCheckType.microphonePermission ||
              check.type == MediaPreJoinCheckType.cameraPermission)
            MediaPreJoinCheck(
              type: check.type,
              status: permissionStatus(
                states[check.type == MediaPreJoinCheckType.microphonePermission
                    ? MediaPermissionKind.microphone
                    : MediaPermissionKind.camera],
              ),
              severity: check.severity,
              message: check.message,
              details: check.details,
            )
          else
            check,
      ],
    );
  }

  Future<void> setMicrophoneEnabled(bool enabled) async {
    final preview = this.preview;
    if (preview == null || busy) return;
    try {
      await preview.setMicrophoneEnabled(enabled);
      _retrySettings = null;
      _previewError = null;
    } catch (error, stack) {
      final failure = _recordFailure(error, stack);
      _previewError = failure;
    }
    _notify();
  }

  Future<void> setCameraEnabled(bool enabled) async {
    final preview = this.preview;
    if (preview == null || busy) return;
    try {
      await preview.setCameraEnabled(enabled);
      _retrySettings = null;
      _previewError = null;
    } catch (error, stack) {
      final failure = _recordFailure(error, stack);
      _previewError = failure;
    }
    _notify();
  }

  Future<void> selectDevice(MediaDevice device) async {
    final preview = this.preview;
    if (preview == null || busy) return;
    if (await _setup.selectDevice(preview, device)) _retrySettings = null;
    _notify();
  }

  Future<void> setBackgroundEffect(MediaBackgroundEffect effect) async {
    if (_disposed || busy || _setup.updatingBackground) return;
    final update = _setup.applyBackground(preview, effect);
    _notify();
    try {
      await update;
      _retrySettings = null;
      _previewError = null;
    } catch (error, stack) {
      final failure = _recordFailure(error, stack);
      _previewError = failure;
    }
    _notify();
  }

  /// Releases preview before joining; a failure re-opens capture for retry.
  /// A successful entry is responsible for route navigation outside this class.
  Future<void> enter(
    Future<void> Function(MediaLocalPreviewSettings settings) onEnter,
  ) async {
    if (!canEnter) return;
    final generation = ++_generation;
    final selected =
        (_retrySettings ??
                preview?.settings ??
                const MediaLocalPreviewSettings())
            .copyWith(backgroundEffect: _setup.backgroundEffect);
    _retrySettings = selected;
    _state = const RealtimePreJoinEntering();
    _joinError = null;
    _notify();
    try {
      await _owner.release();
      if (!_valid(generation)) return;
      await onEnter(selected);
    } catch (error, stack) {
      final failure = _recordFailure(error, stack);
      if (!_valid(generation)) return;
      _joinError = failure;
      // Preserve settings for a retry even when reopening preview fails.
      if (_result != null) await _openLocalPreview(_result!, generation);
    } finally {
      if (_valid(generation)) {
        _state = const RealtimePreJoinReady();
        _notify();
      }
    }
  }

  Future<void>? _closing;
  Future<void> close() {
    dispose();
    return _closing!;
  }

  @override
  void dispose() {
    if (_disposed) return;
    ++_generation;
    _disposed = true;
    _setup.dispose();
    _closing = _owner.dispose();
    observeDetached(
      _closing!,
      onFailure: (error) =>
          _recordFailure(error, error.stackTrace ?? StackTrace.current),
    );
    super.dispose();
  }
}
