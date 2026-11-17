#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ArtcScreenSourcesCallback)(
    NSArray<NSDictionary<NSString *, NSString *> *> *_Nullable sources,
    NSString *_Nullable errorCode,
    NSString *_Nullable errorMessage);

typedef void (^ArtcScreenStartCallback)(
    NSString *_Nullable errorCode,
    NSString *_Nullable errorMessage);

@interface ArtcMacosScreenCapture : NSObject

+ (void)listSourcesWithCompletion:(ArtcScreenSourcesCallback)completion;

- (void)startWithSourceId:(nullable NSString *)sourceId
               sourceKind:(nullable NSString *)sourceKind
                   engine:(id)engine
                onStopped:(void (^)(NSString *_Nullable errorMessage))onStopped
               completion:(ArtcScreenStartCallback)completion;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
