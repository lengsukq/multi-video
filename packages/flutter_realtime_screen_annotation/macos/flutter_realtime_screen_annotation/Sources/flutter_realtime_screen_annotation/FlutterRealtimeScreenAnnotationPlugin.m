#import "FlutterRealtimeScreenAnnotationPlugin.h"
#import <AppKit/AppKit.h>
#import <math.h>

@class AnnotationInkView;

@interface FlutterRealtimeScreenAnnotationPlugin () <NSWindowDelegate>
@property(nonatomic, strong) FlutterMethodChannel *channel;
@property(nonatomic, strong) NSPanel *canvasWindow, *toolbar;
@property(nonatomic, strong) AnnotationInkView *ink;
@property(nonatomic, strong) NSAlert *labelAlert;
@property(nonatomic, copy) NSString *session, *tool;
@property(nonatomic, strong) NSArray *shapes;
@property(nonatomic, strong) NSMutableDictionary *drafts;
@property(nonatomic, strong) NSMutableDictionary *stroke;
@property(nonatomic, strong) NSMutableArray<NSButton *> *toolButtons;
@property(nonatomic) NSTimeInterval lastEmission;
@property(nonatomic) BOOL drawing, zh, failed;
@end

@interface AnnotationInkView : NSView
@property(nonatomic, weak) FlutterRealtimeScreenAnnotationPlugin *owner;
@end

@implementation FlutterRealtimeScreenAnnotationPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterRealtimeScreenAnnotationPlugin *plugin = [self new];
  plugin.channel = [FlutterMethodChannel methodChannelWithName:@"flutter_realtime_screen_annotation"
                                               binaryMessenger:registrar.messenger];
  plugin.shapes = @[];
  plugin.drafts = [NSMutableDictionary new];
  plugin.session = @"";
  plugin.tool = @"pen";
  [registrar addMethodCallDelegate:plugin channel:plugin.channel];
  [[NSNotificationCenter defaultCenter] addObserver:plugin
                                           selector:@selector(displayChanged:)
                                               name:NSApplicationDidChangeScreenParametersNotification
                                             object:nil];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *args = call.arguments;
  if ([call.method isEqual:@"capabilities"]) {
    result(@{@"supported": @YES, @"permissionRequired": @NO});
    return;
  }
  if ([call.method isEqual:@"requestPermission"]) {
    result(@YES);
    return;
  }
  if ([call.method isEqual:@"open"]) {
    [self close];
    _session = args[@"sessionId"];
    _zh = [args[@"languageCode"] isEqual:@"zh"];
    _failed = NO;

    NSScreen *screen = NSScreen.screens.firstObject;
    if (!screen) {
      result([FlutterError errorWithCode:@"system_annotation_failed"
                                 message:@"No primary display."
                                 details:nil]);
      return;
    }

    NSDictionary *v = args[@"viewport"];
    NSRect f = screen.frame;
    NSRect frame = NSMakeRect(f.origin.x + [v[@"x"] doubleValue] * f.size.width,
                              f.origin.y + (1 - [v[@"y"] doubleValue] - [v[@"height"] doubleValue]) * f.size.height,
                              [v[@"width"] doubleValue] * f.size.width,
                              [v[@"height"] doubleValue] * f.size.height);

    _canvasWindow = [[NSPanel alloc] initWithContentRect:frame
                                               styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    _canvasWindow.opaque = NO;
    _canvasWindow.backgroundColor = NSColor.clearColor;
    _canvasWindow.hasShadow = NO;
    _canvasWindow.level = NSFloatingWindowLevel + 1;
    _canvasWindow.hidesOnDeactivate = NO;
    _canvasWindow.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    _canvasWindow.ignoresMouseEvents = YES;

    _ink = [[AnnotationInkView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    _ink.owner = self;
    _canvasWindow.contentView = _ink;
    _shapes = args[@"shapes"] ?: @[];

    // Modern floating toolbar panel (Material 3 / macOS HUD style)
    CGFloat barW = 500;
    CGFloat barH = 50;
    NSRect toolbarFrame = NSMakeRect(f.origin.x + (f.size.width - barW) / 2.0, NSMaxY(f) - 86, barW, barH);
    _toolbar = [[NSPanel alloc] initWithContentRect:toolbarFrame
                                          styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _toolbar.opaque = NO;
    _toolbar.backgroundColor = NSColor.clearColor;
    _toolbar.hasShadow = YES;
    _toolbar.level = NSFloatingWindowLevel + 2;
    _toolbar.hidesOnDeactivate = NO;
    _toolbar.delegate = self;
    _toolbar.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    _toolbar.movableByWindowBackground = YES;

    [self setupModernToolbar:toolbarFrame];

    [_canvasWindow orderFrontRegardless];
    [_toolbar orderFrontRegardless];
    _drawing = NO;
    [self updateButtonStates];
    result(nil);
    return;
  }
  if (![args[@"sessionId"] isEqual:_session]) {
    result(nil);
    return;
  }
  if ([call.method isEqual:@"update"]) {
    _shapes = args[@"shapes"] ?: @[];
    _failed = args[@"error"] != nil && args[@"error"] != NSNull.null;
    [self updateButtonStates];
    _ink.needsDisplay = YES;
  } else if ([call.method isEqual:@"ack"]) {
    [_drafts removeObjectForKey:args[@"id"]];
    _ink.needsDisplay = YES;
  } else if ([call.method isEqual:@"close"]) {
    [self close];
  } else {
    result(FlutterMethodNotImplemented);
    return;
  }
  result(nil);
}

- (void)setupModernToolbar:(NSRect)frame {
  NSVisualEffectView *vfx = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
  vfx.material = NSVisualEffectMaterialHUDWindow;
  vfx.state = NSVisualEffectStateActive;
  vfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  vfx.wantsLayer = YES;
  vfx.layer.cornerRadius = 14.0;
  vfx.layer.masksToBounds = YES;
  vfx.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.18].CGColor;
  vfx.layer.borderWidth = 1.0;
  _toolbar.contentView = vfx;

  // Drag handle on left
  NSTextField *dragHandle = [NSTextField labelWithString:@"⋮⋮"];
  dragHandle.font = [NSFont systemFontOfSize:16 weight:NSFontWeightBold];
  dragHandle.textColor = [NSColor colorWithWhite:1.0 alpha:0.45];
  dragHandle.frame = NSMakeRect(12, 14, 18, 22);
  dragHandle.toolTip = _zh ? @"拖动工具栏" : @"Drag toolbar";
  [vfx addSubview:dragHandle];

  NSArray *symbols = @[
    @"hand.point.up.fill",
    @"pencil.tip",
    @"highlighter",
    @"circle",
    @"arrow.up.right",
    @"textformat",
    @"arrow.uturn.backward",
    @"trash",
    @"xmark"
  ];
  NSArray *tooltipsZh = @[
    @"操作模式（点击穿透下方应用）",
    @"画笔",
    @"荧光高亮",
    @"圆圈",
    @"箭头",
    @"文字说明",
    @"撤销",
    @"清除全部",
    @"关闭悬浮工具"
  ];
  NSArray *tooltipsEn = @[
    @"Navigate mode (pass clicks)",
    @"Pen",
    @"Highlighter",
    @"Circle",
    @"Arrow",
    @"Text label",
    @"Undo",
    @"Clear",
    @"Close"
  ];

  _toolButtons = [NSMutableArray new];
  CGFloat startX = 36;
  CGFloat btnW = 42;
  CGFloat btnH = 34;
  CGFloat gap = 4;

  for (NSInteger i = 0; i < symbols.count; i++) {
    if (i == 6 || i == 8) {
      NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(startX, 10, 1, 30)];
      sep.boxType = NSBoxSeparator;
      [vfx addSubview:sep];
      startX += 7;
    }

    NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(startX, 8, btnW, btnH)];
    b.tag = i;
    b.target = self;
    b.action = @selector(button:);
    b.bordered = NO;
    b.wantsLayer = YES;
    b.layer.cornerRadius = 8.0;
    b.toolTip = _zh ? tooltipsZh[i] : tooltipsEn[i];

    if (@available(macOS 11.0, *)) {
      NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightMedium];
      NSImage *img = [[NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:nil] imageWithSymbolConfiguration:config];
      b.image = img;
      b.imagePosition = NSImageOnly;
      b.contentTintColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    } else {
      b.title = _zh ? @[@"操作", @"笔", @"亮", @"圈", @"箭", @"字", @"撤", @"清", @"关"][i] : symbols[i];
    }

    [vfx addSubview:b];
    [_toolButtons addObject:b];
    startX += btnW + gap;
  }
}

