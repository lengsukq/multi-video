import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';
import 'demo_strings.dart';
import 'demo_backend_diagnostics.dart';

class DemoServerSettingsPanel extends StatelessWidget {
  const DemoServerSettingsPanel({
    super.key,
    required this.controller,
    required this.diagnostics,
    required this.defaultBackendUrl,
    required this.onTest,
  });
  final TextEditingController controller;
  final DemoBackendDiagnostics diagnostics;
  final String defaultBackendUrl;
  final Future<void> Function() onTest;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([controller, diagnostics]),
    builder: (context, _) => _contents(context),
  );
  Widget _contents(BuildContext context) {
    final style = RealtimeStyle.of(context);
    return RealtimeCardSurface(
      radius: RealtimeUiTokens.cardRadius,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final heading = Text(
                DemoStrings.of(context).backendServiceEndpoint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: style.text,
                ),
              );
              final status = RealtimePill(
                label: DemoStrings.of(context).backendStatus(
                  diagnostics.providerInfo,
                  checkingNow: diagnostics.testing,
                ),
                leadingDotColor: diagnostics.testing
                    ? style.primary
                    : diagnostics.online == true
                    ? style.success
                    : diagnostics.online == false
                    ? style.danger
                    : style.textMuted,
                foreground: diagnostics.online == true
                    ? style.success
                    : diagnostics.online == false
                    ? style.danger
                    : style.textMuted,
                background: diagnostics.online == true
                    ? style.successSubtle
                    : diagnostics.online == false
                    ? style.dangerSubtle
                    : style.surfaceSubtle,
                borderColor: diagnostics.online == true
                    ? (style.isDark
                          ? style.success
                          : RealtimeUiTokens.successBorder)
                    : diagnostics.online == false
                    ? (style.isDark
                          ? style.danger
                          : RealtimeUiTokens.dangerBorder)
                    : style.border,
                onTap: diagnostics.testing
                    ? null
                    : () async {
                        await onTest();
                      },
              );
              if (constraints.maxWidth < 430 ||
                  MediaQuery.textScalerOf(context).scale(13) >= 22) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    heading,
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: status),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: heading),
                  const SizedBox(width: 8),
                  status,
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          RealtimeGlassTextField(
            controller: controller,
            label: DemoStrings.of(context).demoBackendUrl,
            hintText: defaultBackendUrl,
            prefixIcon: Icons.dns_outlined,
            keyboardType: TextInputType.url,
            onChanged: (_) {
              diagnostics.clear();
            },
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _preset(
                context,
                DemoStrings.of(context).defaultServer,
                defaultBackendUrl,
              ),
              _preset(context, 'localhost:3000', 'http://localhost:3000'),
              _preset(context, 'Android 10.0.2.2', 'http://10.0.2.2:3000'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _preset(BuildContext context, String label, String url) {
    final style = RealtimeStyle.of(context);
    final selected = controller.text.trim() == url;
    return RealtimePill(
      label: label,
      foreground: selected ? Colors.white : style.textMuted,
      background: selected ? style.primary : style.surfaceSubtle,
      borderColor: selected ? style.primary : style.border,
      onTap: () async {
        controller.text = url;
        await onTest();
      },
    );
  }
}
