#import "ArtcProcessedVideoInput.h"

@interface ArtcProcessedVideoInput () <FlutterRealtimeProcessedVideoFrameSink>
@property(nonatomic, copy) NSString *sourceId;
@property(nonatomic, strong) id engine;
@property(nonatomic, copy) void (^onFailure)(NSString *message);
@property(nonatomic, assign) BOOL disposed;
@end

@implementation ArtcProcessedVideoInput
+ (BOOL)isSupportedWithEngineClass:(Class)engineClass {
#if REALTIME_ARTC_VIDEO_INPUT
  Class hub = NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub");
  return engineClass && NSClassFromString(@"AliRtcVideoDataSample") &&
    [engineClass instancesRespondToSelector:@selector(setExternalVideoSource:sourceType:renderMode:)] &&
    [engineClass instancesRespondToSelector:@selector(pushExternalVideoFrame:sourceType:)] &&
    [hub respondsToSelector:@selector(containsSourceId:)];
#else
  return NO;
#endif
}
- (instancetype)initWithSourceId:(NSString *)sourceId engine:(id)engine
                       onFailure:(void (^)(NSString *))onFailure {
  self = [super init];
  if (!self) return nil;
#if REALTIME_ARTC_VIDEO_INPUT
  Class hub = NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub");
  if (![ArtcProcessedVideoInput isSupportedWithEngineClass:[engine class]] ||
      ![hub containsSourceId:sourceId]) return nil;
  NSInteger result = [engine setExternalVideoSource:YES
    sourceType:AliRtcVideosourceCameraType renderMode:AliRtcRenderModeAuto];
  if (result != 0) return nil;
  _sourceId = [sourceId copy]; _engine = engine; _onFailure = [onFailure copy];
  [hub registerWithSourceId:sourceId sink:self];
  return self;
#else
  return nil;
#endif
}
- (void)onProcessedVideoFrame:(FlutterRealtimeProcessedVideoFrame *)frame {
#if REALTIME_ARTC_VIDEO_INPUT
  @synchronized(self) {
    if (_disposed) return;
    CVPixelBufferLockBaseAddress(frame.pixelBuffer, kCVPixelBufferLock_ReadOnly);
    AliRtcVideoDataSample *sample = [AliRtcVideoDataSample new];
    sample.format = AliRtcVideoFormat_BGRA;
    sample.type = AliRtcBufferType_Raw_Data;
    sample.dataPtr = (long)CVPixelBufferGetBaseAddress(frame.pixelBuffer);
    sample.width = (int)frame.width; sample.height = (int)frame.height;
    sample.stride = (int)CVPixelBufferGetBytesPerRow(frame.pixelBuffer);
    sample.dataLength = sample.stride * sample.height;
    sample.rotation = 0; sample.timeStamp = frame.timestampNs / 1000000;
    NSInteger result = [_engine pushExternalVideoFrame:sample sourceType:AliRtcVideosourceCameraType];
    CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (result != 0) {
      void (^failure)(NSString *) = _onFailure;
      [self dispose];
      failure([NSString stringWithFormat:@"ARTC rejected a processed video frame (%ld).", (long)result]);
    }
  }
#endif
}
- (void)dispose {
  @synchronized(self) {
    if (_disposed) return;
    _disposed = YES;
    [NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub") unregisterWithSourceId:_sourceId sink:self];
#if REALTIME_ARTC_VIDEO_INPUT
    [_engine publishLocalVideoStream:NO];
    [_engine setExternalVideoSource:NO sourceType:AliRtcVideosourceCameraType renderMode:AliRtcRenderModeAuto];
#endif
    _engine = nil; _onFailure = nil;
  }
}
- (void)dealloc { [self dispose]; }
@end