- (void)updateButtonStates {
  if (!_toolButtons.count) return;
  for (NSInteger i = 0; i < _toolButtons.count; i++) {
    NSButton *b = _toolButtons[i];
    BOOL selected = NO;
    if (i == 0) {
      selected = !_drawing;
    } else if (i <= 5) {
      if (_drawing) {
        NSArray *tools = @[@"pen", @"highlight", @"circle", @"arrow", @"text"];
        selected = [_tool isEqual:tools[i - 1]];
      }
    }
    if (selected) {
      b.layer.backgroundColor = [NSColor colorWithSRGBRed:0.96 green:0.62 blue:0.04 alpha:0.35].CGColor;
      if (@available(macOS 11.0, *)) {
        b.contentTintColor = [NSColor colorWithSRGBRed:1.0 green:0.82 blue:0.25 alpha:1.0];
      }
    } else {
      b.layer.backgroundColor = [NSColor clearColor].CGColor;
      if (@available(macOS 11.0, *)) {
        b.contentTintColor = [NSColor colorWithWhite:0.92 alpha:1.0];
      }
    }
  }
}

- (void)event:(NSString *)type extra:(NSDictionary *)extra {
  if (!_session.length) return;
  NSMutableDictionary *event = [@{@"type": type, @"sessionId": _session} mutableCopy];
  if (extra) [event addEntriesFromDictionary:extra];
  [_channel invokeMethod:@"event" arguments:event];
}

- (void)setDrawing:(BOOL)d {
  _drawing = d;
  _canvasWindow.ignoresMouseEvents = !d;
  [self updateButtonStates];
}

- (void)button:(NSButton *)b {
  [self finish];
  if (b.tag == 0) {
    [self setDrawing:NO];
  } else if (b.tag <= 5) {
    if (_failed) return;
    _tool = @[@"pen", @"highlight", @"circle", @"arrow", @"text"][b.tag - 1];
    [self setDrawing:YES];
  } else if (b.tag == 6) {
    [self event:@"undo" extra:nil];
  } else if (b.tag == 7) {
    [self event:@"clear" extra:nil];
  } else {
    [self event:@"closed" extra:nil];
    [self close];
  }
  [self updateButtonStates];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
  [self event:@"closed" extra:nil];
  [self close];
  return NO;
}

- (void)displayChanged:(NSNotification *)n {
  if (_canvasWindow) {
    [self event:@"geometryChanged" extra:nil];
    [self close];
  }
}

- (NSDictionary *)point:(NSPoint)p {
  return @{
    @"x": @(fmax(0, fmin(1, p.x / _ink.bounds.size.width))),
    @"y": @(fmax(0, fmin(1, p.y / _ink.bounds.size.height)))
  };
}

- (void)begin:(NSPoint)p {
  if (_failed || _drafts.count >= 8) return;
  _stroke = [@{
    @"id": NSUUID.UUID.UUIDString,
    @"tool": _tool,
    @"width": @([_tool isEqual:@"highlight"] ? 16 : 3),
    @"color": @([_tool isEqual:@"highlight"] ? 0xffffeb3bULL : 0xfff59e0bULL),
    @"text": @"",
    @"points": [NSMutableArray arrayWithObject:[self point:p]]
  } mutableCopy];
  _drafts[_stroke[@"id"]] = _stroke;
  _lastEmission = 0;
  if ([_tool isEqual:@"text"]) {
    NSAlert *alert = [NSAlert new];
    _labelAlert = alert;
    alert.messageText = _zh ? @"文字说明" : @"Label";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 30)];
    alert.accessoryView = field;
    [alert addButtonWithTitle:_zh ? @"添加" : @"Add"];
    [alert addButtonWithTitle:_zh ? @"取消" : @"Cancel"];
    NSModalResponse answer = [alert runModal];
    _labelAlert = nil;
    if (!_stroke || !_canvasWindow) return;
    NSString *text = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (answer == NSAlertFirstButtonReturn && text.length > 0 && text.length <= 200) {
      _stroke[@"text"] = text;
      [self emitStroke:YES];
    } else {
      [_drafts removeObjectForKey:_stroke[@"id"]];
      _stroke = nil;
    }
  } else {
    [self emitStroke:NO];
  }
  _ink.needsDisplay = YES;
}

- (void)move:(NSPoint)p {
  if (!_stroke) return;
  NSMutableArray *points = _stroke[@"points"];
  if (points.count >= 2048) return;
  if (![_tool isEqual:@"pen"] && ![_tool isEqual:@"highlight"] && points.count > 1) {
    [points removeLastObject];
  }
  [points addObject:[self point:p]];
  if (NSDate.timeIntervalSinceReferenceDate - _lastEmission >= .1) {
    [self emitStroke:NO];
  }
  _ink.needsDisplay = YES;
}

