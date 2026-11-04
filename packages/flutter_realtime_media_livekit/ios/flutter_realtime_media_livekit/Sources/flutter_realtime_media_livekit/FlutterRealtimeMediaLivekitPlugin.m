#import "FlutterRealtimeMediaLivekitPlugin.h"
#import "ProcessedNativeInterfaces.h"

@interface ProcessedWebRtcTrack : NSObject <FlutterRealtimeProcessedVideoFrameSink>
@property NSString *sourceId;
@property NSString *streamId;
@property NSString *trackId;
@property id source;
@property id capturer;
@property id track;
@property BOOL disposed;
@end

@implementation ProcessedWebRtcTrack
- (void)onProcessedVideoFrame:(FlutterRealtimeProcessedVideoFrame *)frame {
  @synchronized (self) {
    if (_disposed) return;
    id buffer = [[NSClassFromString(@"RTCCVPixelBuffer") alloc] initWithPixelBuffer:frame.pixelBuffer];
    id video = [[NSClassFromString(@"RTCVideoFrame") alloc] initWithBuffer:buffer rotation:0 timeStampNs:frame.timestampNs];
    [_source capturer:_capturer didCaptureVideoFrame:video];
  }
}
- (void)dispose {
  @synchronized (self) {
    if (_disposed) return;
    _disposed = YES;
    [NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub") unregisterWithSourceId:_sourceId sink:self];
    id plugin = [NSClassFromString(@"FlutterWebRTCPlugin") sharedSingleton];
    [[plugin localTracks] removeObjectForKey:_trackId];
    [[plugin localStreams] removeObjectForKey:_streamId];
    _track = nil; _capturer = nil; _source = nil;
  }
}
@end

@interface FlutterRealtimeMediaLivekitPlugin ()
@property NSMutableDictionary<NSString *, ProcessedWebRtcTrack *> *tracks;
@end
@implementation FlutterRealtimeMediaLivekitPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:@"flutter_realtime_media_livekit/processed_video" binaryMessenger:registrar.messenger];
  FlutterMethodChannel *broadcastChannel = [FlutterMethodChannel methodChannelWithName:@"flutter_realtime_media_livekit/ios_broadcast" binaryMessenger:registrar.messenger];
  FlutterRealtimeMediaLivekitPlugin *plugin = [self new];
  plugin.tracks = [NSMutableDictionary new];
  [registrar addMethodCallDelegate:plugin channel:channel];
  [registrar addMethodCallDelegate:plugin channel:broadcastChannel];
}
- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"configuration"]) {
    NSString *group = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"RTCAppGroupIdentifier"];
    NSString *extensionId = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"RTCScreenSharingExtension"];
    NSURL *container = group.length ? [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:group] : nil;
    NSURL *plugins = [[NSBundle mainBundle] builtInPlugInsURL];
    BOOL installed = NO;
    if (extensionId.length && plugins) {
      NSArray<NSURL *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:plugins includingPropertiesForKeys:nil options:0 error:nil];
      for (NSURL *entry in entries) {
        NSBundle *bundle = [NSBundle bundleWithURL:entry];
        if ([bundle.bundleIdentifier isEqualToString:extensionId]) {
          installed = YES;
          break;
        }
      }
    }
    result(@{
      @"configured": @(group.length && extensionId.length && container != nil && installed),
      @"hasAppGroup": @(container != nil),
      @"hasExtension": @(installed),
      @"appGroup": group ?: @"",
      @"extensionId": extensionId ?: @""
    });
    return;
  }
  NSString *sourceId = call.arguments[@"sourceId"];
  if ([call.method isEqualToString:@"dispose"]) {
    [_tracks[sourceId] dispose]; [_tracks removeObjectForKey:sourceId]; result(nil); return;
  }
  if (![call.method isEqualToString:@"create"]) { result(FlutterMethodNotImplemented); return; }
  Class hub = NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub");
  Class rtcPlugin = NSClassFromString(@"FlutterWebRTCPlugin");
  if (!sourceId.length || ![hub respondsToSelector:@selector(containsSourceId:)] || ![hub containsSourceId:sourceId] ||
      ![rtcPlugin respondsToSelector:@selector(sharedSingleton)] || !NSClassFromString(@"LocalVideoTrack") ||
      !NSClassFromString(@"RTCCVPixelBuffer") || !NSClassFromString(@"RTCVideoFrame") || !NSClassFromString(@"RTCVideoCapturer")) {
    result([FlutterError errorWithCode:@"processed_video_failed" message:@"The native processed video source or WebRTC input is unavailable." details:nil]); return;
  }
  id rtc = [NSClassFromString(@"FlutterWebRTCPlugin") sharedSingleton];
  id factory = [rtc peerConnectionFactory];
  if (!factory || !sourceId.length) {
    result([FlutterError errorWithCode:@"processed_video_failed" message:@"WebRTC is unavailable or sourceId is missing." details:nil]); return;
  }
  [_tracks[sourceId] dispose];
  ProcessedWebRtcTrack *sink = [ProcessedWebRtcTrack new];
  sink.sourceId = sourceId; sink.streamId = NSUUID.UUID.UUIDString; sink.trackId = NSUUID.UUID.UUIDString;
  sink.source = [factory videoSource];
  sink.capturer = [[NSClassFromString(@"RTCVideoCapturer") alloc] initWithDelegate:sink.source];
  sink.track = [factory videoTrackWithSource:sink.source trackId:sink.trackId];
  id stream = [factory mediaStreamWithStreamId:sink.streamId];
  if (!sink.source || !sink.capturer || !sink.track || !stream) {
    [sink dispose]; result([FlutterError errorWithCode:@"processed_video_failed" message:@"WebRTC failed to create the processed video input." details:nil]); return;
  }
  [stream addVideoTrack:sink.track];
  [rtc localTracks][sink.trackId] = [[NSClassFromString(@"LocalVideoTrack") alloc] initWithTrack:sink.track];
  [rtc localStreams][sink.streamId] = stream;
  _tracks[sourceId] = sink;
  [NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub") registerWithSourceId:sourceId sink:sink];
  result([rtc mediaStreamToMap:stream ownerTag:@"local"]);
}
- (void)dealloc {
  for (ProcessedWebRtcTrack *sink in _tracks.allValues) [sink dispose];
}
@end
