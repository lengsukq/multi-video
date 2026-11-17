#import "FlutterRealtimeMediaArtcPlugin.h"
#import "ArtcMacosScreenCapture.h"
#import "ArtcProcessedVideoInput.h"

#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <objc/message.h>

static NSString *const kArtcMethodChannel =
    @"com.oneplusdream.flutter_realtime_media_artc/methods";
static NSString *const kArtcEventChannel =
    @"com.oneplusdream.flutter_realtime_media_artc/events";
static NSString *const kArtcViewType =
    @"com.oneplusdream.flutter_realtime_media_artc/video";

@class ArtcVideoPlatformView;

@interface FlutterRealtimeMediaArtcPlugin ()
@property(nonatomic, copy, nullable) FlutterEventSink eventSink;
@property(nonatomic, strong, nullable) id engine;
@property(nonatomic, copy, nullable) NSString *localUserId;
@property(nonatomic, assign) BOOL viewer;
@property(nonatomic, assign) BOOL inChannel;
@property(nonatomic, assign) BOOL localVideoEnabled;
@property(nonatomic, copy, nullable) NSString *selectedCameraId;
@property(nonatomic, copy, nullable) NSString *selectedCameraName;
@property(nonatomic, strong) NSHashTable<ArtcVideoPlatformView *> *videoViews;
@property(nonatomic, strong, nullable) ArtcProcessedVideoInput *processedVideo;
@property(nonatomic, strong, nullable) ArtcMacosScreenCapture *screenCapture;
@end

@interface ArtcVideoPlatformView : NSView
@property(nonatomic, copy) NSString *userId;
@property(nonatomic, assign) BOOL local;
@property(nonatomic, assign) BOOL screen;
@property(nonatomic, assign) NSInteger fitMode;
@property(nonatomic, weak) FlutterRealtimeMediaArtcPlugin *plugin;
- (instancetype)initWithUserId:(NSString *)userId
                       isLocal:(BOOL)isLocal
                      isScreen:(BOOL)isScreen
                       fitMode:(NSInteger)fitMode
                        plugin:(FlutterRealtimeMediaArtcPlugin *)plugin;
- (void)attach;
- (void)detach;
@end

@interface ArtcVideoPlatformViewFactory : NSObject <FlutterPlatformViewFactory>
@property(nonatomic, weak) FlutterRealtimeMediaArtcPlugin *plugin;
- (instancetype)initWithPlugin:(FlutterRealtimeMediaArtcPlugin *)plugin;
@end

static int ArtcSendInt0(id target, SEL selector) {
  return ((int (*)(id, SEL))objc_msgSend)(target, selector);
}

static int ArtcSendIntBool(id target, SEL selector, BOOL value) {
  return ((int (*)(id, SEL, BOOL))objc_msgSend)(target, selector, value);
}

static int ArtcSendIntInteger(id target, SEL selector, NSInteger value) {
  return ((int (*)(id, SEL, NSInteger))objc_msgSend)(target, selector, value);
}

static int ArtcSendIntObject(id target, SEL selector, id value) {
  return ((int (*)(id, SEL, id))objc_msgSend)(target, selector, value);
}

static int ArtcSendIntObjectUInteger(
    id target, SEL selector, id value, NSUInteger integerValue) {
  return ((int (*)(id, SEL, id, NSUInteger))objc_msgSend)(
      target, selector, value, integerValue);
}

static int ArtcSendIntObjectObjectUInteger(
    id target, SEL selector, id first, id second, NSUInteger integerValue) {
  return ((int (*)(id, SEL, id, id, NSUInteger))objc_msgSend)(
      target, selector, first, second, integerValue);
}

static NSString *ArtcNormalizeCameraLabel(NSString *label) {
  if (label.length == 0) return @"";
  NSString *trimmed = [label
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  NSRange open = [trimmed rangeOfString:@"(" options:NSBackwardsSearch];
  if (open.location != NSNotFound && [trimmed hasSuffix:@")"]) {
    trimmed = [[trimmed substringToIndex:open.location]
        stringByTrimmingCharactersInSet:NSCharacterSet
                                            .whitespaceAndNewlineCharacterSet];
  }
  return trimmed.lowercaseString;
}

@implementation FlutterRealtimeMediaArtcPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterRealtimeMediaArtcPlugin *instance =
      [[FlutterRealtimeMediaArtcPlugin alloc] init];
  instance.videoViews = [NSHashTable weakObjectsHashTable];

  FlutterMethodChannel *methods =
      [FlutterMethodChannel methodChannelWithName:kArtcMethodChannel
                                 binaryMessenger:registrar.messenger];
  FlutterEventChannel *events =
      [FlutterEventChannel eventChannelWithName:kArtcEventChannel
                                binaryMessenger:registrar.messenger];
  [registrar addMethodCallDelegate:instance channel:methods];
  [events setStreamHandler:instance];
  [registrar registerViewFactory:
                 [[ArtcVideoPlatformViewFactory alloc] initWithPlugin:instance]
                         withId:kArtcViewType];
}

