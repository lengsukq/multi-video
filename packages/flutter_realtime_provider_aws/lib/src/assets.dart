import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';

Future<void> loadAssets({
  Iterable<String> mediaProviderIds = const [],
  bool includeProductChat = false,
  bool includeAllMediaProviders = false,
}) async {
  if (!includeAllMediaProviders &&
      !mediaProviderIds.any(const <String>{'chime', 'ivs'}.contains)) {
    return;
  }
  // Some AWS browser bundles still reference the Node-style `global` symbol.
  // Load a small self-hosted compatibility script before any vendor code.
  await loadRealtimeBundledWebScript(
    'assets/packages/flutter_realtime_provider_aws/assets/browser-global-compat.js',
  );
  if (includeAllMediaProviders || mediaProviderIds.contains('chime')) {
    await loadRealtimeBundledWebScript(
      'assets/packages/flutter_realtime_provider_aws/assets/chime-sdk.js',
    );
  }
  if (includeAllMediaProviders || mediaProviderIds.contains('ivs')) {
    await loadRealtimeBundledWebScript(
      'assets/packages/flutter_realtime_provider_aws/assets/amazon-ivs-web-broadcast.js',
    );
  }
  await loadRealtimeBundledWebScript(
    'assets/packages/flutter_realtime_media_web/assets/media-provider-bridge.js',
  );
}
