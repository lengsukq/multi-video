#import "FlutterRealtimeMediaAgoraPlugin.h"
#import "RealtimeProcessedAgoraSink.h"
@interface FlutterRealtimeMediaAgoraPlugin ()
@property NSMutableDictionary<NSString *, RealtimeProcessedAgoraSink *> *sinks;
@end
@implementation FlutterRealtimeMediaAgoraPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterRealtimeMediaAgoraPlugin *instance = [self new]; instance.sinks = [NSMutableDictionary new];
  FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:@"flutter_realtime_media_agora/processed_video" binaryMessenger:registrar.messenger];
  [registrar addMethodCallDelegate:instance channel:channel];
}
- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *args = call.arguments ?: @{};
  NSString *key = args[@"bindingId"] ?: @"";
  [self.sinks[key] dispose]; [self.sinks removeObjectForKey:key];
  if ([call.method isEqualToString:@"detachProvider"]) { result(nil); return; }
  if (![call.method isEqualToString:@"attachProvider"]) { result(FlutterMethodNotImplemented); return; }
  RealtimeProcessedAgoraSink *sink = [RealtimeProcessedAgoraSink attachWithArguments:args];
  if (!sink) { result([FlutterError errorWithCode:@"processed_binding_failed" message:@"processed.binding.attach" details:nil]); return; }
  NSString *sourceId = args[@"sourceId"] ?: @"";
  sink.onFailure = ^(NSString *message) {
    Class hub = NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub");
    [hub performSelector:NSSelectorFromString(@"reportFailureWithSourceId:message:") withObject:sourceId withObject:message];
  };
  self.sinks[key] = sink; result(nil);
}
- (void)dealloc { for (RealtimeProcessedAgoraSink *sink in self.sinks.allValues) [sink dispose]; }
@end
