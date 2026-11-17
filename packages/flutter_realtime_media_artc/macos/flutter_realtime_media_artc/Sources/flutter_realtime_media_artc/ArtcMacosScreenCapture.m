#import "ArtcMacosScreenCapture.h"
#import "ArtcProcessedVideoInput.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <objc/message.h>

static const NSInteger kArtcVideoSourceScreen = 1;      // AliRtcVideosourceScreenShareType
static const NSUInteger kArtcVideoTrackScreen = 2;      // AliRtcVideoTrackScreen
static const NSUInteger kArtcScreenRenderModeAuto = 0;  // AliRtcRenderModeAuto
static const int kArtcScreenBufferFull = 0x01070102;    // AliRtcErrVideoBufferFull

static BOOL ArtcEnsureScreenCapturePermission(void) {
  if (CGPreflightScreenCaptureAccess()) return YES;
  CGRequestScreenCaptureAccess();
  return CGPreflightScreenCaptureAccess();
}

static BOOL ArtcEngineSupportsExternalScreenInput(id engine) {
  if (engine == nil) return NO;
  Class sampleClass = NSClassFromString(@"AliRtcVideoDataSample");
  SEL setExtSel =
      NSSelectorFromString(@"setExternalVideoSource:sourceType:renderMode:");
  SEL pushExtSel =
      NSSelectorFromString(@"pushExternalVideoFrame:sourceType:");
  return sampleClass != Nil &&
         [engine respondsToSelector:setExtSel] &&
         [engine respondsToSelector:pushExtSel];
}

static int ArtcStartEngineScreenPublish(id engine,
                                        uint32_t numericId,
                                        BOOL isWindow,
                                        BOOL externalMode) {
  if (engine == nil) return -1;
  SEL startSimpleSel = NSSelectorFromString(@"startScreenShare");
  if ([engine respondsToSelector:startSimpleSel]) {
    return ((int (*)(id, SEL))objc_msgSend)(engine, startSimpleSel);
  }
  SEL publishTrackSel =
      NSSelectorFromString(@"publishLocalVideoStream:forTrack:");
  if (externalMode && [engine respondsToSelector:publishTrackSel]) {
    return ((int (*)(id, SEL, BOOL, NSUInteger))objc_msgSend)(
        engine, publishTrackSel, YES, kArtcVideoTrackScreen);
  }
  Class configClass = NSClassFromString(@"AliRtcScreenShareConfig");
  SEL byWindowSel = NSSelectorFromString(@"startScreenShareByWindowId:config:");
  SEL byDesktopSel =
      NSSelectorFromString(@"startScreenShareByDesktopId:config:");
  if (configClass != Nil &&
      [engine respondsToSelector:(isWindow ? byWindowSel : byDesktopSel)]) {
    id config = [[configClass alloc] init];
    SEL setPushSel = NSSelectorFromString(@"setIsPushStream:");
    if ([config respondsToSelector:setPushSel]) {
      ((void (*)(id, SEL, BOOL))objc_msgSend)(config, setPushSel, YES);
    }
    return ((int (*)(id, SEL, unsigned int, id))objc_msgSend)(
        engine, isWindow ? byWindowSel : byDesktopSel, numericId, config);
  }
  return -2;
}

static void ArtcStopEngineScreenPublish(id engine, BOOL externalMode) {
  if (engine == nil) return;
  SEL stopSel = NSSelectorFromString(@"stopScreenShare");
  if ([engine respondsToSelector:stopSel]) {
    ((int (*)(id, SEL))objc_msgSend)(engine, stopSel);
  } else {
    SEL publishTrackSel =
        NSSelectorFromString(@"publishLocalVideoStream:forTrack:");
    if ([engine respondsToSelector:publishTrackSel]) {
      ((int (*)(id, SEL, BOOL, NSUInteger))objc_msgSend)(
          engine, publishTrackSel, NO, kArtcVideoTrackScreen);
    }
  }
  if (externalMode) {
    SEL setExtSel =
        NSSelectorFromString(@"setExternalVideoSource:sourceType:renderMode:");
    if ([engine respondsToSelector:setExtSel]) {
      ((int (*)(id, SEL, BOOL, NSInteger, NSUInteger))objc_msgSend)(
          engine, setExtSel, NO, kArtcVideoSourceScreen,
          kArtcScreenRenderModeAuto);
    }
  }
}

