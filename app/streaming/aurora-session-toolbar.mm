#include "aurora-session-toolbar.h"
#include "aurora-session-toolbar-layout.h"
#include "aurora-connection-details.h"
#include <vector>
#include "aurora-session-privacy.h"
#include "../backend/aurora-bitrate.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#include <SDL_syswm.h>
#include <QThreadPool>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>

namespace {
    constexpr CGFloat GroupHeight = 44;
    constexpr CGFloat DisplayTabHeight = 37;
    constexpr CGFloat BrandSize = 28;
    constexpr CGFloat ButtonHeight = 32;
    constexpr CGFloat FloatingButtonSize = 40;
    constexpr CGFloat FloatingButtonInset = 14;
    NSString* const ControlCenterSymbol = @"AuroraSessionControlCenter";
    NSString* const ContextItem = @"AuroraSessionContext";
    NSString* const ActionsItem = @"AuroraSessionActions";
    char ControllerKey;

    enum class BitrateMode { Unchecked, SavedOnly, Live, Retry };

    struct PrivacyChoice {
        NSString* label;
        AuroraPrivacyOperation operation;
        AuroraPrivacyState state;
    };

    const std::array<PrivacyChoice, 3> PrivacyChoices{{
        {@"关闭", AuroraPrivacyOperation::Disable, AuroraPrivacyState::Off},
        {@"关闭显示器", AuroraPrivacyOperation::DisplayOff, AuroraPrivacyState::DisplayOff},
        {@"隐私屏保", AuroraPrivacyOperation::Enable, AuroraPrivacyState::On},
    }};

    NSColor* rgb(unsigned color)
    {
        return [NSColor colorWithSRGBRed:((color >> 16) & 0xff) / 255.0
                                   green:((color >> 8) & 0xff) / 255.0
                                    blue:(color & 0xff) / 255.0 alpha:1];
    }

    NSImage* controlCenterImage()
    {
        auto* icon = [NSImage imageWithSize:NSMakeSize(24, 24) flipped:YES drawingHandler:^BOOL(NSRect bounds) {
            auto* lines = [NSBezierPath bezierPath];
            [lines moveToPoint:NSMakePoint(3, 7)];
            [lines lineToPoint:NSMakePoint(5.5, 7)];
            [lines moveToPoint:NSMakePoint(10.5, 7)];
            [lines lineToPoint:NSMakePoint(21, 7)];
            [lines moveToPoint:NSMakePoint(3, 17)];
            [lines lineToPoint:NSMakePoint(13.5, 17)];
            [lines moveToPoint:NSMakePoint(18.5, 17)];
            [lines lineToPoint:NSMakePoint(21, 17)];
            [lines appendBezierPathWithOvalInRect:NSMakeRect(5.5, 4.5, 5, 5)];
            [lines appendBezierPathWithOvalInRect:NSMakeRect(13.5, 14.5, 5, 5)];
            lines.lineWidth = 1.75;
            lines.lineCapStyle = NSRoundLineCapStyle;
            [NSColor.blackColor setStroke];
            [lines stroke];
            return YES;
        }];
        [icon setTemplate:YES];
        return icon;
    }

    NSWindow* nativeWindow(SDL_Window* window)
    {
        SDL_SysWMinfo info = {};
        SDL_VERSION(&info.version);
        if (!window || !SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_COCOA) {
            return nil;
        }
        return info.info.cocoa.window;
    }

    void sendAction(Uint32 windowId, AuroraToolbarAction action)
    {
        SDL_Event event = {};
        event.type = SDL_USEREVENT;
        event.user.timestamp = SDL_GetTicks();
        event.user.windowID = windowId;
        event.user.code = static_cast<Sint32>(action);
        if (SDL_PushEvent(&event) != 1) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Could not enqueue Aurora toolbar action");
        }
    }
}

@interface AuroraToolbarGroup : NSView {
    NSLayoutConstraint* _width;
}
- (void)resizeToWidth:(CGFloat)width;
@end

@implementation AuroraToolbarGroup
- (instancetype)init
{
    self = [super initWithFrame:NSMakeRect(0, 0, 120, GroupHeight)];
    if (self) {
        _width = [self.widthAnchor constraintEqualToConstant:120];
        [NSLayoutConstraint activateConstraints:@[_width, [self.heightAnchor constraintEqualToConstant:GroupHeight]]];
    }
    return self;
}

- (void)resizeToWidth:(CGFloat)width
{
    if (_width.constant != width) {
        _width.constant = width;
        [self setFrameSize:NSMakeSize(width, GroupHeight)];
        [self invalidateIntrinsicContentSize];
    }
}

- (BOOL)mouseDownCanMoveWindow { return YES; }
@end

@interface AuroraToolbarButton : NSButton {
    NSImageView* _glyph;
    NSTextField* _caption;
    NSTrackingArea* _tracking;
    BOOL _hover;
    BOOL _warning;
    BOOL _menuOpen;
    BOOL _showsLabel;
    BOOL _menuRow;
    BOOL _option;
    BOOL _selectedOption;
    NSImageView* _nextArrow;
}
- (instancetype)initWithLabel:(NSString*)label symbol:(NSString*)symbol
                       target:(id)target action:(SEL)action warning:(BOOL)warning;
- (void)showLabel:(BOOL)show;
- (void)markMenuOpen:(BOOL)open;
- (void)useMenuLayout:(BOOL)next;
- (void)useOptionStyle:(BOOL)selected;
- (void)selectOption:(BOOL)selected;
@end

@implementation AuroraToolbarButton
- (instancetype)initWithLabel:(NSString*)label symbol:(NSString*)symbol
                       target:(id)target action:(SEL)action warning:(BOOL)warning
{
    self = [super initWithFrame:NSMakeRect(0, 0, ButtonHeight, ButtonHeight)];
    if (self) {
        _warning = warning;
        // The inherited AppKit cell only handles activation and keyboard focus.
        // A single content group positions the icon and text without cell padding.
        self.bordered = NO;
        self.title = @"";
        self.target = target;
        self.action = action;
        self.focusRingType = NSFocusRingTypeExterior;
        self.toolTip = label;
        [self setAccessibilityLabel:label];

        _glyph = [[[NSImageView alloc] initWithFrame:NSZeroRect] autorelease];
        _glyph.imageScaling = NSImageScaleProportionallyDown;
        if ([symbol isEqualToString:ControlCenterSymbol]) {
            _glyph.image = controlCenterImage();
        } else if (symbol.length > 0) {
            NSImage* image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
            _glyph.image = [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration
                configurationWithPointSize:15 weight:NSFontWeightRegular]];
        }
        [_glyph setAccessibilityElement:NO];
        [self addSubview:_glyph];

        _caption = [NSTextField labelWithString:label];
        _caption.font = [NSFont systemFontOfSize:12];
        _caption.lineBreakMode = NSLineBreakByTruncatingTail;
        [_caption setAccessibilityElement:NO];
        [self addSubview:_caption];
        [self setEnabled:YES];
        [self showLabel:YES];
    }
    return self;
}

- (void)setEnabled:(BOOL)enabled
{
    [super setEnabled:enabled];
    NSColor* ink = rgb(enabled ? 0x19283f : 0x9ba7b7);
    _glyph.contentTintColor = ink;
    _caption.textColor = ink;
}

- (void)showLabel:(BOOL)show
{
    _showsLabel = show;
    _caption.hidden = !show;
    self.needsLayout = YES;
}

- (void)layout
{
    [super layout];
    constexpr CGFloat iconSize = 16;
    constexpr CGFloat spacing = 5;
    const NSSize captionSize = _caption.intrinsicContentSize;
    const CGFloat maxLabelWidth = std::max<CGFloat>(0, NSWidth(self.bounds) - iconSize - spacing - 4);
    const CGFloat labelWidth = _showsLabel ? std::min(std::ceil(captionSize.width), maxLabelWidth) : 0;
    const CGFloat rowWidth = iconSize + (labelWidth > 0 ? spacing + labelWidth : 0);
    const CGFloat left = _menuRow ? 8 : std::floor((NSWidth(self.bounds) - rowWidth) / 2);
    _nextArrow.frame = NSMakeRect(NSWidth(self.bounds) - 19, NSMidY(self.bounds) - 6, 12, 12);
    const CGFloat middle = NSMidY(self.bounds);
    _glyph.frame = NSMakeRect(left, middle - iconSize / 2, iconSize, iconSize);
    if (_option) {
        _glyph.hidden = YES;
        _caption.frame = self.bounds;
        const CGFloat height = std::ceil(captionSize.height);
        _caption.frame = NSMakeRect(0, std::floor(middle - height / 2), NSWidth(self.bounds), height);
        return;
    }
    const CGFloat captionHeight = std::ceil(captionSize.height);
    _caption.frame = NSMakeRect(left + iconSize + spacing, std::floor(middle - captionHeight / 2),
                                labelWidth, captionHeight);
}

