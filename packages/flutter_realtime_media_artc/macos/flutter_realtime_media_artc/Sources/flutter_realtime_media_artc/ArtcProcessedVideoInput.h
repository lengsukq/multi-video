#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

// Use the installed SDK's enum values and object layout when it is bundled.
// An absent or incompatible framework remains an unsupported capability.
#if __has_include(<AliRTCSdk/AliRtcEngine.h>)
#import <AliRTCSdk/AliRtcEngine.h>
#define REALTIME_ARTC_VIDEO_INPUT 1
#else
#define REALTIME_ARTC_VIDEO_INPUT 0
#endif

@interface FlutterRealtimeProcessedVideoFrame : NSObject
@property(readonly) CVPixelBufferRef pixelBuffer;
@property(readonly) NSInteger width;
@property(readonly) NSInteger height;
@property(readonly) int64_t timestampNs;
@end
@protocol FlutterRealtimeProcessedVideoFrameSink <NSObject>
- (void)onProcessedVideoFrame:(FlutterRealtimeProcessedVideoFrame *)frame;
@end
@interface NSObject (RealtimeArtcFrameHub)
+ (BOOL)containsSourceId:(NSString *)sourceId;
+ (void)registerWithSourceId:(NSString *)sourceId sink:(id)sink;
+ (void)unregisterWithSourceId:(NSString *)sourceId sink:(id)sink;
@end

@interface ArtcProcessedVideoInput : NSObject
+ (BOOL)isSupportedWithEngineClass:(Class)engineClass;
- (instancetype)initWithSourceId:(NSString *)sourceId engine:(id)engine
                       onFailure:(void (^)(NSString *message))onFailure;
- (void)dispose;
@end