- (FlutterError *)onListenWithArguments:(id)arguments
                              eventSink:(FlutterEventSink)events {
  self.eventSink = events;
  return nil;
}

- (FlutterError *)onCancelWithArguments:(id)arguments {
  self.eventSink = nil;
  return nil;
}

- (void)handleMethodCall:(FlutterMethodCall *)call
                  result:(FlutterResult)result {
  NSDictionary *arguments =
      [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
  if ([call.method isEqualToString:@"isAvailable"]) {
    result(@([self engineClass] != Nil));
  } else if ([call.method isEqualToString:@"probeProcessedVideoInput"]) {
    result(
        @([ArtcProcessedVideoInput isSupportedWithEngineClass:[self engineClass]]));
  } else if ([call.method isEqualToString:@"attachProcessedVideoSource"]) {
    [self attachProcessedVideo:arguments result:result];
  } else if ([call.method isEqualToString:@"detachProcessedVideoSource"]) {
    [self.processedVideo dispose];
    self.processedVideo = nil;
    if (self.inChannel && self.engine != nil && self.localVideoEnabled) {
      ArtcSendIntBool(self.engine, NSSelectorFromString(@"enableLocalVideo:"),
                      YES);
      ArtcSendInt0(self.engine, NSSelectorFromString(@"startPreview"));
    }
    result(nil);
  } else if ([call.method isEqualToString:@"listCameras"]) {
    result([self availableCameras]);
  } else if ([call.method isEqualToString:@"selectCamera"]) {
    [self selectCamera:arguments result:result];
  } else if ([call.method isEqualToString:@"switchCamera"]) {
    [self switchCamera:arguments result:result];
  } else if ([call.method isEqualToString:@"listScreenShareSources"]) {
    [self listScreenShareSources:result];
  } else if ([call.method isEqualToString:@"setScreenShareEnabled"]) {
    [self setScreenShareEnabled:arguments result:result];
  } else if ([call.method isEqualToString:@"join"]) {
    [self join:arguments result:result];
  } else if ([call.method isEqualToString:@"leave"]) {
    [self leave:result];
  } else if ([call.method isEqualToString:@"setMuted"]) {
    [self setMuted:[arguments[@"muted"] boolValue] result:result];
  } else if ([call.method isEqualToString:@"setVideoEnabled"]) {
    [self setVideoEnabled:[arguments[@"enabled"] boolValue] result:result];
  } else if ([call.method isEqualToString:@"sendMessage"]) {
    [self sendMessage:arguments result:result];
  } else if ([call.method isEqualToString:@"dispose"]) {
    [self disposeEngine];
    result(nil);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (Class)engineClass {
  Class type = NSClassFromString(@"AliRtcEngine");
  if (type == Nil) type = NSClassFromString(@"AliRTCEngine");
  return type;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)availableCameras {
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *cameras =
      [NSMutableArray array];
  NSMutableSet<NSString *> *seenIds = [NSMutableSet set];

  AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession
      discoverySessionWithDeviceTypes:@[
        AVCaptureDeviceTypeBuiltInWideAngleCamera,
        AVCaptureDeviceTypeExternalUnknown
      ]
                            mediaType:AVMediaTypeVideo
                             position:AVCaptureDevicePositionUnspecified];
  for (AVCaptureDevice *device in discovery.devices) {
    NSString *deviceId = device.uniqueID ?: @"";
    NSString *label = device.localizedName ?: @"";
    if (deviceId.length == 0) continue;
    [seenIds addObject:deviceId];
    [cameras addObject:@{
      @"id" : deviceId,
      @"label" : label.length > 0 ? label : deviceId,
    }];
  }

  SEL getCamerasSel = NSSelectorFromString(@"getCameraList");
  if (self.engine != nil && [self.engine respondsToSelector:getCamerasSel]) {
    id rawList = ((id(*)(id, SEL))objc_msgSend)(self.engine, getCamerasSel);
    if ([rawList isKindOfClass:NSArray.class]) {
      for (id item in (NSArray *)rawList) {
        NSString *itemId = nil;
        NSString *itemName = nil;
        if ([item isKindOfClass:NSString.class]) {
          itemId = item;
          itemName = item;
        } else {
          SEL idSel = NSSelectorFromString(@"deviceID");
          SEL nameSel = NSSelectorFromString(@"deviceName");
          if ([item respondsToSelector:idSel]) {
            id v = ((id(*)(id, SEL))objc_msgSend)(item, idSel);
            if ([v isKindOfClass:NSString.class]) itemId = v;
          }
          if ([item respondsToSelector:nameSel]) {
            id v = ((id(*)(id, SEL))objc_msgSend)(item, nameSel);
            if ([v isKindOfClass:NSString.class]) itemName = v;
          }
        }
        if (itemId.length == 0 && itemName.length > 0) itemId = itemName;
        if (itemId.length == 0 || [seenIds containsObject:itemId]) continue;
        NSString *normName = ArtcNormalizeCameraLabel(itemName ?: itemId);
        BOOL duplicateByName = NO;
        for (NSDictionary<NSString *, NSString *> *existing in cameras) {
          if (normName.length > 0 &&
              [ArtcNormalizeCameraLabel(existing[@"label"])
                  isEqualToString:normName]) {
            duplicateByName = YES;
            break;
          }
        }
        if (!duplicateByName) {
          [seenIds addObject:itemId];
          [cameras addObject:@{
            @"id" : itemId,
            @"label" : itemName.length > 0 ? itemName : itemId,
          }];
        }
      }
    }
  }
  return cameras;
}

- (int)applyCameraOnEngineWithId:(NSString *)cameraId
                           label:(NSString *)cameraLabel {
  if (self.engine == nil || self.processedVideo != nil) return 0;
  NSArray<NSString *> *idSelectors = @[
    @"setCurrentCameraID:",
    @"setCurrentCameraWithID:",
  ];
  for (NSString *name in idSelectors) {
    SEL sel = NSSelectorFromString(name);
    if ([self.engine respondsToSelector:sel] && cameraId.length > 0) {
      int code = ArtcSendIntObject(self.engine, sel, cameraId);
      if (code == 0) return 0;
    }
  }
  SEL setByNameSel = NSSelectorFromString(@"setCurrentCamera:");
  if ([self.engine respondsToSelector:setByNameSel]) {
    if (cameraLabel.length > 0) {
      int code = ArtcSendIntObject(self.engine, setByNameSel, cameraLabel);
      if (code == 0) return 0;
    }
    if (cameraId.length > 0) {
      int code = ArtcSendIntObject(self.engine, setByNameSel, cameraId);
      if (code == 0) return 0;
    }
    return -1;
  }
  return 0;
}

- (void)selectCamera:(NSDictionary *)arguments result:(FlutterResult)result {
  if (![self requirePublisher:result]) return;
  NSString *requestedId = [self string:arguments key:@"deviceId"];
  NSString *requestedLabel = [self string:arguments key:@"label"];
  if (requestedId.length == 0 && requestedLabel.length == 0) {
    result([FlutterError errorWithCode:@"invalid_argument"
                               message:@"A camera deviceId is required."
                               details:nil]);
    return;
  }
  NSArray<NSDictionary<NSString *, NSString *> *> *cameras =
      [self availableCameras];
  if (cameras.count == 0) {
    result([FlutterError errorWithCode:@"unsupported_feature"
                               message:@"No camera devices are available on this Mac."
                               details:nil]);
    return;
  }
  NSDictionary<NSString *, NSString *> *matched = nil;
  for (NSDictionary<NSString *, NSString *> *item in cameras) {
    if (requestedId.length > 0 && [item[@"id"] isEqualToString:requestedId]) {
      matched = item;
      break;
    }
  }
  if (matched == nil) {
    NSString *normReqLabel = ArtcNormalizeCameraLabel(requestedLabel);
    NSString *normReqId = ArtcNormalizeCameraLabel(requestedId);
    for (NSDictionary<NSString *, NSString *> *item in cameras) {
      NSString *itemLabel = item[@"label"] ?: @"";
      NSString *normItem = ArtcNormalizeCameraLabel(itemLabel);
      if ((requestedId.length > 0 && [itemLabel isEqualToString:requestedId]) ||
          (requestedLabel.length > 0 &&
           [itemLabel isEqualToString:requestedLabel]) ||
          (normReqLabel.length > 0 && [normItem isEqualToString:normReqLabel]) ||
          (normReqId.length > 0 && [normItem isEqualToString:normReqId])) {
        matched = item;
        break;
      }
    }
  }
  if (matched == nil) {
    result([FlutterError errorWithCode:@"invalid_argument"
                               message:@"The requested camera is not available."
                               details:nil]);
    return;
  }
  int code =
      [self applyCameraOnEngineWithId:matched[@"id"] label:matched[@"label"]];
  if (code != 0) {
    [self failNative:result
             message:@"ARTC failed to select the requested camera"
                code:code];
    return;
  }
  self.selectedCameraId = matched[@"id"];
  self.selectedCameraName = matched[@"label"];
  result(nil);
}

- (void)switchCamera:(NSDictionary *)arguments result:(FlutterResult)result {
  if (![self requirePublisher:result]) return;
  NSArray<NSDictionary<NSString *, NSString *> *> *cameras =
      [self availableCameras];
  if (cameras.count == 0) {
    SEL mobileSwitch = NSSelectorFromString(@"switchCamera");
    if ([self.engine respondsToSelector:mobileSwitch]) {
      int code = ArtcSendInt0(self.engine, mobileSwitch);
      [self complete:code
              result:result
             message:@"ARTC failed to switch camera"];
      return;
    }
    result([FlutterError errorWithCode:@"unsupported_feature"
                               message:@"No camera devices are available on this Mac."
                               details:nil]);
    return;
  }

  NSString *position = [[self string:arguments key:@"position"] lowercaseString];
  NSUInteger currentIndex = 0;
  BOOL foundCurrent = NO;
  if (self.selectedCameraId.length > 0) {
    for (NSUInteger i = 0; i < cameras.count; i++) {
      if ([cameras[i][@"id"] isEqualToString:self.selectedCameraId]) {
        currentIndex = i;
        foundCurrent = YES;
        break;
      }
    }
  }
  NSDictionary<NSString *, NSString *> *target = nil;
  if (cameras.count > 1 &&
      ([position isEqualToString:@"front"] ||
       [position isEqualToString:@"back"])) {
    for (NSUInteger i = 0; i < cameras.count; i++) {
      if (foundCurrent && i == currentIndex) continue;
      NSString *lower = [cameras[i][@"label"] lowercaseString];
      BOOL isFront = [lower containsString:@"facetime"] ||
                     [lower containsString:@"built-in"] ||
                     [lower containsString:@"front"] ||
                     [lower containsString:@"前置"] ||
                     [lower containsString:@"内建"];
      BOOL isBack = [lower containsString:@"usb"] ||
                    [lower containsString:@"external"] ||
                    [lower containsString:@"back"] ||
                    [lower containsString:@"rear"] ||
                    [lower containsString:@"后置"] ||
                    [lower containsString:@"外接"];
      if (([position isEqualToString:@"front"] && isFront) ||
          ([position isEqualToString:@"back"] && isBack)) {
        target = cameras[i];
        break;
      }
    }
  }
  if (target == nil) {
    NSUInteger nextIndex =
        cameras.count > 1 ? (currentIndex + 1) % cameras.count : 0;
    target = cameras[nextIndex];
  }
  int code =
      [self applyCameraOnEngineWithId:target[@"id"] label:target[@"label"]];
  if (code != 0) {
    [self failNative:result message:@"ARTC failed to switch camera" code:code];
    return;
  }
  self.selectedCameraId = target[@"id"];
  self.selectedCameraName = target[@"label"];
  result(nil);
}

- (void)listScreenShareSources:(FlutterResult)result {
  if (![self requirePublisher:result]) return;
  [ArtcMacosScreenCapture
      listSourcesWithCompletion:^(
          NSArray<NSDictionary<NSString *, NSString *> *> *_Nullable sources,
          NSString *_Nullable errorCode, NSString *_Nullable errorMessage) {
        if (errorCode != nil) {
          result([FlutterError errorWithCode:errorCode
                                     message:errorMessage
                                     details:nil]);
          return;
        }
        result(sources ?: @[]);
      }];
}

- (void)setScreenShareEnabled:(NSDictionary *)arguments
                       result:(FlutterResult)result {
  if (![self requirePublisher:result]) return;
  BOOL enabled = [arguments[@"enabled"] boolValue];
  if (!enabled) {
    if (self.screenCapture != nil) {
      [self.screenCapture stop];
      self.screenCapture = nil;
    } else if (self.engine != nil) {
      SEL stopSel = NSSelectorFromString(@"stopScreenShare");
      if ([self.engine respondsToSelector:stopSel]) {
        ArtcSendInt0(self.engine, stopSel);
      }
    }
    [self emit:@{@"type" : @"localScreenChanged", @"available" : @NO}];
    result(nil);
    return;
  }

  [self.screenCapture stop];
  ArtcMacosScreenCapture *capture = [[ArtcMacosScreenCapture alloc] init];
  self.screenCapture = capture;
  NSString *sourceId = [self string:arguments key:@"sourceId"];
  NSString *sourceKind = [self string:arguments key:@"sourceKind"];
  __weak FlutterRealtimeMediaArtcPlugin *weakSelf = self;
  [capture startWithSourceId:(sourceId.length > 0 ? sourceId : nil)
                  sourceKind:(sourceKind.length > 0 ? sourceKind : nil)
                      engine:self.engine
                   onStopped:^(__unused NSString *_Nullable errorMessage) {
                     FlutterRealtimeMediaArtcPlugin *strongSelf = weakSelf;
                     if (strongSelf == nil) return;
                     if (strongSelf.screenCapture == capture) {
                       strongSelf.screenCapture = nil;
                     }
                     [strongSelf emit:@{
                       @"type" : @"localScreenChanged",
                       @"available" : @NO
                     }];
                   }
                  completion:^(NSString *_Nullable errorCode,
                               NSString *_Nullable errorMessage) {
                    FlutterRealtimeMediaArtcPlugin *strongSelf = weakSelf;
                    if (errorCode != nil) {
                      if (strongSelf != nil &&
                          strongSelf.screenCapture == capture) {
                        strongSelf.screenCapture = nil;
                      }
                      result([FlutterError errorWithCode:errorCode
                                                 message:errorMessage
                                                 details:nil]);
                      return;
                    }
                    [strongSelf emit:@{
                      @"type" : @"localScreenChanged",
                      @"available" : @YES
                    }];
                    result(nil);
                  }];
}

- (void)join:(NSDictionary *)values result:(FlutterResult)result {
  if (self.inChannel) {
    result([FlutterError errorWithCode:@"invalid_state"
                               message:@"Leave the current ARTC channel before joining another."
                               details:nil]);
    return;
  }
  Class engineClass = [self engineClass];
  if (engineClass == Nil) {
    result([FlutterError errorWithCode:@"unsupported_platform"
                               message:@"Alibaba ARTC macOS framework is not bundled with this SDK build."
                               details:@{@"expectedFramework" : @"AliRTCSdk.framework"}]);
    return;
  }

  NSString *channelId = [self string:values key:@"channelId"];
  NSString *userId = [self string:values key:@"userId"];
  NSString *authInfo = [self string:values key:@"authInfo"];
  NSString *displayName = [self string:values key:@"displayName"];
  NSString *role = [self string:values key:@"role"];
  NSString *roomMode = [self string:values key:@"roomMode"];
  if (channelId.length == 0 || userId.length == 0 || authInfo.length == 0 ||
      !([role isEqualToString:@"participant"] ||
        [role isEqualToString:@"host"] ||
        [role isEqualToString:@"viewer"])) {
    result([FlutterError errorWithCode:@"invalid_join_info"
                               message:@"ARTC macOS join data is incomplete."
                               details:nil]);
    return;
  }

  SEL shared = NSSelectorFromString(@"sharedInstance:extras:");
  if (![engineClass respondsToSelector:shared]) {
    result([FlutterError errorWithCode:@"unsupported_platform"
                               message:@"The bundled ARTC macOS framework does not expose AliRtcEngine.sharedInstance."
                               details:nil]);
    return;
  }
  self.engine =
      ((id(*)(id, SEL, id, id))objc_msgSend)(engineClass, shared, self, nil);
  if (self.engine == nil) {
    result([FlutterError errorWithCode:@"native_error"
                               message:@"ARTC failed to create the macOS engine."
                               details:nil]);
    return;
  }

  self.viewer = [role isEqualToString:@"viewer"];
  self.localUserId = userId;
  self.localVideoEnabled = NO;
  BOOL interactive = ![role isEqualToString:@"participant"] ||
                     [roomMode isEqualToString:@"interactiveLive"];

  int code = ArtcSendIntInteger(
      self.engine, NSSelectorFromString(@"setChannelProfile:"),
      interactive ? 1 : 0);
  if (code != 0) {
    [self failNative:result message:@"ARTC rejected the channel profile" code:code];
    return;
  }
  if (interactive) {
    code = ArtcSendIntInteger(
        self.engine, NSSelectorFromString(@"setClientRole:"),
        self.viewer ? 1 : 0);
    if (code != 0) {
      [self failNative:result message:@"ARTC rejected the client role" code:code];
      return;
    }
  }

  ArtcSendIntBool(self.engine,
                  NSSelectorFromString(@"publishLocalAudioStream:"), NO);
  ArtcSendIntBool(self.engine,
                  NSSelectorFromString(@"publishLocalVideoStream:"), NO);
  ArtcSendIntBool(self.engine,
                  NSSelectorFromString(@"enableLocalVideo:"), NO);

  SEL joinSelector =
      NSSelectorFromString(@"joinChannel:channelId:userId:name:onResultWithUserId:");
  if (![self.engine respondsToSelector:joinSelector]) {
    result([FlutterError errorWithCode:@"unsupported_platform"
                               message:@"The bundled ARTC macOS framework has an incompatible join API."
                               details:nil]);
    return;
  }
  int joinCode =
      ((int (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
          self.engine, joinSelector, authInfo, channelId, userId,
          displayName.length == 0 ? userId : displayName, nil);
  if (joinCode != 0) {
    [self failNative:result message:@"ARTC failed to start joining" code:joinCode];
    return;
  }
  self.inChannel = YES;
  for (ArtcVideoPlatformView *view in self.videoViews) [view attach];
  result(nil);
}

- (void)leave:(FlutterResult)result {
  [self.screenCapture stop];
  self.screenCapture = nil;
  [self.processedVideo dispose];
  self.processedVideo = nil;
  self.localVideoEnabled = NO;
  if (self.engine == nil || !self.inChannel) {
    result(nil);
    return;
  }
  int code = ArtcSendInt0(self.engine, NSSelectorFromString(@"leaveChannel"));
  self.inChannel = NO;
  for (ArtcVideoPlatformView *view in self.videoViews) [view detach];
  if (code == 0) {
    result(nil);
  } else {
    [self failNative:result message:@"ARTC failed to leave the channel" code:code];
  }
}

- (void)setMuted:(BOOL)muted result:(FlutterResult)result {
  if (![self requirePublisher:result]) return;
  if (!muted && ![self ensurePermission:AVMediaTypeAudio result:result]) return;
  int code = ArtcSendIntBool(
      self.engine, NSSelectorFromString(@"publishLocalAudioStream:"), !muted);
  [self complete:code result:result message:@"ARTC failed to update audio publishing"];
}

- (void)setVideoEnabled:(BOOL)enabled result:(FlutterResult)result {
  if (![self requirePublisher:result]) return;
  if (enabled && ![self ensurePermission:AVMediaTypeVideo result:result]) return;
  if (enabled && self.processedVideo == nil && self.selectedCameraId.length > 0) {
    [self applyCameraOnEngineWithId:self.selectedCameraId
                              label:self.selectedCameraName ?: @""];
  }
  int capture = ArtcSendIntBool(
      self.engine, NSSelectorFromString(@"enableLocalVideo:"),
      enabled && self.processedVideo == nil);
  int publish = capture == 0
                    ? ArtcSendIntBool(
                          self.engine,
                          NSSelectorFromString(@"publishLocalVideoStream:"),
                          enabled)
                    : capture;
  if (publish == 0) {
    self.localVideoEnabled = enabled;
    if (enabled && self.processedVideo == nil) {
      ArtcSendInt0(self.engine, NSSelectorFromString(@"startPreview"));
    } else if (!enabled) {
      ArtcSendInt0(self.engine, NSSelectorFromString(@"stopPreview"));
    }
  }
  [self complete:publish result:result message:@"ARTC failed to update video publishing"];
}

- (void)attachProcessedVideo:(NSDictionary *)arguments result:(FlutterResult)result {
  if (![self requirePublisher:result]) return;
  if (![ArtcProcessedVideoInput isSupportedWithEngineClass:[self engineClass]]) {
    result([FlutterError errorWithCode:@"unsupported_feature"
      message:@"The installed ARTC macOS framework does not provide a compatible external video input."
      details:nil]);
    return;
  }
  NSString *sourceId = [self string:arguments key:@"sourceId"];
  if (!sourceId.length) {
    result([FlutterError errorWithCode:@"invalid_argument"
                               message:@"A processed source ID is required."
                               details:nil]);
    return;
  }
  [self.processedVideo dispose];
  self.processedVideo = nil;
  ArtcSendInt0(self.engine, NSSelectorFromString(@"stopPreview"));
  ArtcSendIntBool(self.engine, NSSelectorFromString(@"enableLocalVideo:"), NO);
  __weak FlutterRealtimeMediaArtcPlugin *weakSelf = self;
  self.processedVideo = [[ArtcProcessedVideoInput alloc]
      initWithSourceId:sourceId
                engine:self.engine
             onFailure:^(NSString *message) {
               FlutterRealtimeMediaArtcPlugin *strongSelf = weakSelf;
               if (strongSelf == nil) return;
               strongSelf.processedVideo = nil;
               strongSelf.localVideoEnabled = NO;
               [strongSelf emit:@{
                 @"type" : @"error",
                 @"code" : @-1,
                 @"message" : message
               }];
             }];
  if (!self.processedVideo) {
    ArtcSendIntBool(self.engine,
                    NSSelectorFromString(@"publishLocalVideoStream:"), NO);
    self.localVideoEnabled = NO;
    result([FlutterError errorWithCode:@"attach_provider_failed"
                               message:@"ARTC rejected the processed video source."
                               details:nil]);
    return;
  }
  result(nil);
}

- (void)sendMessage:(NSDictionary *)values result:(FlutterResult)result {
  if (![self requirePublisher:result]) return;
  Class messageClass = NSClassFromString(@"AliRtcDataChannelMsg");
  if (messageClass == Nil) {
    result([FlutterError errorWithCode:@"unsupported_feature"
                               message:@"The ARTC macOS framework does not expose data-channel messages."
                               details:nil]);
    return;
  }
  NSDictionary *envelope = @{
    @"topic" : [self string:values key:@"topic"],
    @"message" : [self string:values key:@"message"],
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
  id message = [[messageClass alloc] init];
  [message setValue:@2 forKey:@"type"];
  [message setValue:data forKey:@"data"];
  int code = ArtcSendIntObject(
      self.engine, NSSelectorFromString(@"sendDataChannelMessage:"), message);
  [self complete:code result:result message:@"ARTC failed to send the data message"];
}

- (BOOL)requirePublisher:(FlutterResult)result {
  if (self.engine == nil || !self.inChannel) {
    result([FlutterError errorWithCode:@"invalid_state"
                               message:@"ARTC controls require an active channel."
                               details:nil]);
    return NO;
  }
  if (self.viewer) {
    result([FlutterError errorWithCode:@"unsupported_feature"
                               message:@"ARTC viewer sessions cannot publish media or data."
                               details:nil]);
    return NO;
  }
  return YES;
}

- (BOOL)ensurePermission:(AVMediaType)mediaType result:(FlutterResult)result {
  AVAuthorizationStatus status =
      [AVCaptureDevice authorizationStatusForMediaType:mediaType];
  if (status == AVAuthorizationStatusAuthorized) return YES;
  if (status == AVAuthorizationStatusNotDetermined) {
    [AVCaptureDevice requestAccessForMediaType:mediaType
                             completionHandler:^(BOOL granted) {
      if (!granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
          result([FlutterError errorWithCode:@"permission_denied"
                                     message:@"Camera or microphone permission was denied."
                                     details:nil]);
        });
      }
    }];
    return NO;
  }
  result([FlutterError errorWithCode:@"permission_denied"
                             message:@"Camera or microphone permission is denied in System Settings."
                             details:nil]);
  return NO;
}

- (void)disposeEngine {
  [self.screenCapture stop];
  self.screenCapture = nil;
  [self.processedVideo dispose];
  self.processedVideo = nil;
  for (ArtcVideoPlatformView *view in self.videoViews) [view detach];
  self.inChannel = NO;
  self.localVideoEnabled = NO;
  self.selectedCameraId = nil;
  self.selectedCameraName = nil;
  self.localUserId = nil;
  self.engine = nil;
  Class engineClass = [self engineClass];
  SEL destroy = NSSelectorFromString(@"destroy");
  if (engineClass != Nil && [engineClass respondsToSelector:destroy]) {
    ((void(*)(id, SEL))objc_msgSend)(engineClass, destroy);
  }
}

- (void)complete:(NSInteger)code
          result:(FlutterResult)result
         message:(NSString *)message {
  if (code == 0) {
    result(nil);
  } else {
    [self failNative:result message:message code:code];
  }
}

- (void)failNative:(FlutterResult)result
            message:(NSString *)message
               code:(NSInteger)code {
  result([FlutterError errorWithCode:@"native_error"
                             message:[NSString stringWithFormat:@"%@ (%ld).",
                                                               message,
                                                               (long)code]
                             details:@{@"code" : @(code)}]);
}

- (NSString *)string:(NSDictionary *)values key:(NSString *)key {
  id value = values[key];
  return [value isKindOfClass:NSString.class] ? value : @"";
}

- (void)emit:(NSDictionary *)event {
  FlutterEventSink sink = self.eventSink;
  if (sink == nil) return;
  dispatch_async(dispatch_get_main_queue(), ^{ sink(event); });
}

- (void)addVideoView:(ArtcVideoPlatformView *)view {
  [self.videoViews addObject:view];
  if (self.inChannel) [view attach];
}

- (void)removeVideoView:(ArtcVideoPlatformView *)view {
  [view detach];
  [self.videoViews removeObject:view];
}

- (void)attachView:(ArtcVideoPlatformView *)view {
  if (self.engine == nil || !self.inChannel) return;
  Class canvasClass = NSClassFromString(@"AliVideoCanvas");
  if (canvasClass == Nil) return;
  id canvas = [[canvasClass alloc] init];
  [canvas setValue:view forKey:@"view"];
  // AliRtcRenderModeFill (2) preserves the full frame; Crop (3) fills the view.
  [canvas setValue:@(view.fitMode == 1 ? 2 : 3) forKey:@"renderMode"];
  NSUInteger source = view.screen ? 2 : 1;
  if (view.local) {
    ArtcSendIntObjectUInteger(
        self.engine, NSSelectorFromString(@"setLocalViewConfig:forTrack:"),
        canvas, source);
    if (self.processedVideo == nil && !view.screen && self.localVideoEnabled) {
      ArtcSendInt0(self.engine, NSSelectorFromString(@"startPreview"));
    }
  } else {
    ArtcSendIntObjectObjectUInteger(
        self.engine, NSSelectorFromString(@"setRemoteViewConfig:uid:forTrack:"),
        canvas, view.userId, source);
  }
}

- (void)detachView:(ArtcVideoPlatformView *)view {
  if (self.engine == nil) return;
  NSUInteger source = view.screen ? 2 : 1;
  if (view.local) {
    ArtcSendIntObjectUInteger(
        self.engine, NSSelectorFromString(@"setLocalViewConfig:forTrack:"),
        nil, source);
  } else {
    ArtcSendIntObjectObjectUInteger(
        self.engine, NSSelectorFromString(@"setRemoteViewConfig:uid:forTrack:"),
        nil, view.userId, source);
  }
}

#pragma mark - AliRtcEngine delegate selectors

- (void)onJoinChannelResult:(int)result
                    channel:(NSString *)channel
                     userId:(NSString *)userId
                    elapsed:(int)elapsed {
  if (result != 0) {
    self.inChannel = NO;
    [self emit:@{@"type" : @"error",
                 @"code" : @(result),
                 @"message" : @"ARTC failed to join the channel."}];
  }
}

- (void)onRemoteUserOnLineNotify:(NSString *)uid elapsed:(int)elapsed {
  [self emit:@{@"type" : @"participantJoined", @"userId" : uid ?: @""}];
}

- (void)onRemoteUserOffLineNotify:(NSString *)uid
                    offlineReason:(NSInteger)reason {
  [self emit:@{@"type" : @"participantLeft", @"userId" : uid ?: @""}];
}

- (void)onRemoteTrackAvailableNotify:(NSString *)uid
                          audioTrack:(NSUInteger)audioTrack
                          videoTrack:(NSUInteger)videoTrack {
  [self emit:@{@"type" : @"audioChanged",
               @"userId" : uid ?: @"",
               @"available" : @(audioTrack != 0)}];
  [self emit:@{@"type" : @"videoChanged",
               @"userId" : uid ?: @"",
               @"available" : @((videoTrack & 1) != 0)}];
  [self emit:@{@"type" : @"screenChanged",
               @"userId" : uid ?: @"",
               @"available" : @((videoTrack & 2) != 0)}];
}

- (void)onScreenSharePublishStateChanged:(NSInteger)oldState
                                newState:(NSInteger)newState
                    elapseSinceLastState:(NSInteger)elapseSinceLastState
                                 channel:(NSString *)channel {
  if (newState == 3) {
    [self emit:@{@"type" : @"localScreenChanged", @"available" : @YES}];
  } else if (newState == 1 && self.screenCapture == nil) {
    [self emit:@{@"type" : @"localScreenChanged", @"available" : @NO}];
  }
}

- (void)onDataChannelMessage:(NSString *)uid controlMsg:(id)message {
  NSData *data = nil;
  @try {
    data = [message valueForKey:@"data"];
  } @catch (__unused NSException *exception) {
    data = nil;
  }
  NSString *text =
      [data isKindOfClass:NSData.class]
          ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
          : @"";
  [self emit:@{@"type" : @"message",
               @"userId" : uid ?: @"",
               @"data" : text ?: @""}];
}

- (void)onAuthInfoWillExpire {
  [self emit:@{@"type" : @"authWillExpire"}];
}

- (void)onAuthInfoExpired {
  [self emit:@{@"type" : @"authWillExpire"}];
}

- (void)onConnectionStatusChange:(NSInteger)status reason:(NSInteger)reason {
  if (status == 2) {
    [self emit:@{@"type" : @"recovered"}];
  } else if (status == 3 || status == 4) {
    [self emit:@{@"type" : @"reconnecting"}];
  }
}

- (void)onOccurError:(int)error message:(NSString *)message {
  [self emit:@{@"type" : @"error",
               @"code" : @(error),
               @"message" : message ?: @"ARTC reported an error."}];
}

@end

@implementation ArtcVideoPlatformView

- (instancetype)initWithUserId:(NSString *)userId
                       isLocal:(BOOL)isLocal
                      isScreen:(BOOL)isScreen
                       fitMode:(NSInteger)fitMode
                        plugin:(FlutterRealtimeMediaArtcPlugin *)plugin {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _userId = [userId copy];
    _local = isLocal;
    _screen = isScreen;
    _fitMode = fitMode;
    _plugin = plugin;
    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.blackColor.CGColor;
    [plugin addVideoView:self];
  }
  return self;
}

- (void)attach {
  [self.plugin attachView:self];
}

- (void)detach {
  [self.plugin detachView:self];
}

- (void)dealloc {
  [self.plugin removeVideoView:self];
}

@end

@implementation ArtcVideoPlatformViewFactory

- (instancetype)initWithPlugin:(FlutterRealtimeMediaArtcPlugin *)plugin {
  self = [super init];
  if (self) _plugin = plugin;
  return self;
}

- (NSView *)createWithViewIdentifier:(int64_t)viewId arguments:(id)args {
  NSDictionary *values = [args isKindOfClass:NSDictionary.class] ? args : @{};
  return [[ArtcVideoPlatformView alloc]
      initWithUserId:[values[@"userId"] isKindOfClass:NSString.class]
                         ? values[@"userId"]
                         : @""
           isLocal:[values[@"isLocal"] boolValue]
          isScreen:[values[@"isScreenShare"] boolValue]
           fitMode:(values[@"fitMode"] != nil ? [values[@"fitMode"] integerValue] : 1)
            plugin:self.plugin];
}

- (NSObject<FlutterMessageCodec> *)createArgsCodec {
  return FlutterStandardMessageCodec.sharedInstance;
}

@end