- (NSView*)hitTest:(NSPoint)point { return [super hitTest:point] ? self : nil; }

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    if (_tracking) {
        [self removeTrackingArea:_tracking];
        [_tracking release];
    }
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingInVisibleRect | NSTrackingActiveInKeyWindow
        owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent*)event
{
    _hover = YES;
    self.needsDisplay = YES;
}

- (void)mouseExited:(NSEvent*)event
{
    _hover = NO;
    self.needsDisplay = YES;
}

- (void)highlight:(BOOL)flag
{
    [super highlight:flag];
    self.needsDisplay = YES;
}

- (void)markMenuOpen:(BOOL)open
{
    _menuOpen = open;
    self.needsDisplay = YES;
}

- (void)useMenuLayout:(BOOL)next
{
    _menuRow = YES;
    _caption.font = [NSFont systemFontOfSize:13];
    if (next) {
        _nextArrow = [[[NSImageView alloc] initWithFrame:NSZeroRect] autorelease];
        _nextArrow.image = [[NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:nil]
            imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:9 weight:NSFontWeightRegular]];
        _nextArrow.contentTintColor = rgb(0x526176);
        [_nextArrow setAccessibilityElement:NO];
        [self addSubview:_nextArrow];
    }
    self.needsLayout = YES;
}

- (void)useOptionStyle:(BOOL)selected
{
    _option = YES;
    _caption.alignment = NSTextAlignmentCenter;
    [self selectOption:selected];
    self.needsLayout = YES;
}

- (void)selectOption:(BOOL)selected
{
    _selectedOption = selected;
    _caption.textColor = rgb(!self.enabled ? 0x8390a1 : selected ? 0x2350b4 : 0x19283f);
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
    if (_option) {
        [rgb(_selectedOption ? 0xe2e7ef : _hover ? 0xe8edf4 : 0xf4f6fa) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
    }
    if (!_option && self.enabled && (_hover || _menuOpen || self.cell.highlighted)) {
        const unsigned color = _warning ? 0xfbe7e8 :
            (_menuOpen || self.cell.highlighted) ? 0xe2e7ef : 0xe8edf4;
        [rgb(color) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
    }
    [super drawRect:dirtyRect];
}

- (NSRect)focusRingMaskBounds { return self.bounds; }
- (void)drawFocusRingMask
{
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:6 yRadius:6] fill];
}
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)dealloc
{
    if (_tracking) [self removeTrackingArea:_tracking];
    [_tracking release];
    [super dealloc];
}
@end

@interface AuroraFloatingControlsButton : AuroraToolbarButton
@end

@implementation AuroraFloatingControlsButton
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (void)resetCursorRects
{
    [self addCursorRect:self.bounds cursor:NSCursor.arrowCursor];
}

- (void)drawRect:(NSRect)dirtyRect
{
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                                         xRadius:13 yRadius:13];
    [rgb(0xf7f9fd) setFill];
    [shape fill];
    [rgb(0xc6d1e0) setStroke];
    [shape stroke];
    [super drawRect:dirtyRect];
}
@end

@interface AuroraStatusDot : NSView {
@public
    BOOL poor;
    BOOL connecting;
    BOOL failed;
}
@end

@implementation AuroraStatusDot
- (void)drawRect:(NSRect)dirtyRect
{
    if (connecting) {
        const NSRect pathBounds = NSInsetRect(self.bounds, .5, .5);
        [rgb(0xd4e0f2) setStroke];
        [[NSBezierPath bezierPathWithOvalInRect:pathBounds] stroke];
        auto* arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter:NSMakePoint(NSMidX(pathBounds), NSMidY(pathBounds))
                                       radius:NSWidth(pathBounds) / 2 startAngle:35 endAngle:125];
        [rgb(0x087cf5) setStroke];
        [arc stroke];
        return;
    }
    [rgb(failed ? 0xad384e : poor ? 0xbf8219 : 0x244fc5) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:self.bounds] fill];
}
- (BOOL)mouseDownCanMoveWindow { return YES; }
@end

@interface AuroraDisplayTab : NSView {
    NSImageView* _glyph;
    NSTextField* _caption;
}
- (void)showLabel:(BOOL)show;
@end

@implementation AuroraDisplayTab
- (instancetype)init
{
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _glyph = [[[NSImageView alloc] initWithFrame:NSZeroRect] autorelease];
        _glyph.imageScaling = NSImageScaleProportionallyDown;
        _glyph.image = [[NSImage imageWithSystemSymbolName:@"display" accessibilityDescription:nil]
            imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular]];
        _glyph.contentTintColor = rgb(0x19283f);
        [_glyph setAccessibilityElement:NO];
        [self addSubview:_glyph];
        _caption = [NSTextField labelWithString:@"显示器 1"];
        _caption.font = [NSFont systemFontOfSize:12];
        _caption.textColor = rgb(0x19283f);
        [_caption setAccessibilityElement:NO];
        [self addSubview:_caption];
        [self setAccessibilityElement:YES];
        [self setAccessibilityRole:NSAccessibilityStaticTextRole];
        [self setAccessibilityLabel:@"显示器 1"];
    }
    return self;
}

- (void)showLabel:(BOOL)show
{
    _caption.hidden = !show;
    self.needsLayout = YES;
}

- (void)layout
{
    [super layout];
    const CGFloat middle = NSMidY(self.bounds);
    constexpr CGFloat foot = AuroraSessionToolbarLayout::DisplayFoot;
    const CGFloat left = _caption.hidden ? std::floor((NSWidth(self.bounds) - 14) / 2) : foot + 11;
    _glyph.frame = NSMakeRect(left, middle - 7, 14, 14);
    const CGFloat height = std::ceil(_caption.intrinsicContentSize.height);
    _caption.frame = NSMakeRect(left + 20, std::floor(middle - height / 2),
                                std::max<CGFloat>(0, NSWidth(self.bounds) - foot - left - 26), height);
}

- (void)drawRect:(NSRect)dirtyRect
{
    constexpr CGFloat foot = AuroraSessionToolbarLayout::DisplayFoot;
    constexpr CGFloat topRadius = 10;
    const CGFloat width = NSWidth(self.bounds);
    const CGFloat height = NSHeight(self.bounds);
    auto* outline = [NSBezierPath bezierPath];
    [outline moveToPoint:NSMakePoint(0, 0)];
    [outline appendBezierPathWithArcWithCenter:NSMakePoint(0, foot) radius:foot
                                   startAngle:270 endAngle:360 clockwise:NO];
    [outline lineToPoint:NSMakePoint(foot, height - topRadius)];
    [outline appendBezierPathWithArcWithCenter:NSMakePoint(foot + topRadius, height - topRadius) radius:topRadius
                                   startAngle:180 endAngle:90 clockwise:YES];
    [outline lineToPoint:NSMakePoint(width - foot - topRadius, height)];
    [outline appendBezierPathWithArcWithCenter:NSMakePoint(width - foot - topRadius, height - topRadius) radius:topRadius
                                   startAngle:90 endAngle:0 clockwise:YES];
    [outline lineToPoint:NSMakePoint(width - foot, foot)];
    [outline appendBezierPathWithArcWithCenter:NSMakePoint(width, foot) radius:foot
                                   startAngle:180 endAngle:270 clockwise:NO];
    [outline closePath];
    [rgb(0xffffff) setFill];
    [outline fill];
}

- (BOOL)mouseDownCanMoveWindow { return YES; }
@end

@interface AuroraConnectionStatus : NSButton
@end

