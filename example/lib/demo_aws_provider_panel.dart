import 'package:flutter/material.dart';
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// Desktop Demo entry point for the already-registered AWS media vendor.
///
/// The Demo never changes the backend provider without admin authorization.
/// The authenticated backend dashboard selects AWS for *new* rooms only.
class DemoAwsProviderPanel extends StatelessWidget {
  const DemoAwsProviderPanel({
    super.key,
    required this.backendUrl,
    required this.activeProviderId,
    required this.online,
    this.openDashboard,
  });

  final String backendUrl;
  final String? activeProviderId;
  final bool? online;
  final Future<bool> Function(Uri url)? openDashboard;

  Uri? get dashboardUri {
    final uri = Uri.tryParse(backendUrl.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '/',
    );
  }

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final style = RealtimeStyle.of(context);
    final active = activeProviderId == 'aws' ||
        activeProviderId == 'chime' ||
        activeProviderId == 'ivs';
    final status = online != true
        ? (zh ? '后端未确认' : 'Backend not verified')
        : active
            ? (zh ? '后端已选择 AWS' : 'AWS selected on backend')
            : (zh ? '已注册，等待后端选择' : 'Registered; select on backend');
    final dashboard = dashboardUri;

    return RealtimeCardSurface(
      radius: 18,
      padding: const EdgeInsets.all(16),
      child: Column(
        key: const ValueKey('demo-macos-aws-provider'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_outlined, size: 20, color: style.text),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'AWS',
                  style: TextStyle(
                    color: style.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                status,
                style: TextStyle(color: style.textMuted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            zh
                ? '会议 · AWS Chime SDK\n直播 · Amazon IVS Real-Time'
                : 'Meetings · AWS Chime SDK\nLive · Amazon IVS Real-Time',
            style: TextStyle(color: style.text, height: 1.5),
          ),
          const SizedBox(height: 8),
          Text(
            zh
                ? 'macOS 通过 WebKit 桥接接入；IVS 不受 AWS 官方 WebView 支持，需实机验收。新房间的供应商由后端管理员选择。'
                : 'macOS uses a WebKit bridge. AWS does not support IVS in WebViews; verify media on real devices. Backend administrators select the provider for new rooms.',
            style: TextStyle(color: style.textMuted, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('demo-manage-aws-provider'),
              onPressed: dashboard == null
                  ? null
                  : () async {
                      final open = openDashboard ??
                          (Uri uri) => launchUrl(
                                uri,
                                mode: LaunchMode.externalApplication,
                              );
                      await open(dashboard);
                    },
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(zh ? '打开后端供应商管理' : 'Open backend provider settings'),
            ),
          ),
        ],
      ),
    );
  }
}