API_AVAILABLE(macos(12.3))
@interface ArtcScStreamSession : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, strong, nullable) SCStream *stream;
@property(nonatomic, strong, nullable) id engine;
@property(nonatomic, strong) dispatch_queue_t sampleQueue;
@property(nonatomic, copy, nullable) void (^onStopped)(NSString *_Nullable);
@property(nonatomic, assign) BOOL disposed;
@property(nonatomic, assign) BOOL externalMode;
- (void)stop;
@end

@implementation ArtcScStreamSession

- (instancetype)initWithEngine:(id)engine
                     onStopped:(void (^)(NSString *_Nullable))onStopped {
  self = [super init];
  if (self) {
    _engine = engine;
    _onStopped = [onStopped copy];
    _sampleQueue = dispatch_queue_create(
        "com.oneplusdream.artc.macos_screen_capture",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                QOS_CLASS_USER_INTERACTIVE, 0));
  }
  return self;
}

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
  if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sampleBuffer)) {
    return;
  }
  NSArray<NSDictionary *> *attachments =
      (__bridge NSArray<NSDictionary *> *)CMSampleBufferGetSampleAttachmentsArray(
          sampleBuffer, false);
  NSNumber *statusValue = attachments.firstObject[SCStreamFrameInfoStatus];
  if (statusValue != nil &&
      statusValue.integerValue != SCFrameStatusComplete) {
    return;
  }
  CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (imageBuffer == NULL) return;

  CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  Float64 seconds = CMTIME_IS_NUMERIC(pts) ? CMTimeGetSeconds(pts) : 0;
  int64_t timestampMs = seconds > 0 ? (int64_t)(seconds * 1000.0) : 0;

  @synchronized(self) {
    if (_disposed || !_externalMode || _engine == nil) return;
    Class sampleClass = NSClassFromString(@"AliRtcVideoDataSample");
    if (sampleClass == Nil) return;
    if (CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly) !=
        kCVReturnSuccess) {
      return;
    }
    id sample = [[sampleClass alloc] init];
    BOOL valid =
        ArtcPopulateLockedBgraVideoSample(sample, imageBuffer, timestampMs);
    int code = 0;
    if (valid) {
      SEL pushSel =
          NSSelectorFromString(@"pushExternalVideoFrame:sourceType:");
      code = ((int (*)(id, SEL, id, NSInteger))objc_msgSend)(
          _engine, pushSel, sample, kArtcVideoSourceScreen);
    }
    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    if (valid && code != 0 && code != kArtcScreenBufferFull) {
      // Transient drop on busy encoder; stream stoppage comes via SCStreamDelegate.
      return;
    }
  }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
  void (^stopped)(NSString *_Nullable) = nil;
  @synchronized(self) {
    if (_disposed) return;
    _disposed = YES;
    _stream = nil;
    ArtcStopEngineScreenPublish(_engine, _externalMode);
    _engine = nil;
    stopped = _onStopped;
    _onStopped = nil;
  }
  if (stopped != nil) {
    dispatch_async(dispatch_get_main_queue(), ^{
      stopped(error.localizedDescription);
    });
  }
}

- (void)stop {
  SCStream *activeStream = nil;
  id activeEngine = nil;
  BOOL wasExternal = NO;
  @synchronized(self) {
    if (_disposed) return;
    _disposed = YES;
    activeStream = _stream;
    _stream = nil;
    activeEngine = _engine;
    _engine = nil;
    wasExternal = _externalMode;
    _onStopped = nil;
  }
  if (activeStream != nil) {
    [activeStream stopCaptureWithCompletionHandler:^(__unused NSError *error){
    }];
  }
  ArtcStopEngineScreenPublish(activeEngine, wasExternal);
}

- (void)dealloc {
  [self stop];
}

@end

@interface ArtcMacosScreenCapture ()
@property(nonatomic, strong, nullable) id activeSession;
@end

@implementation ArtcMacosScreenCapture

