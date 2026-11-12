import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_realtime_media_ui/flutter_realtime_media_ui.dart';
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

void main() {
  const strings = RealtimeStrings.zh();

  RealtimeException wrapped(RealtimeException cause) => RealtimeException(
    code: RealtimeErrorCode.invalidState,
    message: 'sharedContent.commitAfterCaptureStop',
    cause: cause,
  );

  test('expired meeting reports recreate action instead of internal key', () {
    final text = strings.displayRealtimeError(
      wrapped(
        const RealtimeException(
          code: RealtimeErrorCode.roomNotFound,
          message: 'Backend request failed (HTTP 404).',
          statusCode: 404,
        ),
      ),
    );
    expect(text, contains('会议已失效'));
    expect(text, isNot(contains('sharedContent.')));
  });

  test('simultaneous share rejection tells users to wait for the presenter',
      () {
    final message = strings.displayRealtimeError(
      const RealtimeException(
        code: RealtimeErrorCode.roomConflict,
        domain: 'sharedContent',
        message: 'Another participant is already sharing their screen.',
        suggestedAction: 'wait-for-screen-sharing-to-end',
      ),
    );
    expect(message, contains('其他成员'));
    expect(message, contains('结束'));
  });

  test('screen capture permission denial never claims camera/mic is missing',
      () {
    final message = strings.displayRealtimeError(
      const RealtimeException(
        code: RealtimeErrorCode.permissionDenied,
        operation: 'screenShare',
        message: 'Screen-capture permission was denied.',
      ),
    );
    expect(message, contains('屏幕'));
    expect(message, isNot(contains('麦克风')));
  });

  test('camera permission errors show an authorization action', () {
    final message = strings.displayRealtimeError(
      const RealtimeException(
        code: RealtimeErrorCode.permissionDenied,
        operation: 'camera',
        message: 'Camera access denied',
      ),
    );
    expect(message, contains('权限'));
    expect(message, contains('音视频'));
  });

  test('forbidden and conflict have actionable localized explanations', () {
    expect(
      strings.displayRealtimeError(
        wrapped(
          const RealtimeException(
            code: RealtimeErrorCode.forbidden,
            message: 'Forbidden',
            statusCode: 403,
          ),
        ),
      ),
      contains('权限'),
    );
    expect(
      strings.displayRealtimeError(
        wrapped(
          const RealtimeException(
            code: RealtimeErrorCode.roomConflict,
            message: 'Conflict',
            statusCode: 409,
          ),
        ),
      ),
      contains('重试'),
    );
  });

  test(
    'unclassified shared content failures never print implementation keys',
    () {
      expect(
        strings.displayRealtimeError(
          const RealtimeException(
            code: RealtimeErrorCode.invalidState,
            message: 'sharedContent.commitAfterCaptureStop',
          ),
        ),
        contains('切换白板'),
      );
    },
  );
}
