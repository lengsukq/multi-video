#import "FlutterRealtimeMediaArtcPlugin.h"
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
@property(nonatomic, strong) NSHashTable<ArtcVideoPlatformView *> *videoViews;
@property(nonatomic, strong, nullable) ArtcProcessedVideoInput *processedVideo;
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

static NSInteger ArtcSendInt0(id target, SEL selector) {
  return ((NSInteger(*)(id, SEL))objc_msgSend)(target, selector);
}

static NSInteger ArtcSendIntBool(id target, SEL selector, BOOL value) {
  return ((NSInteger(*)(id, SEL, BOOL))objc_msgSend)(target, selector, value);
}

static NSInteger ArtcSendIntInteger(id target, SEL selector, NSInteger value) {
  return ((NSInteger(*)(id, SEL, NSInteger))objc_msgSend)(target, selector, value);
}

static NSInteger ArtcSendIntObject(id target, SEL selector, id value) {
  return ((NSInteger(*)(id, SEL, id))objc_msgSend)(target, selector, value);
}

static NSInteger ArtcSendIntObjectInteger(
    id target, SEL selector, id value, NSInteger integerValue) {
  return ((NSInteger(*)(id, SEL, id, NSInteger))objc_msgSend)(
      target, selector, value, integerValue);
}

