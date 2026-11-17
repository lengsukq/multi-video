#import "ArtcProcessedVideoInput.h"
#import <objc/message.h>

static const NSInteger kArtcVideoSourceCamera = 0;      // AliRtcVideosourceCameraType
static const NSUInteger kArtcRenderModeAuto = 0;        // AliRtcRenderModeAuto
static const NSInteger kArtcVideoFormatBGRA = 0;        // AliRtcVideoFormat_BGRA
static const NSInteger kArtcBufferTypeRawData = 0;      // AliRtcBufferType_Raw_Data
static const int kArtcErrVideoBufferFull = 0x01070102;  // AliRtcErrVideoBufferFull

@interface ArtcProcessedVideoFrameProxy : NSObject
@property(readonly) CVPixelBufferRef pixelBuffer;
@property(readonly) NSInteger width;
@property(readonly) NSInteger height;
@property(readonly) int64_t timestampNs;
@end

@interface NSObject (RealtimeArtcFrameHubDynamic)
+ (BOOL)containsSourceId:(NSString *)sourceId;
+ (void)registerWithSourceId:(NSString *)sourceId sink:(id)sink;
+ (void)unregisterWithSourceId:(NSString *)sourceId sink:(id)sink;
+ (void)reportFailureWithSourceId:(NSString *)sourceId message:(NSString *)message;
@end

BOOL ArtcPopulateLockedBgraVideoSample(id sample,
                                       CVPixelBufferRef pixelBuffer,
                                       int64_t timestampMs) {
  if (sample == nil || pixelBuffer == NULL || CVPixelBufferIsPlanar(pixelBuffer)) {
    return NO;
  }
  void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
  size_t rawWidth = CVPixelBufferGetWidth(pixelBuffer);
  size_t rawHeight = CVPixelBufferGetHeight(pixelBuffer);
  size_t rawStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
  if (baseAddress == NULL || rawWidth == 0 || rawHeight == 0 ||
      rawWidth > 4096 || rawHeight > 4096 || rawStride < rawWidth * 4) {
    return NO;
  }

  SEL setFormatSel = NSSelectorFromString(@"setFormat:");
  SEL setTypeSel = NSSelectorFromString(@"setType:");
  SEL setPixelBufferSel = NSSelectorFromString(@"setPixelBuffer:");
  SEL setDataPtrSel = NSSelectorFromString(@"setDataPtr:");
  SEL setDataLengthSel = NSSelectorFromString(@"setDataLength:");
  SEL setStrideSel = NSSelectorFromString(@"setStride:");
  SEL setWidthSel = NSSelectorFromString(@"setWidth:");
  SEL setHeightSel = NSSelectorFromString(@"setHeight:");
  SEL setRotationSel = NSSelectorFromString(@"setRotation:");
  SEL setTimeStampSel = NSSelectorFromString(@"setTimeStamp:");

  if (![sample respondsToSelector:setFormatSel] ||
      ![sample respondsToSelector:setTypeSel] ||
      ![sample respondsToSelector:setDataPtrSel] ||
      ![sample respondsToSelector:setDataLengthSel] ||
      ![sample respondsToSelector:setStrideSel] ||
      ![sample respondsToSelector:setWidthSel] ||
      ![sample respondsToSelector:setHeightSel]) {
    return NO;
  }

  ((void (*)(id, SEL, NSInteger))objc_msgSend)(
      sample, setFormatSel, kArtcVideoFormatBGRA);
  ((void (*)(id, SEL, NSInteger))objc_msgSend)(
      sample, setTypeSel, kArtcBufferTypeRawData);
  if ([sample respondsToSelector:setPixelBufferSel]) {
    ((void (*)(id, SEL, CVPixelBufferRef))objc_msgSend)(
        sample, setPixelBufferSel, pixelBuffer);
  }
  ((void (*)(id, SEL, uint8_t *))objc_msgSend)(
      sample, setDataPtrSel, (uint8_t *)baseAddress);
  ((void (*)(id, SEL, int))objc_msgSend)(sample, setWidthSel, (int)rawWidth);
  ((void (*)(id, SEL, int))objc_msgSend)(sample, setHeightSel, (int)rawHeight);
  ((void (*)(id, SEL, int))objc_msgSend)(sample, setStrideSel, (int)rawStride);
  ((void (*)(id, SEL, long))objc_msgSend)(
      sample, setDataLengthSel, (long)rawStride * (long)rawHeight);
  if ([sample respondsToSelector:setRotationSel]) {
    ((void (*)(id, SEL, int))objc_msgSend)(sample, setRotationSel, 0);
  }
  if ([sample respondsToSelector:setTimeStampSel]) {
    ((void (*)(id, SEL, long long))objc_msgSend)(
        sample, setTimeStampSel, (long long)timestampMs);
  }
  return YES;
}

@interface ArtcProcessedVideoInput ()
@property(nonatomic, copy) NSString *sourceId;
@property(nonatomic, strong, nullable) id engine;
@property(nonatomic, copy, nullable) void (^onFailure)(NSString *message);
@property(nonatomic, assign) BOOL disposed;
@end

@implementation ArtcProcessedVideoInput

+ (BOOL)isSupportedWithEngineClass:(Class)engineClass {
  Class hub = NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub");
  Class sampleClass = NSClassFromString(@"AliRtcVideoDataSample");
  SEL setExtSel =
      NSSelectorFromString(@"setExternalVideoSource:sourceType:renderMode:");
  SEL pushExtSel =
      NSSelectorFromString(@"pushExternalVideoFrame:sourceType:");
  SEL containsSel = NSSelectorFromString(@"containsSourceId:");
  return engineClass != Nil && sampleClass != Nil && hub != Nil &&
         [engineClass instancesRespondToSelector:setExtSel] &&
         [engineClass instancesRespondToSelector:pushExtSel] &&
         [hub respondsToSelector:containsSel];
}

