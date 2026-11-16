part of '../flutter_realtime_design_ui.dart';

/// Presents an SDK modal sheet with a drag handle and host appearance overrides.
Future<T?> showRealtimeGlassBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: isScrollControlled,
  backgroundColor: Colors.transparent,
  barrierColor:
      (Theme.of(context).brightness == Brightness.dark
              ? Colors.black
              : const Color(0xFF1D1D1F))
          .withValues(alpha: 0.40),
  elevation: 0,
  builder: (sheetContext) => _RealtimeModalTheme(
    builder: (sheetContext) {
      final style = RealtimeStyle.of(sheetContext);
      final iosModal = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
      return RepaintBoundary(
        child: RealtimeGlassSurface(
          radius: RealtimeUiThemeExtension.of(sheetContext).sheetRadius,
          opacity: iosModal ? 0.98 : null,
          blur: iosModal ? 0.0 : null,
          shadow: false,
          child: Material(
            type: MaterialType.transparency,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 10, bottom: 10),
                      width: 40,
                      height: 4.5,
                      decoration: BoxDecoration(
                        color: style.borderStrong,
                        borderRadius: BorderRadius.circular(
                          RealtimeUiTokens.pillRadius,
                        ),
                      ),
                    ),
                  ),
                  Flexible(child: builder(sheetContext)),
                ],
              ),
            ),
          ),
        ),
      );
    },
  ),
);