+ (void)listSourcesWithCompletion:(ArtcScreenSourcesCallback)completion {
  if (@available(macOS 12.3, *)) {
    if (!ArtcEnsureScreenCapturePermission()) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(nil, @"permission_denied",
                   @"Screen Recording permission is required in System Settings.");
      });
      return;
    }
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:NO
                               onScreenWindowsOnly:YES
                                 completionHandler:^(
                                     SCShareableContent *_Nullable content,
                                     NSError *_Nullable error) {
                                   if (error != nil || content == nil) {
                                     BOOL denied =
                                         !CGPreflightScreenCaptureAccess();
                                     dispatch_async(dispatch_get_main_queue(), ^{
                                       completion(
                                           nil,
                                           denied ? @"permission_denied"
                                                  : @"native_error",
                                           denied
                                               ? @"Screen Recording permission is required in System Settings."
                                               : (error.localizedDescription
                                                      ?: @"Failed to enumerate macOS displays and windows."));
                                     });
                                     return;
                                   }
                                   NSMutableArray<
                                       NSDictionary<NSString *, NSString *> *>
                                       *results = [NSMutableArray array];
                                   NSUInteger displayCount =
                                       content.displays.count;
                                   [content.displays
                                       enumerateObjectsUsingBlock:^(
                                           SCDisplay *display, NSUInteger idx,
                                           __unused BOOL *stop) {
                                         NSString *label =
                                             displayCount == 1
                                                 ? [NSString
                                                       stringWithFormat:
                                                           @"Main Display (%ldx%ld)",
                                                           (long)display.width,
                                                           (long)display.height]
                                                 : [NSString
                                                       stringWithFormat:
                                                           @"Display %lu (%ldx%ld)",
                                                           (unsigned long)(idx +
                                                                           1),
                                                           (long)display.width,
                                                           (long)display.height];
                                         [results addObject:@{
                                           @"id" : [NSString
                                               stringWithFormat:@"display:%u",
                                                                display
                                                                    .displayID],
                                           @"name" : label,
                                           @"kind" : @"display",
                                         }];
                                       }];
                                   pid_t selfPid = NSProcessInfo.processInfo
                                                       .processIdentifier;
                                   for (SCWindow *window in content.windows) {
                                     if (!window.isOnScreen ||
                                         window.windowLayer != 0 ||
                                         window.frame.size.width < 64 ||
                                         window.frame.size.height < 64 ||
                                         window.owningApplication.processID ==
                                             selfPid) {
                                       continue;
                                     }
                                     NSString *appName =
                                         [window.owningApplication
                                                 .applicationName
                                             stringByTrimmingCharactersInSet:
                                                 NSCharacterSet
                                                     .whitespaceAndNewlineCharacterSet]
                                             ?: @"";
                                     NSString *title =
                                         [window.title
                                             stringByTrimmingCharactersInSet:
                                                 NSCharacterSet
                                                     .whitespaceAndNewlineCharacterSet]
                                             ?: @"";
                                     NSString *label = nil;
                                     if (title.length > 0 &&
                                         appName.length > 0 &&
                                         ![title isEqualToString:appName]) {
                                       label = [NSString
                                           stringWithFormat:@"%@ - %@", appName,
                                                            title];
                                     } else if (title.length > 0) {
                                       label = title;
                                     } else if (appName.length > 0) {
                                       label = appName;
                                     } else {
                                       continue;
                                     }
                                     [results addObject:@{
                                       @"id" : [NSString
                                           stringWithFormat:@"window:%u",
                                                            window.windowID],
                                       @"name" : label,
                                       @"kind" : @"window",
                                     }];
                                   }
                                   dispatch_async(dispatch_get_main_queue(), ^{
                                     completion(results, nil, nil);
                                   });
                                 }];
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    completion(nil, @"unsupported_feature",
               @"macOS screen capture requires macOS 12.3 or later.");
  });
}