@implementation AuroraConnectionStatus
- (NSView*)hitTest:(NSPoint)point { return [super hitTest:point] ? self : nil; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
@end

@interface AuroraControlPageView : NSView
@end

@implementation AuroraControlPageView
- (BOOL)isFlipped { return YES; }
@end

@interface AuroraControlPanel : NSPanel
@end

@implementation AuroraControlPanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface AuroraSessionToolbarController : NSObject <NSToolbarDelegate, NSPopoverDelegate> {
@public
    Uint32 streamWindowId;
    std::shared_ptr<AuroraSessionPrivacy> privacy;
@private
    NSWindow* _window;  // Owned by SDL. The native window retains this controller.
    NSPanel* _floatingPanel;
    AuroraToolbarGroup* _context;
    AuroraToolbarGroup* _actions;
    NSTextField* _device;
    AuroraConnectionStatus* _status;
    NSImageView* _statusChevron;
    NSPopover* _connectionDetails;
    NSTimer* _connectionRefresh;
    AuroraStatusDot* _dot;
    NSTextField* _statusText;
    AuroraDisplayTab* _display;
    BOOL _connectionWindow;
    AuroraToolbarButton* _controls;
    AuroraToolbarButton* _disconnect;
    NSImageView* _brand;
    AuroraControlPanel* _controlCenter;
    AuroraToolbarButton* _controlAnchor;
    id _controlMonitor;
    NSMutableDictionary<NSString*, NSString*>* _preferences;
    NSTextField* _bitrateLabel;
    NSTextField* _bitrateFeedback;
    NSSlider* _bitrateSlider;
    BitrateMode _bitrateMode;
    QByteArray _bitrateSession;
    quint32 _bitrateRevision;
    int _bitrateRequestedKbps;
    int _bitrateEncoderKbps;
    int _bitrateMaximumKbps;
    NSInteger _controlPage;
    BOOL _showFloatingControls;
    BOOL _nativeFullscreen;
    NSSize _videoAspect;
}
- (instancetype)initWithWindow:(NSWindow*)window deviceName:(NSString*)name connecting:(BOOL)connecting;
- (void)setConnectionFailed:(BOOL)failed cancelTarget:(id)target cancelAction:(SEL)action;
- (void)updateConnectionResult:(BOOL)failed;
- (AuroraToolbarButton*)addButton:(NSString*)title symbol:(NSString*)symbol action:(SEL)action
                            code:(AuroraToolbarAction)code warning:(BOOL)warning;
- (void)resizeItems;
- (void)showConnectionDetails:(id)sender;
- (void)closeConnectionDetails;
- (void)refreshConnectionDetails:(NSTimer*)timer;
- (void)showIfWindowed;
- (void)setVideoWidth:(int)width height:(int)height fullscreen:(BOOL)fullscreen;
- (void)showFullscreenControls:(BOOL)visible;
- (void)positionFullscreenControls;
- (void)updateConnectionQuality:(BOOL)poor;
- (void)requestPrivacy:(AuroraPrivacyOperation)operation;
- (void)updatePrivacyMenu;
- (void)updateBitrateControls;
- (void)requestBitrate:(const AuroraBitrate::Request&)request;
- (void)finishBitrateRequest:(const AuroraBitrate::Request&)request reply:(const QByteArray&)reply;
- (void)closeControlCenter;
- (void)positionControlCenter;
@end

static AuroraSessionToolbarController* auroraToolbar(NSWindow* window)
{
    return window ? objc_getAssociatedObject(window, &ControllerKey) : nil;
}

@implementation AuroraSessionToolbarController
- (instancetype)initWithWindow:(NSWindow*)window deviceName:(NSString*)name connecting:(BOOL)connecting
{
    self = [super init];
    if (!self) return nil;

    _window = window;
    _connectionWindow = connecting;
    _context = [[AuroraToolbarGroup alloc] init];
    _actions = [[AuroraToolbarGroup alloc] init];
    _device = [NSTextField labelWithString:name];
    _device.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    _device.textColor = rgb(0x19283f);
    _device.lineBreakMode = NSLineBreakByTruncatingTail;
    _device.toolTip = name;
    [_context addSubview:_device];

    _status = [[[AuroraConnectionStatus alloc] initWithFrame:NSZeroRect] autorelease];
    _status.bordered = NO;
    _status.title = @"";
    _status.image = nil;
    _status.target = self;
    _status.action = @selector(showConnectionDetails:);
    _status.toolTip = @"连接详情";
    [_context addSubview:_status];
    _statusChevron = [[[NSImageView alloc] initWithFrame:NSZeroRect] autorelease];
    _statusChevron.image = [[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:8 weight:NSFontWeightRegular]];
    [_statusChevron setAccessibilityElement:NO];
    [_status addSubview:_statusChevron];
    _dot = [[[AuroraStatusDot alloc] initWithFrame:NSZeroRect] autorelease];
    [_status addSubview:_dot];
    _statusText = [NSTextField labelWithString:@""];
    [_statusText setAccessibilityElement:NO];
    _statusText.font = [NSFont systemFontOfSize:12];
    [_status addSubview:_statusText];

    _display = [[[AuroraDisplayTab alloc] init] autorelease];
    [_context addSubview:_display];

    _controls = [self addButton:@"控制中心" symbol:ControlCenterSymbol action:@selector(showControls:)
                            code:AuroraToolbarAction::ReleaseMouse warning:NO];
    _disconnect = [self addButton:connecting ? @"取消" : @"断开"
                           symbol:connecting ? @"xmark" : @"rectangle.portrait.and.arrow.right"
                           action:@selector(sendButtonAction:)
                             code:AuroraToolbarAction::Disconnect warning:!connecting];

    NSString* brandPath = [NSBundle.mainBundle pathForResource:@"AuroraStreamBrand" ofType:@"png"];
    NSImage* brand = brandPath ? [[[NSImage alloc] initWithContentsOfFile:brandPath] autorelease] : nil;
    if (brand) {
        _brand = [[[NSImageView alloc] initWithFrame:NSZeroRect] autorelease];
        _brand.image = brand;
        _brand.imageScaling = NSImageScaleProportionallyUpOrDown;
        [_brand setAccessibilityElement:NO];
        [_actions addSubview:_brand];
    }

    if (!connecting) {
        NSString* json = NSProcessInfo.processInfo.environment[@"AURORA_STREAM_PREFERENCES"];
        if (json.length > 0) {
            id settings = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                         options:NSJSONReadingMutableContainers error:nullptr];
            if ([settings isKindOfClass:NSMutableDictionary.class]) _preferences = [settings retain];
        }
    }

    NSNotificationCenter* notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:self selector:@selector(dismissControlCenter:) name:NSApplicationDidResignActiveNotification object:nil];
    [notifications addObserver:self selector:@selector(dismissControlCenter:) name:NSWindowWillCloseNotification object:window];
    [notifications addObserver:self selector:@selector(windowResized:) name:NSWindowDidResizeNotification object:window];
    [notifications addObserver:self selector:@selector(windowWillEnterFullscreen:) name:NSWindowWillEnterFullScreenNotification object:window];
    [notifications addObserver:self selector:@selector(windowDidEnterFullscreen:) name:NSWindowDidEnterFullScreenNotification object:window];
    [notifications addObserver:self selector:@selector(windowDidExitFullscreen:) name:NSWindowDidExitFullScreenNotification object:window];
    [self resizeItems];
    return self;
}

- (AuroraToolbarButton*)addButton:(NSString*)title symbol:(NSString*)symbol action:(SEL)action
                            code:(AuroraToolbarAction)code warning:(BOOL)warning
{
    AuroraToolbarButton* button = [[AuroraToolbarButton alloc] initWithLabel:title symbol:symbol
        target:self action:action warning:warning];
    button.tag = static_cast<NSInteger>(code);
    [_actions addSubview:button];
    [button release];
    return button;
}

