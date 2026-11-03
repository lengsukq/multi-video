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