- (void)emitStroke:(BOOL)done {
  if (!_stroke) return;
  NSMutableDictionary *shape = [_stroke mutableCopy];
  shape[@"points"] = [_stroke[@"points"] copy];
  [self event:@"stroke" extra:@{@"shape": shape, @"finished": @(done)}];
  _lastEmission = NSDate.timeIntervalSinceReferenceDate;
}

- (void)finish {
  if (_stroke) {
    [self emitStroke:YES];
    _stroke = nil;
  }
}

- (void)close {
  if (_labelAlert) {
    [NSApp abortModal];
    [_labelAlert.window orderOut:nil];
    _labelAlert = nil;
  }
  _toolbar.delegate = nil;
  [_toolbar orderOut:nil];
  [_canvasWindow orderOut:nil];
  _toolbar = nil;
  _canvasWindow = nil;
  _ink = nil;
  _stroke = nil;
  _toolButtons = nil;
  [_drafts removeAllObjects];
  _shapes = @[];
  _session = @"";
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self close];
}

@end

@implementation AnnotationInkView

- (BOOL)isFlipped { return YES; }

- (void)mouseDown:(NSEvent *)e {
  if (_owner.drawing) [_owner begin:[self convertPoint:e.locationInWindow fromView:nil]];
}

- (void)mouseDragged:(NSEvent *)e {
  [_owner move:[self convertPoint:e.locationInWindow fromView:nil]];
}

- (void)mouseUp:(NSEvent *)e {
  [_owner finish];
}

- (void)drawRect:(NSRect)dirty {
  CGFloat w = self.bounds.size.width, h = self.bounds.size.height, scale = MIN(w, h) / 720;
  NSMutableArray *all = [NSMutableArray new];
  for (NSDictionary *s in _owner.shapes) {
    if (!_owner.drafts[s[@"id"]]) [all addObject:s];
  }
  [all addObjectsFromArray:_owner.drafts.allValues];
  for (NSDictionary *s in all) {
    NSArray *points = s[@"points"];
    if (!points.count) continue;
    NSString *tool = s[@"tool"];
    uint32_t argb = [s[@"color"] unsignedIntValue];
    NSColor *color = [NSColor colorWithSRGBRed:((argb >> 16) & 255) / 255.0
                                         green:((argb >> 8) & 255) / 255.0
                                          blue:(argb & 255) / 255.0
                                         alpha:[tool isEqual:@"highlight"] ? .35 : 1];
    [color set];
    NSDictionary *a = points.firstObject, *z = points.lastObject;
    NSPoint p = NSMakePoint([a[@"x"] doubleValue] * w, [a[@"y"] doubleValue] * h);
    NSPoint q = NSMakePoint([z[@"x"] doubleValue] * w, [z[@"y"] doubleValue] * h);
    NSBezierPath *path = [NSBezierPath bezierPath];
    path.lineWidth = MAX(1, [s[@"width"] doubleValue] * scale);
    path.lineCapStyle = NSLineCapStyleRound;
    path.lineJoinStyle = NSLineJoinStyleRound;
    if ([tool isEqual:@"text"]) {
      [s[@"text"] drawAtPoint:p
               withAttributes:@{
                 NSForegroundColorAttributeName: color,
                 NSFontAttributeName: [NSFont systemFontOfSize:MAX(10, 22 * scale)]
               }];
      continue;
    }
    if ([tool isEqual:@"circle"]) {
      [path appendBezierPathWithOvalInRect:NSMakeRect(MIN(p.x, q.x), MIN(p.y, q.y), fabs(q.x - p.x), fabs(q.y - p.y))];
    } else if ([tool isEqual:@"arrow"]) {
      [path moveToPoint:p];
      [path lineToPoint:q];
      double angle = atan2(q.y - p.y, q.x - p.x), len = MAX(8, 18 * scale);
      for (double d = -.5; d <= .5; d += 1) {
        [path moveToPoint:q];
        [path lineToPoint:NSMakePoint(q.x - cos(angle + d) * len, q.y - sin(angle + d) * len)];
      }
    } else {
      if (points.count == 1) {
        [NSBezierPath fillRect:NSMakeRect(p.x - path.lineWidth / 2, p.y - path.lineWidth / 2, path.lineWidth, path.lineWidth)];
        continue;
      }
      [path moveToPoint:p];
      for (NSDictionary *point in [points subarrayWithRange:NSMakeRange(1, points.count - 1)]) {
        [path lineToPoint:NSMakePoint([point[@"x"] doubleValue] * w, [point[@"y"] doubleValue] * h)];
      }
    }
    [path stroke];
  }
}

@end