- (void)resizeItems
{
    NSButton* zoom = [_window standardWindowButton:NSWindowZoomButton];
    const auto trafficEdge = zoom ? NSMaxX([zoom convertRect:zoom.bounds toView:nil]) : 0;
    const NSSize nameInk = [_device.stringValue sizeWithAttributes:@{NSFontAttributeName: _device.font}];
    const auto layout = auroraSessionToolbarLayout(
        static_cast<int>(NSWidth(_window.frame)), static_cast<int>(std::ceil(trafficEdge)),
        static_cast<int>(std::ceil(nameInk.width)) + 4, _brand != nil);
    [_context resizeToWidth:layout.contextWidth()];
    [_actions resizeToWidth:layout.actionsWidth()];

    const CGFloat middle = GroupHeight / 2;
    const CGFloat deviceHeight = std::ceil(_device.intrinsicContentSize.height);
    _device.frame = NSMakeRect(0, std::floor(middle - deviceHeight / 2), layout.device, deviceHeight);
    _status.frame = NSMakeRect(layout.device + 8, middle - 14, layout.status, 28);
    const BOOL compactStatus = layout.status == 25;
    const BOOL arrow = !_connectionWindow;
    _statusText.hidden = compactStatus;
    _statusChevron.hidden = !arrow;
    const CGFloat dot = _dot->connecting ? 9 : 6;
    const CGFloat leading = compactStatus && !arrow ? (layout.status - dot) / 2 : 4;
    _dot.frame = NSMakeRect(leading, 14 - dot / 2, dot, dot);
    const CGFloat textX = NSMaxX(_dot.frame) + 6;
    const CGFloat textHeight = std::ceil(_statusText.intrinsicContentSize.height);
    const CGFloat textWidth = std::min(std::ceil(_statusText.intrinsicContentSize.width),
        std::max<CGFloat>(0, layout.status - textX - (arrow ? 15 : 0)));
    _statusText.frame = NSMakeRect(textX, std::floor(14 - textHeight / 2), textWidth, textHeight);
    const CGFloat arrowX = compactStatus ? layout.status - 10 : NSMaxX(_statusText.frame) + 5;
    _statusChevron.frame = NSMakeRect(arrowX, 8, 9, 12);

    [_display showLabel:layout.display > 32];
    _display.frame = NSMakeRect(NSMaxX(_status.frame) + 6, 0,
                                layout.display + 2 * AuroraSessionToolbarLayout::DisplayFoot, DisplayTabHeight);

    [_controls showLabel:layout.controls > 32];
    [_disconnect showLabel:layout.disconnect > 32];
    _controls.frame = NSMakeRect(0, middle - ButtonHeight / 2, layout.controls, ButtonHeight);
    _disconnect.frame = NSMakeRect(layout.controls + 4, middle - ButtonHeight / 2, layout.disconnect, ButtonHeight);
    _brand.hidden = !layout.brand;
    _brand.frame = NSMakeRect(NSMaxX(_disconnect.frame) + 8, middle - BrandSize / 2,
                              BrandSize, BrandSize);
}

- (void)updateConnectionResult:(BOOL)failed
{
    [self setConnectionFailed:failed cancelTarget:_disconnect.target cancelAction:_disconnect.action];
}

- (void)setConnectionFailed:(BOOL)failed cancelTarget:(id)target cancelAction:(SEL)action
{
    _controls.enabled = NO;
    _status.enabled = NO;
    _status.toolTip = nil;
    _dot->connecting = !failed;
    _dot->failed = failed;
    _dot.needsDisplay = YES;
    NSString* text = failed ? @"连接失败" : @"连接中";
    _statusText.stringValue = text;
    _statusText.textColor = rgb(failed ? 0xad384e : 0x52647b);
    [_status setAccessibilityLabel:text];
    [_status setAccessibilityRole:NSAccessibilityStaticTextRole];
    _disconnect.target = target;
    _disconnect.action = action;
    _disconnect.keyEquivalent = failed ? @"" : @"\033";
    _disconnect.hidden = failed;
    [self resizeItems];
}

- (void)showIfWindowed
{
    if (!_nativeFullscreen && !(_window.styleMask & NSWindowStyleMaskFullScreen)) {
        if (!_window.toolbar.visible) _window.toolbar.visible = YES;
        [self resizeItems];
    }
}

- (void)positionFullscreenControls
{
    const NSRect video = [_window convertRectToScreen:[_window.contentView convertRect:_window.contentView.bounds toView:nil]];
    [_floatingPanel setFrameOrigin:NSMakePoint(NSMaxX(video) - FloatingButtonSize - FloatingButtonInset,
                                               NSMaxY(video) - FloatingButtonSize - FloatingButtonInset)];
}

- (void)showFullscreenControls:(BOOL)visible
{
    if (_showFloatingControls != visible) [self closeControlCenter];
    _showFloatingControls = visible;
    if (!visible) {
        if (_floatingPanel.parentWindow == _window) [_window removeChildWindow:_floatingPanel];
        [_floatingPanel orderOut:nil];
        return;
    }
    if (!_floatingPanel) {
        _floatingPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, FloatingButtonSize, FloatingButtonSize)
            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
              backing:NSBackingStoreBuffered defer:NO];
        _floatingPanel.opaque = NO;
        _floatingPanel.backgroundColor = NSColor.clearColor;
        _floatingPanel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary |
                                              NSWindowCollectionBehaviorIgnoresCycle;
        _floatingPanel.hasShadow = YES;
        _floatingPanel.hidesOnDeactivate = YES;
        _floatingPanel.releasedWhenClosed = NO;
        auto* button = [[AuroraFloatingControlsButton alloc] initWithLabel:@"控制中心"
            symbol:ControlCenterSymbol target:self action:@selector(showControls:) warning:NO];
        [button showLabel:NO];
        button.frame = NSMakeRect(0, 0, FloatingButtonSize, FloatingButtonSize);
        _floatingPanel.contentView = button;
        [button release];
    }
    [self positionFullscreenControls];
    if (_floatingPanel.parentWindow != _window) [_window addChildWindow:_floatingPanel ordered:NSWindowAbove];
}

- (void)windowResized:(NSNotification*)notification
{
    if (_floatingPanel.parentWindow == _window) [self positionFullscreenControls];
    if (_controlCenter.visible) [self positionControlCenter];
    if (!_nativeFullscreen && !(_window.styleMask & NSWindowStyleMaskFullScreen)) {
        [self resizeItems];
    }
}

- (void)setVideoWidth:(int)width height:(int)height fullscreen:(BOOL)fullscreen
{
    _videoAspect = width > 0 && height > 0 ? NSMakeSize(static_cast<CGFloat>(width) / height, 1) : NSZeroSize;
    const NSSize aspect = fullscreen || _nativeFullscreen ? NSZeroSize : _videoAspect;
    // Constrain the video content, leaving titlebar sizing and drag behavior to AppKit.
    if (!NSEqualSizes(_window.contentAspectRatio, aspect)) _window.contentAspectRatio = aspect;
}

- (void)windowWillEnterFullscreen:(NSNotification*)notification
{
    _nativeFullscreen = YES;
    _window.contentAspectRatio = NSZeroSize;
    _window.toolbar.visible = NO;
}

- (void)windowDidEnterFullscreen:(NSNotification*)notification
{
    [self showFullscreenControls:YES];
}

- (void)windowDidExitFullscreen:(NSNotification*)notification
{
    _nativeFullscreen = NO;
    _window.contentAspectRatio = _videoAspect;
    [self showFullscreenControls:NO];
    [self showIfWindowed];
}

- (NSArray<NSToolbarItemIdentifier>*)toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar
{
    return @[ContextItem, NSToolbarFlexibleSpaceItemIdentifier, ActionsItem];
}

- (NSArray<NSToolbarItemIdentifier>*)toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar
{
    return [self toolbarAllowedItemIdentifiers:toolbar];
}

- (NSToolbarItem*)toolbar:(NSToolbar*)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier
          willBeInsertedIntoToolbar:(BOOL)willInsert
{
    const BOOL isContext = [identifier isEqualToString:ContextItem];
    if (!isContext && ![identifier isEqualToString:ActionsItem]) return nil;
    NSToolbarItem* item = [[[NSToolbarItem alloc] initWithItemIdentifier:identifier] autorelease];
    item.label = isContext ? @"连接" : @"会话操作";
    item.view = isContext ? _context : _actions;
    item.autovalidates = NO;
    item.visibilityPriority = NSToolbarItemVisibilityPriorityHigh;
    return item;
}

