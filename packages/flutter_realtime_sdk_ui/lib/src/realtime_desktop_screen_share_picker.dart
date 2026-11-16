import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';

import 'room_ui_controller.dart';

/// Returns false if the user dismisses the picker. The RTC adapter, not the
/// UI, owns capture and validates that the chosen source still exists.
Future<bool> selectDesktopScreenShareSource(
  BuildContext context,
  RealtimeRoomUiController controller,
) async {
  final isDesktop = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);
  if (!isDesktop || !controller.canSelectScreenShareSource ||
      controller.snapshot.localScreenShareEnabled) {
    return true;
  }
  final sources = await controller.listScreenShareSources();
  if (sources.isEmpty) {
    throw const RealtimeException(
      code: RealtimeErrorCode.unsupportedFeature,
      message: 'No shareable screen or window was found on this computer.',
      operation: 'screenShare.listSources',
    );
  }
  if (!context.mounted) return false;
  final selected = await showDesktopScreenSharePicker(context, sources);
  if (selected == null) return false;
  await controller.selectScreenShareSource(selected);
  return true;
}

/// The UI selection surface is separately testable without RTC credentials
/// or a real Windows desktop capture session.
Future<MediaScreenShareSource?> showDesktopScreenSharePicker(
  BuildContext context,
  List<MediaScreenShareSource> sources,
) {
  final isZh = Localizations.localeOf(context).languageCode == 'zh';
  return showDialog<MediaScreenShareSource>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(isZh ? '选择要共享的屏幕或窗口' : 'Choose a screen or window'),
      content: SizedBox(
        width: 460,
        height: sources.length > 6 ? 385 : sources.length * 57.0 + 8,
        child: ListView.builder(
          itemCount: sources.length,
          itemBuilder: (_, index) {
            final source = sources[index];
            return ListTile(
              leading: Icon(source.kind == MediaScreenShareSourceKind.window
                  ? Icons.web_asset_rounded
                  : Icons.monitor_rounded),
              title: Text(source.name, maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              subtitle: Text(source.kind == MediaScreenShareSourceKind.window
                  ? (isZh ? '应用窗口' : 'Application window')
                  : (isZh ? '完整屏幕' : 'Entire display')),
              onTap: () => Navigator.of(dialogContext).pop(source),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(isZh ? '取消' : 'Cancel'),
        ),
      ],
    ),
  );
}

Future<void> toggleScreenShareWithPicker(
  BuildContext context,
  RealtimeRoomUiController controller,
) async {
  if (!await selectDesktopScreenShareSource(context, controller)) return;
  await controller.toggleScreenShare();
}
