#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

BOOL ArtcPopulateLockedBgraVideoSample(id sample,
                                       CVPixelBufferRef pixelBuffer,
                                       int64_t timestampMs);

@interface ArtcProcessedVideoInput : NSObject
+ (BOOL)isSupportedWithEngineClass:(nullable Class)engineClass;
- (nullable instancetype)initWithSourceId:(NSString *)sourceId
                                   engine:(id)engine
                                onFailure:(void (^)(NSString *message))onFailure;
- (void)dispose;
@end

NS_ASSUME_NONNULL_END