- (void)updateConnectionQuality:(BOOL)poor
{
    _dot->poor = poor;
    _dot.needsDisplay = YES;
    NSString* text = poor ? @"网络较差" : @"已连接";
    _statusText.stringValue = text;
    _statusText.textColor = rgb(poor ? 0x946317 : 0x52647b);
    [_status setAccessibilityLabel:[text stringByAppendingString:@"，查看连接详情"]];
    [self resizeItems];
}

- (void)sendButtonAction:(NSButton*)sender
{
    sendAction(streamWindowId, static_cast<AuroraToolbarAction>(sender.tag));
}


- (AuroraToolbarButton*)controlRow:(NSString*)title symbol:(NSString*)symbol
                              y:(CGFloat)y action:(SEL)action tag:(NSInteger)tag next:(BOOL)next
{
    auto* button = [[[AuroraToolbarButton alloc] initWithLabel:title symbol:symbol
        target:self action:action warning:NO] autorelease];
    button.tag = tag;
    button.frame = NSMakeRect(0, y, 274, 34);
    [button useMenuLayout:next];
    return button;
}

- (void)renderControlCenter
{
    if (!_controlCenter) return;
    constexpr CGFloat width = 288;
    NSView* root = _controlCenter.contentView;
    _bitrateLabel = nil;
    _bitrateFeedback = nil;
    _bitrateSlider = nil;
    root.subviews = @[];
    auto* body = [[[AuroraControlPageView alloc] initWithFrame:NSMakeRect(0, 0, 274, 0)] autorelease];
    CGFloat y = 0;
    auto row = [&](NSString* title, NSString* symbol, SEL action, NSInteger tag, BOOL next = NO) {
        [body addSubview:[self controlRow:title symbol:symbol y:y action:action tag:tag next:next]];
        y += 34;
    };
    auto label = [&](NSString* text, BOOL muted = NO) {
        auto* field = [NSTextField labelWithString:text];
        field.textColor = rgb(muted ? 0x526176 : 0x19283f);
        field.font = [NSFont systemFontOfSize:muted ? 12 : 13];
        field.frame = NSMakeRect(8, y + 4, 258, 18);
        [body addSubview:field];
        y += 25;
        return field;
    };
    auto choice = [&](NSString* title, NSString* key, NSArray<NSString*>* labels, NSArray<NSString*>* values) {
        label(title);
        auto* group = [[[NSView alloc] initWithFrame:NSMakeRect(8, y, 258, 26)] autorelease];
        group.identifier = key;
        [group setAccessibilityLabel:title];
        const CGFloat gap = 4;
        const CGFloat units = labels.count + ([key isEqualToString:@"resolution"] ? 0.9 : 0);
        const CGFloat unit = (258 - gap * (labels.count - 1)) / units;
        CGFloat x = 0;
        for (NSUInteger index = 0; index < labels.count; index++) {
            const CGFloat buttonWidth = unit * ((index == 0 && units > labels.count) ? 1.9 : 1);
            auto* button = [[[AuroraToolbarButton alloc] initWithLabel:labels[index] symbol:@""
                target:self action:@selector(changeControlChoice:) warning:NO] autorelease];
            button.frame = NSMakeRect(x, 0, buttonWidth, 26);
            button.identifier = values[index];
            button.enabled = _preferences != nil;
            [button useOptionStyle:[values[index] isEqualToString:_preferences[key]]];
            [group addSubview:button];
            x += buttonWidth + gap;
        }
        [body addSubview:group];
        y += 32;
    };
    auto toggle = [&](NSString* title, NSString* key, BOOL invert = NO) {
        auto* field = [NSTextField labelWithString:title];
        field.font = [NSFont systemFontOfSize:13];
        field.textColor = rgb(0x19283f);
        field.frame = NSMakeRect(8, y + 7, 190, 18);
        [body addSubview:field];
        auto* button = [[[NSSwitch alloc] initWithFrame:NSMakeRect(221, y + 4, 45, 23)] autorelease];
        button.controlSize = NSControlSizeSmall;
        button.identifier = key;
        button.state = ([_preferences[key] isEqualToString:@"on"] != invert) ? NSControlStateValueOn : NSControlStateValueOff;
        button.target = self;
        button.action = @selector(changeControlSwitch:);
        button.enabled = _preferences != nil;
        [button setAccessibilityLabel:title];
        [body addSubview:button];
        y += 31;
    };

    NSArray<NSString*>* titles = @[@"画质", @"声音", @"输入", @"安全"];
    NSArray<NSString*>* icons = @[@"display", @"speaker.wave.2", @"computermouse", @"shield"];
    if (_controlPage == 0) {
        for (NSUInteger index = 0; index < titles.count; index++) {
            row(titles[index], icons[index], @selector(openControlPage:), index + 1, YES);
        }
        auto* divider = [[[NSBox alloc] initWithFrame:NSMakeRect(0, y + 5, 274, 1)] autorelease];
        divider.boxType = NSBoxSeparator;
        [body addSubview:divider];
        y += 11;
        if (_showFloatingControls) {
            row(@"连接详情", @"info.circle", @selector(showFullscreenDetails:), 0);
            row(@"断开连接", @"rectangle.portrait.and.arrow.right", @selector(runControlAction:),
                static_cast<NSInteger>(AuroraToolbarAction::Disconnect));
        }
        row(_showFloatingControls ? @"退出全屏" : @"全屏", @"arrow.up.left.and.arrow.down.right",
            @selector(runControlAction:), static_cast<NSInteger>(AuroraToolbarAction::ToggleFullscreen));
    } else {
        row(titles[_controlPage - 1], @"arrow.left", @selector(openControlPage:), 0);
        if (_controlPage != 4) {
            auto* note = [NSTextField labelWithString:@"下次连接生效"];
            note.font = [NSFont systemFontOfSize:11];
            note.textColor = rgb(0x526176);
            note.frame = NSMakeRect(167, 9, 99, 18);
            note.alignment = NSTextAlignmentRight;
            [body addSubview:note];
        }
        switch (_controlPage) {
        case 1: {
            choice(@"分辨率", @"resolution", @[@"跟随被控端", @"720p", @"1080p", @"1440p", @"4K"],
                   @[@"host", @"1280x720", @"1920x1080", @"2560x1440", @"3840x2160"]);
            choice(@"帧率", @"fps", @[@"30 FPS", @"60 FPS"], @[@"30", @"60"]);
            auto* bitrateTitle = label(@"视频码率");
            auto* value = [NSTextField labelWithString:@""];
            value.font = [NSFont systemFontOfSize:12];
            value.textColor = rgb(0x526176);
            value.alignment = NSTextAlignmentRight;
            value.frame = NSMakeRect(160, NSMinY(bitrateTitle.frame), 106, 18);
            [body addSubview:value];
            auto* rate = [NSSlider sliderWithValue:0.5 minValue:0.5
                maxValue:150 target:self action:@selector(changeControlBitrate:)];
            rate.frame = NSMakeRect(8, y, 258, 25);
            rate.continuous = NO;
            [rate setAccessibilityLabel:@"视频码率（Mbps）"];
            [body addSubview:rate];
            _bitrateLabel = value;
            _bitrateSlider = rate;
            y += 29;
            _bitrateFeedback = label(@"", YES);
            [self updateBitrateControls];
            choice(@"视频编码", @"video-codec", @[@"自动", @"H.264", @"HEVC", @"AV1"], @[@"auto", @"H.264", @"HEVC", @"AV1"]);
            toggle(@"HDR", @"hdr");
            toggle(@"性能统计", @"performance-overlay");
            break;
        }
        case 2:
            choice(@"音频配置", @"audio-config", @[@"立体声", @"5.1 环绕声", @"7.1 环绕声"],
                   @[@"stereo", @"5.1-surround", @"7.1-surround"]);
            toggle(@"远端扬声器静音", @"audio-on-host", YES);
            toggle(@"失焦静音", @"mute-on-focus-loss");
            break;
        case 3:
            choice(@"鼠标模式", @"absolute-mouse", @[@"桌面指针", @"锁定鼠标"], @[@"on", @"off"]);
            toggle(@"交换鼠标左右键", @"mouse-buttons-swap");
            toggle(@"反转滚轮", @"reverse-scroll-direction");
            row(@"释放当前鼠标", @"computermouse", @selector(runControlAction:),
                static_cast<NSInteger>(AuroraToolbarAction::ReleaseMouse));
            break;
        case 4: {
            label(@"隐私保护");
            const bool hasTarget = privacy && privacy->live && !privacy->target.program.isEmpty();
            const auto state = hasTarget ? privacy->state : AuroraPrivacyState::Unavailable;
            const bool busy = hasTarget && privacy->busy;

            NSMutableArray<NSString*>* labels = [NSMutableArray arrayWithCapacity:PrivacyChoices.size()];
            NSInteger selected = -1;
            for (const auto& choice : PrivacyChoices) {
                if (state == choice.state) selected = labels.count;
                [labels addObject:choice.label];
            }
            auto* modes = [NSSegmentedControl segmentedControlWithLabels:labels
                trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changePrivacyMode:)];
            modes.frame = NSMakeRect(8, y, 258, 26);
            modes.selectedSegment = selected;
            modes.enabled = !busy && selected >= 0;
            [modes setAccessibilityLabel:@"隐私保护"];
            [body addSubview:modes];
            y += 32;

            if (busy) label(@"正在确认隐私保护…", YES);
            else if (state == AuroraPrivacyState::Unavailable) label(@"当前会话不支持隐私保护", YES);
            else if (privacy->changeRejected) label(@"主机未切换到所选状态", YES);
            else if (selected < 0) {
                label(@"无法确认隐私保护", YES);
                row(@"重新检查", @"shield", @selector(refreshPrivacy:), 0);
            }
            break;
        }
        }
    }

    CGFloat available = NSHeight(_window.contentView.bounds) - 32;
    if (_window.screen) available = std::min(available, NSHeight(_window.screen.visibleFrame) - 100);
    const CGFloat height = std::min(y + 12, std::max(CGFloat(124), available));
    body.frame = NSMakeRect(0, 0, 274, y);
    auto* scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(6, 6, width - 12, height - 12)] autorelease];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = y > height - 12;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.documentView = body;
    [_controlCenter setContentSize:NSMakeSize(width, height)];
    [root addSubview:scroll];
    [scroll.contentView scrollToPoint:NSZeroPoint];
    if (_controlCenter.visible) {
        [self positionControlCenter];
        [_controlCenter makeFirstResponder:body.subviews.firstObject];
    }
}