static NSInteger ArtcSendIntObjectObjectInteger(
    id target, SEL selector, id first, id second, NSInteger integerValue) {
  return ((NSInteger(*)(id, SEL, id, id, NSInteger))objc_msgSend)(
      target, selector, first, second, integerValue);
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
    result(@([ArtcProcessedVideoInput isSupportedWithEngineClass:[self engineClass]]));
  } else if ([call.method isEqualToString:@"attachProcessedVideoSource"]) {
    [self attachProcessedVideo:arguments result:result];
  } else if ([call.method isEqualToString:@"detachProcessedVideoSource"]) {
    [self.processedVideo dispose]; self.processedVideo = nil; result(nil);
  } else if ([call.method isEqualToString:@"join"]) {
    [self join:arguments result:result];
  } else if ([call.method isEqualToString:@"leave"]) {
    [self leave:result];
  } else if ([call.method isEqualToString:@"setMuted"]) {
    [self setMuted:[arguments[@"muted"] boolValue] result:result];
  } else if ([call.method isEqualToString:@"setVideoEnabled"]) {
    [self setVideoEnabled:[arguments[@"enabled"] boolValue] result:result];
  } else if ([call.method isEqualToString:@"switchCamera"]) {
    result([FlutterError errorWithCode:@"unsupported_feature"
                               message:@"ARTC macOS does not expose a front/back camera switch."
                               details:nil]);
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
  BOOL interactive = ![role isEqualToString:@"participant"] ||
                     [roomMode isEqualToString:@"interactiveLive"];

  NSInteger code = ArtcSendIntInteger(
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
  NSInteger joinCode =
      ((NSInteger(*)(id, SEL, id, id, id, id, id))objc_msgSend)(
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
  [self.processedVideo dispose]; self.processedVideo = nil;
  if (self.engine == nil || !self.inChannel) {
    result(nil);
    return;
  }
  NSInteger code =
      ArtcSendInt0(self.engine, NSSelectorFromString(@"leaveChannel"));
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
  NSInteger code = ArtcSendIntBool(
      self.engine, NSSelectorFromString(@"publishLocalAudioStream:"), !muted);
  [self complete:code result:result message:@"ARTC failed to update audio publishing"];
}

- (void)setVideoEnabled:(BOOL)enabled result:(FlutterResult)result {
  if (![self requirePublisher:result]) return;
  if (enabled && ![self ensurePermission:AVMediaTypeVideo result:result]) return;
  NSInteger capture = ArtcSendIntBool(
      self.engine, NSSelectorFromString(@"enableLocalVideo:"), enabled && self.processedVideo == nil);
  NSInteger publish = capture == 0
                          ? ArtcSendIntBool(
                                self.engine,
                                NSSelectorFromString(@"publishLocalVideoStream:"),
                                enabled)
                          : capture;
  if (enabled && publish == 0 && self.processedVideo == nil) {
    ArtcSendInt0(self.engine, NSSelectorFromString(@"startPreview"));
  }
  [self complete:publish result:result message:@"ARTC failed to update video publishing"];
}

- (void)attachProcessedVideo:(NSDictionary *)arguments result:(FlutterResult)result {
  if (![self requirePublisher:result]) return;
  if (![ArtcProcessedVideoInput isSupportedWithEngineClass:[self engineClass]]) {
    result([FlutterError errorWithCode:@"unsupported_feature"
      message:@"The installed ARTC macOS framework does not provide a compatible external video input."
      details:nil]); return;
  }
  NSString *sourceId = [self string:arguments key:@"sourceId"];
  if (!sourceId.length) {
    result([FlutterError errorWithCode:@"invalid_argument" message:@"A processed source ID is required." details:nil]); return;
  }
  [self.processedVideo dispose]; self.processedVideo = nil;
  ArtcSendInt0(self.engine, NSSelectorFromString(@"stopPreview"));
  ArtcSendIntBool(self.engine, NSSelectorFromString(@"enableLocalVideo:"), NO);
  __weak FlutterRealtimeMediaArtcPlugin *weakSelf = self;
  self.processedVideo = [[ArtcProcessedVideoInput alloc] initWithSourceId:sourceId engine:self.engine
    onFailure:^(NSString *message) {
      [weakSelf emit:@{@"type": @"error", @"code": @-1, @"message": message}];
    }];
  if (!self.processedVideo) {
    ArtcSendIntBool(self.engine, NSSelectorFromString(@"publishLocalVideoStream:"), NO);
    result([FlutterError errorWithCode:@"attach_provider_failed" message:@"ARTC rejected the processed video source." details:nil]); return;
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
  NSInteger code = ArtcSendIntObject(
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
  [self.processedVideo dispose]; self.processedVideo = nil;
  for (ArtcVideoPlatformView *view in self.videoViews) [view detach];
  self.inChannel = NO;
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
  NSInteger source = view.screen ? 2 : 1;
  if (view.local) {
    ArtcSendIntObjectInteger(
        self.engine, NSSelectorFromString(@"setLocalViewConfig:forTrack:"),
        canvas, source);
    if (self.processedVideo == nil) ArtcSendInt0(self.engine, NSSelectorFromString(@"startPreview"));
  } else {
    ArtcSendIntObjectObjectInteger(
        self.engine, NSSelectorFromString(@"setRemoteViewConfig:uid:forTrack:"),
        canvas, view.userId, source);
  }
}

- (void)detachView:(ArtcVideoPlatformView *)view {
  if (self.engine == nil) return;
  NSInteger source = view.screen ? 2 : 1;
  if (view.local) {
    ArtcSendIntObjectInteger(
        self.engine, NSSelectorFromString(@"setLocalViewConfig:forTrack:"),
        nil, source);
  } else {
    ArtcSendIntObjectObjectInteger(
        self.engine, NSSelectorFromString(@"setRemoteViewConfig:uid:forTrack:"),
        nil, view.userId, source);
  }
}

#pragma mark - AliRtcEngine delegate selectors

- (void)onJoinChannelResult:(NSInteger)result
                    channel:(NSString *)channel
                     userId:(NSString *)userId
                    elapsed:(NSInteger)elapsed {
  if (result != 0) {
    self.inChannel = NO;
    [self emit:@{@"type" : @"error",
                 @"code" : @(result),
                 @"message" : @"ARTC failed to join the channel."}];
  }
}

- (void)onRemoteUserOnLineNotify:(NSString *)uid elapsed:(NSInteger)elapsed {
  [self emit:@{@"type" : @"participantJoined", @"userId" : uid ?: @""}];
}

- (void)onRemoteUserOffLineNotify:(NSString *)uid
                    offlineReason:(NSInteger)reason {
  [self emit:@{@"type" : @"participantLeft", @"userId" : uid ?: @""}];
}

- (void)onRemoteTrackAvailableNotify:(NSString *)uid
                          audioTrack:(NSInteger)audioTrack
                          videoTrack:(NSInteger)videoTrack {
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

- (void)onOccurError:(NSInteger)error message:(NSString *)message {
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