- (instancetype)initWithSourceId:(NSString *)sourceId
                          engine:(id)engine
                       onFailure:(void (^)(NSString *message))onFailure {
  self = [super init];
  if (!self) return nil;
  Class hub = NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub");
  if (engine == nil || sourceId.length == 0 ||
      ![ArtcProcessedVideoInput isSupportedWithEngineClass:[engine class]]) {
    return nil;
  }
  SEL containsSel = NSSelectorFromString(@"containsSourceId:");
  BOOL hasSource =
      ((BOOL(*)(id, SEL, id))objc_msgSend)(hub, containsSel, sourceId);
  if (!hasSource) return nil;

  SEL setExtSel =
      NSSelectorFromString(@"setExternalVideoSource:sourceType:renderMode:");
  int result = ((int (*)(id, SEL, BOOL, NSInteger, NSUInteger))objc_msgSend)(
      engine, setExtSel, YES, kArtcVideoSourceCamera, kArtcRenderModeAuto);
  if (result != 0) return nil;

  _sourceId = [sourceId copy];
  _engine = engine;
  _onFailure = [onFailure copy];
  SEL registerSel = NSSelectorFromString(@"registerWithSourceId:sink:");
  ((void (*)(id, SEL, id, id))objc_msgSend)(hub, registerSel, sourceId, self);
  return self;
}

- (void)onProcessedVideoFrame:(id)rawFrame {
  ArtcProcessedVideoFrameProxy *frame = (ArtcProcessedVideoFrameProxy *)rawFrame;
  NSString *failureMessage = nil;
  void (^failureCallback)(NSString *) = nil;
  NSString *failedSourceId = nil;

  @synchronized(self) {
    if (_disposed || _engine == nil || frame == nil) return;
    Class sampleClass = NSClassFromString(@"AliRtcVideoDataSample");
    if (sampleClass == Nil) return;

    SEL pixelBufferSel = NSSelectorFromString(@"pixelBuffer");
    if (![frame respondsToSelector:pixelBufferSel]) return;
    CVPixelBufferRef pixelBuffer =
        ((CVPixelBufferRef(*)(id, SEL))objc_msgSend)(frame, pixelBufferSel);
    if (pixelBuffer == NULL) return;

    int64_t timestampNs = 0;
    SEL timestampSel = NSSelectorFromString(@"timestampNs");
    if ([frame respondsToSelector:timestampSel]) {
      timestampNs = ((int64_t(*)(id, SEL))objc_msgSend)(frame, timestampSel);
    }

    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
      return;
    }
    id sample = [[sampleClass alloc] init];
    BOOL valid = ArtcPopulateLockedBgraVideoSample(
        sample, pixelBuffer, timestampNs / 1000000);
    int result = -1;
    if (valid) {
      SEL pushSel =
          NSSelectorFromString(@"pushExternalVideoFrame:sourceType:");
      result = ((int (*)(id, SEL, id, NSInteger))objc_msgSend)(
          _engine, pushSel, sample, kArtcVideoSourceCamera);
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    if (!valid || (result != 0 && result != kArtcErrVideoBufferFull)) {
      failureMessage = !valid
                           ? @"ARTC received an invalid processed video frame."
                           : [NSString stringWithFormat:
                                           @"ARTC rejected a processed video frame (%d).",
                                           result];
      failureCallback = _onFailure;
      failedSourceId = _sourceId;
      [self disposeLocked];
    }
  }

  if (failureMessage != nil) {
    Class hub = NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub");
    SEL reportSel = NSSelectorFromString(@"reportFailureWithSourceId:message:");
    if (hub != Nil && [hub respondsToSelector:reportSel] &&
        failedSourceId.length > 0) {
      ((void (*)(id, SEL, id, id))objc_msgSend)(
          hub, reportSel, failedSourceId, failureMessage);
    }
    if (failureCallback != nil) {
      failureCallback(failureMessage);
    }
  }
}

- (void)disposeLocked {
  if (_disposed) return;
  _disposed = YES;
  Class hub = NSClassFromString(@"FlutterRealtimeProcessedVideoFrameHub");
  SEL unregisterSel = NSSelectorFromString(@"unregisterWithSourceId:sink:");
  if (hub != Nil && [hub respondsToSelector:unregisterSel] &&
      _sourceId.length > 0) {
    ((void (*)(id, SEL, id, id))objc_msgSend)(
        hub, unregisterSel, _sourceId, self);
  }
  if (_engine != nil) {
    SEL publishSel = NSSelectorFromString(@"publishLocalVideoStream:");
    if ([_engine respondsToSelector:publishSel]) {
      ((int (*)(id, SEL, BOOL))objc_msgSend)(_engine, publishSel, NO);
    }
    SEL setExtSel =
        NSSelectorFromString(@"setExternalVideoSource:sourceType:renderMode:");
    if ([_engine respondsToSelector:setExtSel]) {
      ((int (*)(id, SEL, BOOL, NSInteger, NSUInteger))objc_msgSend)(
          _engine, setExtSel, NO, kArtcVideoSourceCamera, kArtcRenderModeAuto);
    }
  }
  _engine = nil;
  _onFailure = nil;
}

- (void)dispose {
  @synchronized(self) {
    [self disposeLocked];
  }
}

- (void)dealloc {
  [self dispose];
}

@end
