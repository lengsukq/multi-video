#import "RealtimeProcessedAgoraSink.h"
#import "ProcessedNativeInterfaces.h"
#include "IAgoraRtcEngine.h"
#include "IAgoraMediaEngine.h"

@interface RealtimeProcessedAgoraSink () <FlutterRealtimeProcessedVideoFrameSink>
@property NSString *sourceId;
@property NSString *provider;
@property uint32_t trackId;
@property void *mediaEngine;
@property BOOL disposed;
@end
@implementation RealtimeProcessedAgoraSink
+ (instancetype)attachWithArguments:(NSDictionary *)args { return [self attachWithSourceId:args[@"sourceId"] ?: @"" provider:@"agora" engineHandle:[args[@"engineHandle"] longLongValue] trackId:[args[@"trackId"] unsignedIntValue]]; }
+ (instancetype)attachWithSourceId:(NSString *)sourceId provider:(NSString *)provider engineHandle:(int64_t)handle trackId:(uint32_t)trackId {
  Class hub = NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub");
  if (!sourceId.length || ![hub respondsToSelector:@selector(containsSourceId:)] || ![hub containsSourceId:sourceId]) return nil;
  RealtimeProcessedAgoraSink *sink = [self new];
  sink.sourceId = sourceId; sink.provider = provider; sink.trackId = trackId;
  if ([provider isEqualToString:@"agora"]) {
    auto *engine = reinterpret_cast<agora::rtc::IRtcEngine *>(handle);
    agora::media::IMediaEngine *media = nullptr;
    if (!engine || engine->queryInterface(agora::rtc::AGORA_IID_MEDIA_ENGINE, reinterpret_cast<void **>(&media))) return nil;
    sink.mediaEngine = media;
  } else return nil;
  [NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub") registerWithSourceId:sourceId sink:sink];
  return sink;
}
- (void)onProcessedVideoFrame:(FlutterRealtimeProcessedVideoFrame *)input {
  @synchronized(self) {
    if (_disposed) return;
    if (_mediaEngine) {
      CVPixelBufferLockBaseAddress(input.pixelBuffer,kCVPixelBufferLock_ReadOnly);
      agora::media::base::ExternalVideoFrame frame;
      frame.format = agora::media::base::VIDEO_PIXEL_BGRA;
      frame.buffer = CVPixelBufferGetBaseAddress(input.pixelBuffer);
      frame.stride = (int)CVPixelBufferGetBytesPerRow(input.pixelBuffer)/4;
      frame.height = (int)input.height;
      frame.cropRight = frame.stride - (int)input.width;
      frame.timestamp = input.timestampNs/1000000;
      int result = reinterpret_cast<agora::media::IMediaEngine *>(_mediaEngine)->pushVideoFrame(&frame,_trackId);
      CVPixelBufferUnlockBaseAddress(input.pixelBuffer,kCVPixelBufferLock_ReadOnly);
      if (result != 0) {
        void (^failure)(NSString *) = self.onFailure;
        [self dispose];
        if (failure) failure([NSString stringWithFormat:@"Agora rejected a processed video frame (%d).", result]);
      }
    }
  }
}
- (void)dispose {
  @synchronized(self) {
    if (_disposed) return; _disposed=YES;
    [NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub") unregisterWithSourceId:_sourceId sink:self];
    if (_mediaEngine) { reinterpret_cast<agora::media::IMediaEngine *>(_mediaEngine)->release(); _mediaEngine=nullptr; }
  }
}
- (void)dealloc { [self dispose]; }
@end
