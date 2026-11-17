import DefaultMeetingSession from 'amazon-chime-sdk-js/build/meetingsession/DefaultMeetingSession.js';
import MeetingSessionConfiguration from 'amazon-chime-sdk-js/build/meetingsession/MeetingSessionConfiguration.js';
import DefaultDeviceController from 'amazon-chime-sdk-js/build/devicecontroller/DefaultDeviceController.js';
import ConsoleLogger from 'amazon-chime-sdk-js/build/logger/ConsoleLogger.js';
import LogLevel from 'amazon-chime-sdk-js/build/logger/LogLevel.js';
import MeetingSessionStatusCode from 'amazon-chime-sdk-js/build/meetingsession/MeetingSessionStatusCode.js';
import VideoCodecCapability from 'amazon-chime-sdk-js/build/sdp/VideoCodecCapability.js';

// The Chime SDK publishes CommonJS modules. esbuild's ESM/CJS interop wraps
// their default exports in `{ default: ... }` for this import path. Expose
// actual constructors/enums to the macOS WKWebView and browser bridge rather
// than those wrapper objects (`new ChimeSDK.ConsoleLogger` otherwise fails).
const unwrapDefault = (value) => value?.default ?? value;

const ResolvedDeviceController = unwrapDefault(DefaultDeviceController);

// DefaultDeviceController.getAudioContext() unguardedly accesses
// navigator.mediaDevices.getSupportedConstraints(), which throws in embedded
// WebViews if mediaDevices is restricted and prevents Chime from synthesizing
// its silent initial audio stream required for attendee presence handshake.
if (ResolvedDeviceController && typeof ResolvedDeviceController.getAudioContext === 'function') {
  const originalGetAudioContext = ResolvedDeviceController.getAudioContext.bind(ResolvedDeviceController);
  ResolvedDeviceController.getAudioContext = function patchedGetAudioContext() {
    if (ResolvedDeviceController.audioContext) {
      return ResolvedDeviceController.audioContext;
    }
    const nav = globalThis.navigator;
    if (nav && nav.mediaDevices && typeof nav.mediaDevices.getSupportedConstraints === 'function') {
      return originalGetAudioContext();
    }
    const ContextCtor = globalThis.AudioContext || globalThis.webkitAudioContext;
    if (!ContextCtor) {
      return originalGetAudioContext();
    }
    ResolvedDeviceController.audioContext = new ContextCtor();
    return ResolvedDeviceController.audioContext;
  };
}

globalThis.ChimeSDK = {
  DefaultMeetingSession: unwrapDefault(DefaultMeetingSession),
  MeetingSessionConfiguration: unwrapDefault(MeetingSessionConfiguration),
  DefaultDeviceController: ResolvedDeviceController,
  ConsoleLogger: unwrapDefault(ConsoleLogger),
  LogLevel: unwrapDefault(LogLevel),
  MeetingSessionStatusCode: unwrapDefault(MeetingSessionStatusCode),
  VideoCodecCapability: unwrapDefault(VideoCodecCapability),
};