- (void)openControlPage:(NSButton*)button
{
    _controlPage = button.tag;
    [self renderControlCenter];
    if (_controlPage == 1 && (_bitrateMode == BitrateMode::Unchecked || _bitrateMode == BitrateMode::Retry)) {
        [self requestBitrate:AuroraBitrate::Request{}];
    }
    if (_controlPage == 4 && privacy &&
        (!privacy->lastStatusCheck.isValid() || privacy->lastStatusCheck.hasExpired(3000))) {
        [self requestPrivacy:AuroraPrivacyOperation::Status];
    }
}

- (void)runControlAction:(NSButton*)button
{
    auto action = static_cast<AuroraToolbarAction>(button.tag);
    [self closeControlCenter];
    sendAction(streamWindowId, action);
}

- (void)showFullscreenDetails:(id)sender
{
    [self closeControlCenter];
    [self showConnectionDetails:sender];
}

- (void)positionControlCenter
{
    if (!_controlAnchor.window) return;
    const NSRect windowFrame = _window.frame;
    const NSRect button = [_controlAnchor.window convertRectToScreen:[_controlAnchor convertRect:_controlAnchor.bounds toView:nil]];
    const NSRect screen = (_window.screen ?: NSScreen.mainScreen).visibleFrame;
    const NSSize size = _controlCenter.frame.size;
    const CGFloat right = NSWidth(windowFrame) < 530 ? NSMaxX(windowFrame) - 8 : NSMaxX(button);
    const CGFloat top = _showFloatingControls ? NSMinY(button) - 4 :
        NSMaxY([_window convertRectToScreen:_window.contentLayoutRect]);
    const CGFloat x = std::clamp(right - size.width, NSMinX(screen) + 6, NSMaxX(screen) - size.width - 6);
    const CGFloat y = std::clamp(top - size.height, NSMinY(screen) + 6, NSMaxY(screen) - size.height - 6);
    [_controlCenter setFrameOrigin:NSMakePoint(x, y)];
}

- (void)closeControlCenter
{
    if (_controlMonitor) [NSEvent removeMonitor:_controlMonitor];
    _controlMonitor = nil;
    if (_controlCenter.parentWindow == _window) [_window removeChildWindow:_controlCenter];
    [_controlCenter orderOut:nil];
    [_controlAnchor markMenuOpen:NO];
    _controlAnchor = nil;
}

- (void)dismissControlCenter:(NSNotification*)notification
{
    [self closeControlCenter];
}

- (void)showControls:(AuroraToolbarButton*)sender
{
    if (_controlCenter.visible) {
        [self closeControlCenter];
        return;
    }
    [self closeConnectionDetails];
    sendAction(streamWindowId, AuroraToolbarAction::ReleaseMouse);
    _controlAnchor = sender;
    _controlPage = 0;
    if (!_controlCenter) {
        _controlCenter = [[AuroraControlPanel alloc] initWithContentRect:NSMakeRect(0, 0, 288, 193)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        _controlCenter.opaque = NO;
        _controlCenter.backgroundColor = NSColor.clearColor;
        _controlCenter.hasShadow = YES;
        _controlCenter.hidesOnDeactivate = YES;
        _controlCenter.releasedWhenClosed = NO;
        _controlCenter.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary |
                                             NSWindowCollectionBehaviorIgnoresCycle;
        _controlCenter.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        NSView* frame = _controlCenter.contentView;
        frame.wantsLayer = YES;
        frame.layer.backgroundColor = NSColor.whiteColor.CGColor;
        frame.layer.borderColor = rgb(0xd7dfec).CGColor;
        frame.layer.borderWidth = 1;
        frame.layer.cornerRadius = 9;
        frame.layer.masksToBounds = YES;
    }
    [self renderControlCenter];
    [self positionControlCenter];
    [sender markMenuOpen:YES];
    [_window addChildWindow:_controlCenter ordered:NSWindowAbove];
    [_controlCenter makeKeyAndOrderFront:nil];
    [_controlCenter selectNextKeyView:nil];

    __block AuroraSessionToolbarController* controller = self;
    _controlMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:
        NSEventMaskKeyDown | NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown handler:^NSEvent*(NSEvent* event) {
        if (event.type != NSEventTypeKeyDown) {
            if (event.window == controller->_controlCenter) return event;
            AuroraToolbarButton* trigger = controller->_controlAnchor;
            if (event.window == trigger.window &&
                NSPointInRect([trigger convertPoint:event.locationInWindow fromView:nil], trigger.bounds)) return event;
            [controller closeControlCenter];
            return event;
        }
        if (event.keyCode != 53 || event.window != controller->_controlCenter) return event;
        if (controller->_controlPage == 0) {
            auto* anchorButton = controller->_controlAnchor;
            [controller closeControlCenter];
            [controller->_window makeKeyWindow];
            [anchorButton.window makeFirstResponder:anchorButton];
        } else {
            controller->_controlPage = 0;
            [controller renderControlCenter];
        }
        return nil;
    }];
}

- (void)saveControlValue:(NSString*)value forKey:(NSString*)key
{
    if (!key || !value || !_preferences || [_preferences[key] isEqualToString:value]) return;
    _preferences[key] = value;
    std::fprintf(stdout, "aurora-stream-setting/1\t%s\t%s\n", key.UTF8String, value.UTF8String);
    std::fflush(stdout);
}

- (void)changeControlChoice:(AuroraToolbarButton*)sender
{
    [self saveControlValue:sender.identifier forKey:sender.superview.identifier];
    for (AuroraToolbarButton* option in sender.superview.subviews) [option selectOption:option == sender];
}

- (void)changeControlSwitch:(NSSwitch*)sender
{
    BOOL enabled = (sender.state == NSControlStateValueOn) != ([sender.identifier isEqualToString:@"audio-on-host"]);
    [self saveControlValue:enabled ? @"on" : @"off" forKey:sender.identifier];
}

