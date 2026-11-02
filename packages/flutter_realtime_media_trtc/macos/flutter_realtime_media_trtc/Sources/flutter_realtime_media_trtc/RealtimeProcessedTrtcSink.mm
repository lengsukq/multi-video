#import "RealtimeProcessedTrtcSink.h"
#import "ProcessedNativeInterfaces.h"

@interface RealtimeProcessedTrtcSink () <FlutterRealtimeProcessedVideoFrameSink>
@property NSString *sourceId;
@property NSString *provider;
@property uint32_t trackId;
@property void *mediaEngine;
@property BOOL disposed;
@end
@implementation RealtimeProcessedTrtcSink
+ (instancetype)attachWithArguments:(NSDictionary *)args { return [self attachWithSourceId:args[@"sourceId"] ?: @"" provider:@"trtc" engineHandle:[args[@"engineHandle"] longLongValue] trackId:[args[@"trackId"] unsignedIntValue]]; }
+ (instancetype)attachWithSourceId:(NSString *)sourceId provider:(NSString *)provider engineHandle:(int64_t)handle trackId:(uint32_t)trackId {
  Class hub = NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub");
  if (!sourceId.length || ![hub respondsToSelector:@selector(containsSourceId:)] || ![hub containsSourceId:sourceId]) return nil;
  RealtimeProcessedTrtcSink *sink = [self new];
  sink.sourceId = sourceId; sink.provider = provider; sink.trackId = trackId;
  {
    Class cloud = NSClassFromString(@"TRTCCloud");
    Class frame = NSClassFromString(@"TRTCVideoFrame");
    if (![cloud respondsToSelector:@selector(sharedInstance)] || !frame) return nil;
    id engine = [cloud sharedInstance];
    if (![engine respondsToSelector:@selector(enableCustomVideoCapture:enable:)] ||
        ![engine respondsToSelector:@selector(sendCustomVideoData:frame:)]) return nil;
    [engine stopLocalPreview];
    [engine enableCustomVideoCapture:0 enable:YES];
  }
  [NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub") registerWithSourceId:sourceId sink:sink];
  return sink;
}
- (void)onProcessedVideoFrame:(FlutterRealtimeProcessedVideoFrame *)input {
  @synchronized(self) {
    if (_disposed) return;
    {
      id frame = [NSClassFromString(@"TRTCVideoFrame") new];
      if (!frame) return;
      [frame setValue:@(6) forKey:@"pixelFormat"];
      [frame setValue:@(1) forKey:@"bufferType"];
      [frame setValue:(__bridge id)input.pixelBuffer forKey:@"pixelBuffer"];
      [frame setValue:@(input.width) forKey:@"width"];
      [frame setValue:@(input.height) forKey:@"height"];
      [frame setValue:@(input.timestampNs/1000000) forKey:@"timestamp"];
      [frame setValue:@(0) forKey:@"rotation"];
      [[NSClassFromString(@"TRTCCloud") sharedInstance] sendCustomVideoData:0 frame:frame];
    }
  }
}
- (void)dispose {
  @synchronized(self) {
    if (_disposed) return; _disposed=YES;
    [NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub") unregisterWithSourceId:_sourceId sink:self];
    if ([_provider isEqualToString:@"trtc"]) [[NSClassFromString(@"TRTCCloud") sharedInstance] enableCustomVideoCapture:0 enable:NO];
  }
}
- (void)dealloc { [self dispose]; }
@end
