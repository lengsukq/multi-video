part of '../flutter_realtime_design_ui.dart';

class RealtimeGlassDialog extends StatelessWidget {
  const RealtimeGlassDialog({
    super.key,
    required this.title,
    required this.content,
    this.icon,
    this.iconColor = RealtimeUiTokens.text,
    this.iconBackground = RealtimeUiTokens.primarySubtle,
    this.actions = const [],
    this.maxWidth = 480,
  });

  final Widget title;
  final Widget content;
  final IconData? icon;
  final Color iconColor;
  final Color iconBackground;
  final List<Widget> actions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final iosModal = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    return _RealtimeModalTheme(
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          // Avoid Impeller BackdropFilter compositing over iOS UiKitView tiles.
          child: RepaintBoundary(
            child: RealtimeGlassSurface(
              radius: RealtimeUiThemeExtension.of(context).sheetRadius,
              opacity: iosModal ? 0.98 : 0.92,
              blur: iosModal ? 0.0 : null,
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
          child: Material(
            type: MaterialType.transparency,
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        if (icon != null) ...[
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: iconBackground,
                              borderRadius: BorderRadius.circular(
                                RealtimeUiTokens.compactRadius,
                              ),
                            ),
                            child: Icon(icon, color: iconColor, size: 22),
                          ),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: DefaultTextStyle(
                            style: Theme.of(context).textTheme.titleLarge!
                                .copyWith(
                                  color: RealtimeStyle.of(context).text,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.2,
                                ),
                            child: title,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight,
                      ),
                      child: content,
                    ),
                    if (actions.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Wrap(
                        alignment: WrapAlignment.end,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: actions,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);
  }
}

// Standalone SDK modals get the same defaults as the prebuilt room pages.
// A host that installs the SDK extension retains its theme and brand overrides.
class _RealtimeModalTheme extends StatelessWidget {
  const _RealtimeModalTheme({required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (theme.extension<RealtimeUiThemeExtension>() != null) {
      return builder(context);
    }
    return Theme(
      data: RealtimeUiTheme.light(),
      child: Builder(builder: builder),
    );
  }
}