- (void)changeControlBitrate:(NSSlider*)sender
{
    if (sender != _bitrateSlider || !sender.enabled || !privacy || !privacy->live || privacy->bitrateBusy) return;

    const int kbps = static_cast<int>(std::lround(sender.doubleValue * 2)) * 500;
    if (_bitrateMode == BitrateMode::Live) {
        const int requested = sender.doubleValue >= sender.maxValue ?
            _bitrateMaximumKbps : std::min(kbps, _bitrateMaximumKbps);
        if (requested != _bitrateRequestedKbps) {
            [self requestBitrate:AuroraBitrate::Request{_bitrateSession, QByteArray::number(requested), _bitrateRevision}];
        } else {
            [self updateBitrateControls];
        }
    } else if (_bitrateMode == BitrateMode::SavedOnly) {
        [self saveControlValue:[NSString stringWithFormat:@"%d", kbps] forKey:@"bitrate"];
        [self updateBitrateControls];
    }
}

- (void)updateBitrateControls
{
    if (!_bitrateSlider) return;

    const int requested = _bitrateRequestedKbps ? _bitrateRequestedKbps : [_preferences[@"bitrate"] intValue];
    const int maximum = _bitrateMaximumKbps ? _bitrateMaximumKbps : AuroraBitrate::MaxKbps;
    _bitrateSlider.maxValue = maximum / 1000.0;
    _bitrateSlider.doubleValue = requested / 1000.0;
    const bool busy = privacy && privacy->bitrateBusy;
    _bitrateSlider.enabled = !busy && (_bitrateMode == BitrateMode::Live ||
        (_bitrateMode == BitrateMode::SavedOnly && _preferences));
    _bitrateLabel.stringValue = requested > 0 ? [NSString stringWithFormat:@"%.1f Mbps", requested / 1000.0] : @"—";

    if (busy || _bitrateMode == BitrateMode::Unchecked) {
        _bitrateFeedback.stringValue = _bitrateMode == BitrateMode::Live ? @"正在应用实时码率…" : @"正在查询实时码率…";
    } else if (_bitrateMode == BitrateMode::Live) {
        _bitrateFeedback.stringValue = [NSString stringWithFormat:@"实时编码器：%d kbps", _bitrateEncoderKbps];
    } else if (_bitrateMode == BitrateMode::SavedOnly) {
        _bitrateFeedback.stringValue = @"此项下次连接生效";
    } else {
        _bitrateFeedback.stringValue = @"未确认实时码率，重新打开画质页查询";
    }
}

- (void)requestBitrate:(const AuroraBitrate::Request&)request
{
    if (!privacy || !privacy->live || privacy->bitrateBusy) return;
    if (privacy->target.program.isEmpty()) {
        _bitrateMode = BitrateMode::SavedOnly;
        [self updateBitrateControls];
        return;
    }

    privacy->bitrateBusy = true;
    [self updateBitrateControls];
    const std::weak_ptr<AuroraSessionPrivacy> weak(privacy);
    const auto windowId = streamWindowId;
    QThreadPool::globalInstance()->start([weak, windowId, request]() {
        const auto session = weak.lock();
        if (!session || !session->live) return;

        const auto reply = runAuroraBitrateCommand(session->target, request, session->live);
        if (!session->live) return;

        const auto mainLoop = CFRunLoopGetMain();
        CFRunLoopPerformBlock(mainLoop, kCFRunLoopCommonModes, ^{
            const auto current = weak.lock();
            if (!current || !current->live) return;
            current->bitrateBusy = false;
            auto* toolbar = auroraToolbar(nativeWindow(SDL_GetWindowFromID(windowId)));
            if (toolbar && toolbar->privacy == current) {
                [toolbar finishBitrateRequest:request reply:reply];
            }
        });
        CFRunLoopWakeUp(mainLoop);
    });
}

- (void)finishBitrateRequest:(const AuroraBitrate::Request&)request reply:(const QByteArray&)reply
{
    AuroraBitrate::Confirmation confirmed;
    // Keep a status retry bound to the same server session token.
    if (AuroraBitrate::parseConfirmation(request, reply, confirmed) && (_bitrateSession.isEmpty() ||
            (confirmed.session == _bitrateSession && confirmed.revision >= _bitrateRevision))) {
        _bitrateMode = BitrateMode::Live;
        _bitrateSession = confirmed.session;
        _bitrateRevision = confirmed.revision;
        _bitrateRequestedKbps = confirmed.requestedKbps;
        _bitrateEncoderKbps = confirmed.encoderKbps;
        _bitrateMaximumKbps = confirmed.maximumKbps;
        if (request.setting()) {
            [self saveControlValue:[NSString stringWithFormat:@"%d", _bitrateRequestedKbps] forKey:@"bitrate"];
        }
    } else if (reply == "unsupported" && !request.setting()) {
        _bitrateMode = BitrateMode::SavedOnly;
    } else {
        _bitrateMode = BitrateMode::Retry;
    }
    if (_controlCenter.visible && _controlPage == 1) {
        [self updateBitrateControls];
        if (request.setting() && _bitrateMode == BitrateMode::Retry) {
            [self requestBitrate:AuroraBitrate::Request{}];
        }
    }
}

- (void)showConnectionDetails:(id)sender
{
    [self closeControlCenter];
    if (_connectionDetails.shown) {
        [self closeConnectionDetails];
        return;
    }

    NSView* anchor = sender == _status ? _status : _floatingPanel.contentView;
    if (!anchor.window) return;
    if (!_connectionDetails) {
        _connectionDetails = [[NSPopover alloc] init];
        _connectionDetails.delegate = self;
        _connectionDetails.behavior = NSPopoverBehaviorTransient;
        _connectionDetails.animates = NO;
        _connectionDetails.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        auto* content = [[[NSViewController alloc] init] autorelease];
        content.view = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 292, 80)] autorelease];
        _connectionDetails.contentViewController = content;
    }

    [self refreshConnectionDetails:nil];
    [_connectionDetails showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSRectEdgeMinY];
    if (_connectionDetails.shown) {
        _connectionRefresh = [[NSTimer timerWithTimeInterval:1 target:self
            selector:@selector(refreshConnectionDetails:) userInfo:nil repeats:YES] retain];
        [NSRunLoop.mainRunLoop addTimer:_connectionRefresh forMode:NSRunLoopCommonModes];
    }
}

- (void)refreshConnectionDetails:(NSTimer*)timer
{
    const auto details = AuroraConnectionMonitor::instance().latest();
    std::vector<std::pair<NSString*, NSString*>> rows;
    if (details.roundTripMs > 0) rows.emplace_back(@"网络延迟", [NSString stringWithFormat:@"%d ms", details.roundTripMs]);
    if (details.width > 0 && details.height > 0) {
        rows.emplace_back(@"画面分辨率", [NSString stringWithFormat:@"%d × %d", details.width, details.height]);
    }
    if (details.fpsHundredths > 0) rows.emplace_back(@"接收帧率", [NSString stringWithFormat:@"%.1f FPS", details.fpsHundredths / 100.0]);
    if (details.videoKbps > 0) rows.emplace_back(@"接收码率", [NSString stringWithFormat:@"%.1f Mbps", details.videoKbps / 1000.0]);
    if (details.lossHundredths >= 0) rows.emplace_back(@"网络丢帧", [NSString stringWithFormat:@"%.1f%%", details.lossHundredths / 100.0]);
    if (details.codec >= 1 && details.codec <= 3) {
        NSArray<NSString*>* codecs = @[@"H.264", @"HEVC", @"AV1"];
        rows.emplace_back(@"视频编码", codecs[details.codec - 1]);
    }
    if (details.decodeMicroseconds >= 0) rows.emplace_back(@"平均解码耗时", [NSString stringWithFormat:@"%.1f ms", details.decodeMicroseconds / 1000.0]);
    if (rows.empty()) rows.emplace_back(@"暂无连接参数", @"");

    NSView* view = _connectionDetails.contentViewController.view;
    view.subviews = @[];
    const CGFloat height = 43 + 23 * rows.size();
    auto* title = [NSTextField labelWithString:@"连接详情"];
    title.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    title.frame = NSMakeRect(13, height - 30, 266, 18);
    [view addSubview:title];
    CGFloat y = height - 54;
    for (const auto& row : rows) {
        auto* name = [NSTextField labelWithString:row.first];
        auto* value = [NSTextField labelWithString:row.second];
        name.frame = NSMakeRect(13, y, 132, 18);
        name.textColor = NSColor.secondaryLabelColor;
        value.frame = NSMakeRect(145, y, 134, 18);
        value.alignment = NSTextAlignmentRight;
        [view addSubview:name];
        [view addSubview:value];
        y -= 23;
    }
    _connectionDetails.contentSize = NSMakeSize(292, height);
}

