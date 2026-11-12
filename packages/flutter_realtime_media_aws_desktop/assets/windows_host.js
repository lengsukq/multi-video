/* Internal, isolated AWS WebView2 RPC bridge.
 * IVS is strictly experimental: AWS does NOT support Broadcast SDK in WebViews.
 */
(function installAwsWindowsHost(global) {
  'use strict';
  const host = global.chrome && global.chrome.webview;
  if (!host || !global.AwsDesktopRuntime) return;
  const providerId = global.location.hostname === 'aws-ivs-local.invalid'
    ? 'ivs' : global.location.hostname === 'aws-chime-local.invalid'
      ? 'chime' : null;
  if (!providerId) return;
  const sessionId = 'aws-desktop-' + providerId;
  const channel = 'aws-windows-' + providerId + '-v1';

  host.addEventListener('message', async function (event) {
    const request = event.data;
    if (!request || request.channel !== channel ||
        !Number.isSafeInteger(request.id) || request.id < 1) return;
    try {
      let value;
      if (request.operation === 'invoke') {
        if (request.providerId !== providerId ||
            request.sessionId !== sessionId) {
          throw new Error('Cross-provider Windows session access is forbidden.');
        }
        value = await global.AwsDesktopRuntime.invoke(
          request.providerId, request.sessionId, request.name,
          request.payload || {});
      } else if (request.operation === 'bind') {
        let trackId = String(request.trackId || '');
        const snapshot = global.AwsDesktopRuntime.snapshot(sessionId);
        if (providerId === 'ivs' && trackId.startsWith('ivs:participant:')) {
          const participantId = trackId.substring('ivs:participant:'.length);
          const found = snapshot?.tracks?.find(track => track.participantId === participantId &&
            !track.isScreenShare);
          if (!found) throw new Error('IVS participant does not have a published video track yet.');
          trackId = found.id;
        }
        if (!snapshot?.tracks?.some(track => track.id === trackId)) {
          throw new Error('AWS video track is not present in the current session.');
        }
        value = await global.AwsDesktopRuntime.bindTrack(
          providerId, sessionId, trackId,
          String(request.viewKey || ''));
      } else if (request.operation === 'unbind') {
        value = await global.AwsDesktopRuntime.unbindTrack(
          String(request.viewKey || ''));
      } else if (request.operation === 'probeDevices') {
        const devices = await global.navigator.mediaDevices.enumerateDevices();
        value = {
          microphones: devices.filter(device => device.kind === 'audioinput').length,
          cameras: devices.filter(device => device.kind === 'videoinput').length,
        };
      } else {
        throw new Error('Unknown AWS Windows host operation.');
      }
      host.postMessage({
        channel: channel, kind: 'result', id: request.id,
        success: true, value: value == null ? null : value,
      });
    } catch (error) {
      host.postMessage({
        channel: channel, kind: 'result', id: request.id,
        success: false,
        message: String(error && error.message || error),
      });
    }
  });
  // A WebView2 API existing does not prove that this application's own
  // Windows RPC handler loaded and attached successfully.
  global.__awsWindowsHostChannel = channel;
})(globalThis);