- (void)startWithSourceId:(NSString *)sourceId
               sourceKind:(NSString *)sourceKind
                   engine:(id)engine
                onStopped:(void (^)(NSString *_Nullable))onStopped
               completion:(ArtcScreenStartCallback)completion {
  if (@available(macOS 12.3, *)) {
    if (engine == nil) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(@"invalid_state", @"ARTC engine is not active.");
      });
      return;
    }
    if (!ArtcEnsureScreenCapturePermission()) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(@"permission_denied",
                   @"Screen Recording permission is required in System Settings.");
      });
      return;
    }
    [self stop];
    ArtcScStreamSession *session =
        [[ArtcScStreamSession alloc] initWithEngine:engine onStopped:onStopped];
    self.activeSession = session;

    [SCShareableContent
        getShareableContentExcludingDesktopWindows:NO
                               onScreenWindowsOnly:YES
                                 completionHandler:^(
                                     SCShareableContent *_Nullable content,
                                     NSError *_Nullable error) {
                                   if (error != nil || content == nil) {
                                     BOOL denied =
                                         !CGPreflightScreenCaptureAccess();
                                     dispatch_async(dispatch_get_main_queue(), ^{
                                       completion(
                                           denied ? @"permission_denied"
                                                  : @"native_error",
                                           denied
                                               ? @"Screen Recording permission is required in System Settings."
                                               : (error.localizedDescription
                                                      ?: @"Failed to read shareable content."));
                                     });
                                     return;
                                   }

                                   SCContentFilter *filter = nil;
                                   NSInteger rawWidth = 0;
                                   NSInteger rawHeight = 0;
                                   uint32_t targetId = 0;
                                   BOOL isWindow = NO;

                                   if (sourceId.length > 0 &&
                                       ([sourceId hasPrefix:@"window:"] ||
                                        [sourceKind isEqualToString:@"window"])) {
                                     NSString *suffix =
                                         [sourceId hasPrefix:@"window:"]
                                             ? [sourceId substringFromIndex:7]
                                             : sourceId;
                                     long long parsed = suffix.longLongValue;
                                     if (parsed <= 0 || parsed > UINT32_MAX) {
                                       dispatch_async(
                                           dispatch_get_main_queue(), ^{
                                             completion(
                                                 @"invalid_argument",
                                                 @"Invalid ARTC window source ID.");
                                           });
                                       return;
                                     }
                                     targetId = (uint32_t)parsed;
                                     isWindow = YES;
                                     SCWindow *matchedWindow = nil;
                                     for (SCWindow *item in content.windows) {
                                       if (item.windowID == targetId) {
                                         matchedWindow = item;
                                         break;
                                       }
                                     }
                                     if (matchedWindow == nil) {
                                       dispatch_async(
                                           dispatch_get_main_queue(), ^{
                                             completion(
                                                 @"invalid_argument",
                                                 @"The selected window is no longer available.");
                                           });
                                       return;
                                     }
                                     filter = [[SCContentFilter alloc]
                                         initWithDesktopIndependentWindow:
                                             matchedWindow];
                                     rawWidth = MAX(
                                         2, (NSInteger)llround(
                                                matchedWindow.frame.size.width));
                                     rawHeight = MAX(
                                         2, (NSInteger)llround(
                                                matchedWindow.frame.size.height));
                                   } else if (sourceId.length > 0) {
                                     NSString *suffix =
                                         [sourceId hasPrefix:@"display:"]
                                             ? [sourceId substringFromIndex:8]
                                             : sourceId;
                                     long long parsed = suffix.longLongValue;
                                     if (parsed <= 0 || parsed > UINT32_MAX) {
                                       dispatch_async(
                                           dispatch_get_main_queue(), ^{
                                             completion(
                                                 @"invalid_argument",
                                                 @"Invalid ARTC display source ID.");
                                           });
                                       return;
                                     }
                                     targetId = (uint32_t)parsed;
                                     SCDisplay *matchedDisplay = nil;
                                     for (SCDisplay *item in content.displays) {
                                       if (item.displayID == targetId) {
                                         matchedDisplay = item;
                                         break;
                                       }
                                     }
                                     if (matchedDisplay == nil) {
                                       dispatch_async(
                                           dispatch_get_main_queue(), ^{
                                             completion(
                                                 @"invalid_argument",
                                                 @"The selected display is no longer available.");
                                           });
                                       return;
                                     }
                                     filter = [[SCContentFilter alloc]
                                          initWithDisplay:matchedDisplay
                                         excludingWindows:@[]];
                                     rawWidth = MAX(2, matchedDisplay.width);
                                     rawHeight = MAX(2, matchedDisplay.height);
                                   } else if (content.displays.firstObject !=
                                              nil) {
                                     SCDisplay *primary =
                                         content.displays.firstObject;
                                     targetId = primary.displayID;
                                     filter = [[SCContentFilter alloc]
                                          initWithDisplay:primary
                                         excludingWindows:@[]];
                                     rawWidth = MAX(2, primary.width);
                                     rawHeight = MAX(2, primary.height);
                                   } else {
                                     dispatch_async(
                                         dispatch_get_main_queue(), ^{
                                           completion(
                                               @"invalid_argument",
                                               @"No shareable display is available.");
                                         });
                                     return;
                                   }

                                   BOOL supportsExternal =
                                       ArtcEngineSupportsExternalScreenInput(
                                           engine);
                                   if (!supportsExternal) {
                                     int fallbackCode =
                                         ArtcStartEngineScreenPublish(
                                             engine, targetId, isWindow, NO);
                                     dispatch_async(
                                         dispatch_get_main_queue(), ^{
                                           if (fallbackCode == 0) {
                                             session.externalMode = NO;
                                             completion(nil, nil);
                                           } else {
                                             [self stop];
                                             completion(
                                                 fallbackCode == -2
                                                     ? @"unsupported_feature"
                                                     : @"native_error",
                                                 @"The installed ARTC macOS framework does not expose screen share publishing.");
                                           }
                                         });
                                     return;
                                   }

                                   SEL setExtSel = NSSelectorFromString(
                                       @"setExternalVideoSource:sourceType:renderMode:");
                                   int extCode =
                                       ((int (*)(id, SEL, BOOL, NSInteger,
                                                 NSUInteger))objc_msgSend)(
                                           engine, setExtSel, YES,
                                           kArtcVideoSourceScreen,
                                           kArtcScreenRenderModeAuto);
                                   if (extCode != 0) {
                                     dispatch_async(
                                         dispatch_get_main_queue(), ^{
                                           [self stop];
                                           completion(
                                               @"native_error",
                                               [NSString
                                                   stringWithFormat:
                                                       @"ARTC rejected external screen video source (%d).",
                                                       extCode]);
                                         });
                                     return;
                                   }
                                   session.externalMode = YES;

                                   int pubCode = ArtcStartEngineScreenPublish(
                                       engine, targetId, isWindow, YES);
                                   if (pubCode != 0) {
                                     ArtcStopEngineScreenPublish(engine, YES);
                                     dispatch_async(
                                         dispatch_get_main_queue(), ^{
                                           [self stop];
                                           completion(
                                               pubCode == -2
                                                   ? @"unsupported_feature"
                                                   : @"native_error",
                                               [NSString
                                                   stringWithFormat:
                                                       @"ARTC failed to start screen share publishing (%d).",
                                                       pubCode]);
                                         });
                                     return;
                                   }

                                   double scale = MIN(
                                       1.0, 1920.0 / (double)MAX(rawWidth,
                                                                 rawHeight));
                                   size_t width = (size_t)MAX(
                                       2,
                                       (((NSInteger)llround((double)rawWidth *
                                                            scale)) /
                                        2) *
                                           2);
                                   size_t height = (size_t)MAX(
                                       2,
                                       (((NSInteger)llround((double)rawHeight *
                                                            scale)) /
                                        2) *
                                           2);

                                   SCStreamConfiguration *config =
                                       [[SCStreamConfiguration alloc] init];
                                   config.width = width;
                                   config.height = height;
                                   config.minimumFrameInterval =
                                       CMTimeMake(1, 15);
                                   config.pixelFormat =
                                       kCVPixelFormatType_32BGRA;
                                   config.showsCursor = YES;
                                   config.queueDepth = 3;

                                   SCStream *stream =
                                       [[SCStream alloc] initWithFilter:filter
                                                          configuration:config
                                                               delegate:session];
                                   NSError *outputError = nil;
                                   if (![stream
                                           addStreamOutput:session
                                                      type:SCStreamOutputTypeScreen
                                        sampleHandlerQueue:session.sampleQueue
                                                     error:&outputError]) {
                                     ArtcStopEngineScreenPublish(engine, YES);
                                     dispatch_async(
                                         dispatch_get_main_queue(), ^{
                                           [self stop];
                                           completion(
                                               @"native_error",
                                               outputError.localizedDescription
                                                   ?: @"Failed to attach ScreenCaptureKit output.");
                                         });
                                     return;
                                   }

                                   @synchronized(session) {
                                     if (session.disposed) {
                                       ArtcStopEngineScreenPublish(engine, YES);
                                       return;
                                     }
                                     session.stream = stream;
                                   }

                                   [stream startCaptureWithCompletionHandler:^(
                                               NSError *_Nullable startError) {
                                     if (startError != nil) {
                                       [session stop];
                                       dispatch_async(
                                           dispatch_get_main_queue(), ^{
                                             if (self.activeSession ==
                                                 session) {
                                               self.activeSession = nil;
                                             }
                                             completion(
                                                 @"native_error",
                                                 startError.localizedDescription
                                                     ?: @"Failed to start macOS screen capture.");
                                           });
                                       return;
                                     }
                                     dispatch_async(
                                         dispatch_get_main_queue(), ^{
                                           completion(nil, nil);
                                         });
                                   }];
                                 }];
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    completion(@"unsupported_feature",
               @"macOS screen capture requires macOS 12.3 or later.");
  });
}

- (void)stop {
  if (@available(macOS 12.3, *)) {
    ArtcScStreamSession *current = (ArtcScStreamSession *)self.activeSession;
    self.activeSession = nil;
    [current stop];
  } else {
    self.activeSession = nil;
  }
}

- (void)dealloc {
  [self stop];
}

@end