- (void)closeConnectionDetails
{
    [_connectionRefresh invalidate];
    [_connectionRefresh release];
    _connectionRefresh = nil;
    [_connectionDetails close];
}

- (void)popoverDidClose:(NSNotification*)notification
{
    [_connectionRefresh invalidate];
    [_connectionRefresh release];
    _connectionRefresh = nil;
}

- (void)updatePrivacyMenu
{
    if (_controlCenter.visible && _controlPage == 4) [self renderControlCenter];
}

- (void)requestPrivacy:(AuroraPrivacyOperation)operation
{
    if (!privacy || !privacy->live || privacy->target.program.isEmpty() || privacy->busy) {
        return;
    }
    privacy->busy = true;
    privacy->changeRejected = false;
    privacy->lastStatusCheck.start();
    [self updatePrivacyMenu];

    const std::weak_ptr<AuroraSessionPrivacy> weak(privacy);
    const auto windowId = streamWindowId;
    QThreadPool::globalInstance()->start([weak, windowId, operation]() {
        const auto session = weak.lock();
        if (!session || !session->live) {
            return;
        }
        const auto result = runAuroraPrivacyCommand(session->target, operation, session->live);
        if (!session->live) {
            return;
        }
        const auto mainLoop = CFRunLoopGetMain();
        CFRunLoopPerformBlock(mainLoop, kCFRunLoopCommonModes, ^{
            const auto current = weak.lock();
            if (!current || !current->live) {
                return;
            }
            current->busy = false;
            current->lastStatusCheck.restart();
            current->state = result;
            const auto choice = std::find_if(PrivacyChoices.begin(), PrivacyChoices.end(),
                [operation](const PrivacyChoice& option) { return option.operation == operation; });
            current->changeRejected = choice != PrivacyChoices.end() &&
                result != AuroraPrivacyState::Unavailable && result != AuroraPrivacyState::Error &&
                result != choice->state;
            AuroraSessionToolbarController* toolbar = auroraToolbar(nativeWindow(SDL_GetWindowFromID(windowId)));
            if (toolbar && toolbar->privacy == current) {
                [toolbar updatePrivacyMenu];
            }
        });
        CFRunLoopWakeUp(mainLoop);
    });
}

- (void)changePrivacyMode:(NSSegmentedControl*)sender
{
    const NSInteger selected = sender.selectedSegment;
    if (!sender.enabled || !privacy || selected < 0 ||
        selected >= static_cast<NSInteger>(PrivacyChoices.size())) return;

    const auto& choice = PrivacyChoices[selected];
    if (choice.state != privacy->state) [self requestPrivacy:choice.operation];
}

- (void)refreshPrivacy:(NSButton*)sender
{
    [self requestPrivacy:AuroraPrivacyOperation::Status];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self closeControlCenter];
    [_controlCenter release];
    [_preferences release];
    _connectionDetails.delegate = nil;
    [self closeConnectionDetails];
    [_connectionDetails release];
    [_floatingPanel release];
    [_context release];
    [_actions release];
    [super dealloc];
}
@end

static void installSessionToolbar(NSWindow* native, AuroraSessionToolbarController* controller)
{
    // AppKit owns the traffic lights and titlebar. Preserve the content geometry.
    const NSSize contentSize = native.contentView.bounds.size;
    native.titleVisibility = NSWindowTitleHidden;
    native.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
    native.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    native.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    native.backgroundColor = rgb(0xedf1f8);
    native.titlebarAppearsTransparent = YES;

    auto* toolbar = [[NSToolbar alloc] initWithIdentifier:@"AuroraStreamUnifiedToolbar"];
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    toolbar.allowsUserCustomization = NO;
    toolbar.autosavesConfiguration = NO;
    toolbar.delegate = controller;
    native.toolbar = toolbar;
    [toolbar release];

    if (!NSEqualSizes(native.contentView.bounds.size, contentSize)) {
        [native setContentSize:contentSize];
    }
    NSSize minimum = native.contentMinSize;
    if (minimum.width < 400) {
        minimum.width = 400;
        native.contentMinSize = minimum;
    }
    [controller resizeItems];
}

void installAuroraConnectionToolbar(NSWindow* window, NSString* deviceName, id cancelTarget, SEL cancelAction)
{
    auto* controller = [[AuroraSessionToolbarController alloc] initWithWindow:window
        deviceName:deviceName connecting:YES];
    objc_setAssociatedObject(window, &ControllerKey, controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [controller setConnectionFailed:NO cancelTarget:cancelTarget cancelAction:cancelAction];
    installSessionToolbar(window, controller);
    [controller release];
}

void setAuroraConnectionToolbarFailed(NSWindow* window, bool failed)
{
    auto* controller = auroraToolbar(window);
    if (controller) [controller updateConnectionResult:failed];
}

bool installAuroraSessionToolbar(SDL_Window* window, const QString& deviceName, bool connectionPoor,
                                 const std::shared_ptr<AuroraSessionPrivacy>& privacy, int videoWidth, int videoHeight)
{
    if (![NSThread isMainThread] || !window) return false;
    NSWindow* native = nativeWindow(window);
    if (!native) return false;

    const BOOL fullscreen = (SDL_GetWindowFlags(window) & SDL_WINDOW_FULLSCREEN) ||
                            (native.styleMask & NSWindowStyleMaskFullScreen);
    if (!fullscreen && (!(native.styleMask & NSWindowStyleMaskTitled) ||
                        (native.styleMask & NSWindowStyleMaskFullSizeContentView))) return false;

    auto* controller = auroraToolbar(native);
    if (!controller) {
        const auto preferred = qEnvironmentVariable("AURORA_STREAM_DEVICE_NAME").simplified();
        const auto utf8 = (preferred.isEmpty() ? deviceName : preferred).toUtf8();
        NSString* name = [NSString stringWithUTF8String:utf8.constData()];
        controller = [[AuroraSessionToolbarController alloc] initWithWindow:native
            deviceName:name.length ? name : @"远程设备" connecting:NO];
        controller->streamWindowId = SDL_GetWindowID(window);
        controller->privacy = privacy;
        objc_setAssociatedObject(native, &ControllerKey, controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [controller release];
        [controller updateConnectionQuality:connectionPoor];
        [controller updatePrivacyMenu];
    }

    if (privacy && !privacy->lastStatusCheck.isValid())
        [controller requestPrivacy:AuroraPrivacyOperation::Status];

    [controller setVideoWidth:videoWidth height:videoHeight fullscreen:fullscreen];
    [controller showFullscreenControls:fullscreen];
    if (fullscreen) return false;
    if (native.toolbar.delegate == controller) {
        [controller showIfWindowed];
        return true;
    }

    installSessionToolbar(native, controller);
    return true;
}

void prepareAuroraSessionToolbarForFullscreenChange(SDL_Window* window, bool enteringFullscreen)
{
    NSWindow* native = nativeWindow(window);
    if (!auroraToolbar(native)) return;

    native.contentAspectRatio = NSZeroSize;
    if (!enteringFullscreen && native.toolbar.visible) native.toolbar.visible = NO;
}

void closeAuroraFullscreenControls(SDL_Window* window)
{
    auto* controller = auroraToolbar(nativeWindow(window));
    [controller closeConnectionDetails];
    [controller showFullscreenControls:NO];
}

void setAuroraSessionToolbarConnectionQuality(SDL_Window* window, bool poor)
{
    [auroraToolbar(nativeWindow(window)) updateConnectionQuality:poor];
}
