#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

@interface FlutterRealtimeProcessedVideoFrame : NSObject
@property(readonly) CVPixelBufferRef pixelBuffer;
@property(readonly) NSInteger width;
@property(readonly) NSInteger height;
@property(readonly) int64_t timestampNs;
@end
@protocol FlutterRealtimeProcessedVideoFrameSink <NSObject>
- (void)onProcessedVideoFrame:(FlutterRealtimeProcessedVideoFrame *)frame;
@end
@interface NSObject (RealtimeNativeVideo)
+ (BOOL)containsSourceId:(NSString *)sourceId;
+ (id)sharedSingleton;
+ (id)sharedInstance;
+ (void)registerWithSourceId:(NSString *)sourceId sink:(id)sink;
+ (void)unregisterWithSourceId:(NSString *)sourceId sink:(id)sink;
- (id)peerConnectionFactory;
- (NSMutableDictionary *)localTracks;
- (NSMutableDictionary *)localStreams;
- (id)videoSource;
- (id)initWithDelegate:(id)delegate;
- (id)videoTrackWithSource:(id)source trackId:(NSString *)trackId;
- (id)mediaStreamWithStreamId:(NSString *)streamId;
- (void)addVideoTrack:(id)track;
- (id)initWithTrack:(id)track;
- (NSDictionary *)mediaStreamToMap:(id)stream ownerTag:(NSString *)ownerTag;
- (id)initWithPixelBuffer:(CVPixelBufferRef)buffer;
- (id)initWithBuffer:(id)buffer rotation:(NSInteger)rotation timeStampNs:(int64_t)timestamp;
- (void)capturer:(id)capturer didCaptureVideoFrame:(id)frame;
- (void)stopLocalPreview;
- (void)enableCustomVideoCapture:(NSInteger)streamType enable:(BOOL)enabled;
- (void)sendCustomVideoData:(NSInteger)streamType frame:(id)frame;
@end
