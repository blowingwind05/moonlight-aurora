#include "aurora-session-toolbar.h"
#include "aurora-session-toolbar-layout.h"
#include "aurora-connection-details.h"
#include <vector>
#include "aurora-session-privacy.h"

#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#include <SDL_syswm.h>
#include <QThreadPool>
#include <cmath>

namespace {
    constexpr CGFloat GroupHeight = 44;
    constexpr CGFloat DisplayTabHeight = 37;
    constexpr CGFloat BrandSize = 28;
    constexpr CGFloat ButtonHeight = 32;
    constexpr CGFloat FloatingButtonSize = 40;
    constexpr CGFloat FloatingButtonInset = 14;
    NSString* const ContextItem = @"AuroraSessionContext";
    NSString* const ActionsItem = @"AuroraSessionActions";
    char ControllerKey;

    NSColor* rgb(unsigned color)
    {
        return [NSColor colorWithSRGBRed:((color >> 16) & 0xff) / 255.0
                                   green:((color >> 8) & 0xff) / 255.0
                                    blue:(color & 0xff) / 255.0 alpha:1];
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
}
- (instancetype)initWithLabel:(NSString*)label symbol:(NSString*)symbol
                       target:(id)target action:(SEL)action warning:(BOOL)warning;
- (void)showLabel:(BOOL)show;
- (void)markMenuOpen:(BOOL)open;
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
        NSImage* image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
        _glyph.image = [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration
            configurationWithPointSize:15 weight:NSFontWeightRegular]];
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
    const CGFloat left = std::floor((NSWidth(self.bounds) - rowWidth) / 2);
    const CGFloat middle = NSMidY(self.bounds);
    _glyph.frame = NSMakeRect(left, middle - iconSize / 2, iconSize, iconSize);
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

- (void)drawRect:(NSRect)dirtyRect
{
    if (self.enabled && (_hover || _menuOpen || self.cell.highlighted)) {
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
    const CGFloat left = _caption.hidden ? std::floor((NSWidth(self.bounds) - 14) / 2) : 11;
    _glyph.frame = NSMakeRect(left, middle - 7, 14, 14);
    const CGFloat height = std::ceil(_caption.intrinsicContentSize.height);
    _caption.frame = NSMakeRect(left + 20, std::floor(middle - height / 2),
                                std::max<CGFloat>(0, NSWidth(self.bounds) - left - 26), height);
}

- (void)drawRect:(NSRect)dirtyRect
{
    [rgb(0xffffff) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:10 yRadius:10] fill];
    NSRectFill(NSMakeRect(0, 0, NSWidth(self.bounds), 10));
}

- (BOOL)mouseDownCanMoveWindow { return YES; }
@end

@interface AuroraConnectionStatus : NSButton
@end

@implementation AuroraConnectionStatus
- (NSView*)hitTest:(NSPoint)point { return [super hitTest:point] ? self : nil; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
@end

@interface AuroraSessionToolbarController : NSObject <NSToolbarDelegate, NSMenuDelegate, NSPopoverDelegate> {
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
    NSMenuItem* _fullscreenDetailsItem;
    AuroraStatusDot* _dot;
    NSTextField* _statusText;
    AuroraDisplayTab* _display;
    BOOL _connectionWindow;
    AuroraToolbarButton* _controls;
    AuroraToolbarButton* _disconnect;
    NSImageView* _brand;
    NSMenu* _controlMenu;
    NSMenuItem* _privacyItem;
    NSMenuItem* _privacyNote;
    NSMenuItem* _exitFullscreen;
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

    _controls = [self addButton:@"控制中心" symbol:@"slider.horizontal.3" action:@selector(showControls:)
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

    _controlMenu = [[NSMenu alloc] initWithTitle:@"控制中心"];
    _controlMenu.minimumWidth = 224;
    _controlMenu.autoenablesItems = NO;
    _controlMenu.delegate = self;
    _privacyItem = [[NSMenuItem alloc] initWithTitle:@"隐私保护" action:@selector(togglePrivacy:) keyEquivalent:@""];
    _privacyItem.target = self;
    [_controlMenu addItem:_privacyItem];
    [_privacyItem release];
    _privacyNote = [[NSMenuItem alloc] initWithTitle:@"" action:nullptr keyEquivalent:@""];
    _privacyNote.enabled = NO;
    [_controlMenu addItem:_privacyNote];
    [_privacyNote release];
    [_controlMenu addItem:[NSMenuItem separatorItem]];
    _fullscreenDetailsItem = [_controlMenu addItemWithTitle:@"连接详情" action:@selector(showConnectionDetails:) keyEquivalent:@""];
    _fullscreenDetailsItem.target = self;
    _fullscreenDetailsItem.hidden = YES;
    NSMenuItem* release = [_controlMenu addItemWithTitle:@"释放鼠标" action:@selector(sendMenuAction:) keyEquivalent:@"z"];
    release.target = self;
    release.tag = static_cast<NSInteger>(AuroraToolbarAction::ReleaseMouse);
    release.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift;
    [_controlMenu addItem:[NSMenuItem separatorItem]];
    _exitFullscreen = [_controlMenu addItemWithTitle:@"全屏" action:@selector(sendMenuAction:) keyEquivalent:@""];
    _exitFullscreen.target = self;
    _exitFullscreen.tag = static_cast<NSInteger>(AuroraToolbarAction::ToggleFullscreen);
    NSMenuItem* disconnect = [_controlMenu addItemWithTitle:@"断开连接" action:@selector(sendMenuAction:) keyEquivalent:@""];
    disconnect.target = self;
    disconnect.tag = static_cast<NSInteger>(AuroraToolbarAction::Disconnect);

    NSNotificationCenter* notifications = NSNotificationCenter.defaultCenter;
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
    _display.frame = NSMakeRect(NSMaxX(_status.frame) + 6, 0, layout.display, DisplayTabHeight);

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
    _exitFullscreen.title = visible ? @"退出全屏" : @"全屏";
    _fullscreenDetailsItem.hidden = !visible;
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
            symbol:@"slider.horizontal.3" target:self action:@selector(showControls:) warning:NO];
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

- (void)sendMenuAction:(NSMenuItem*)sender
{
    sendAction(streamWindowId, static_cast<AuroraToolbarAction>(sender.tag));
}

- (void)showControls:(AuroraToolbarButton*)sender
{
    [self closeConnectionDetails];
    [sender markMenuOpen:YES];
    [_controlMenu popUpMenuPositioningItem:nil atLocation:NSMakePoint(
        NSWidth(sender.bounds) - _controlMenu.minimumWidth, NSMinY(sender.bounds)) inView:sender];
    [sender markMenuOpen:NO];
}

- (void)showConnectionDetails:(id)sender
{
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
    const bool hasTarget = privacy && privacy->live && !privacy->target.program.isEmpty();
    const auto state = hasTarget ? privacy->state : AuroraPrivacyState::Unavailable;
    const bool busy = hasTarget && privacy->busy;
    _privacyItem.enabled = !busy && (state == AuroraPrivacyState::On || state == AuroraPrivacyState::Off);
    _privacyItem.state = !busy && state == AuroraPrivacyState::On ? NSControlStateValueOn : NSControlStateValueOff;

    NSString* note = nil;
    if (busy || state == AuroraPrivacyState::Unknown) {
        note = @"正在确认隐私保护状态…";
    } else if (state == AuroraPrivacyState::Unavailable) {
        note = @"此连接不支持隐私保护";
    } else if (state == AuroraPrivacyState::Error) {
        note = @"无法确认主机状态，重新打开控制中心以重试";
    } else if (privacy->changeRejected) {
        note = @"主机未切换到所选状态";
    }
    _privacyNote.title = note ?: @"";
    _privacyNote.hidden = note == nil;
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
            current->changeRejected =
                (operation == AuroraPrivacyOperation::Enable && result == AuroraPrivacyState::Off) ||
                (operation == AuroraPrivacyOperation::Disable && result == AuroraPrivacyState::On);
            AuroraSessionToolbarController* toolbar = auroraToolbar(nativeWindow(SDL_GetWindowFromID(windowId)));
            if (toolbar && toolbar->privacy == current) {
                [toolbar updatePrivacyMenu];
            }
        });
        CFRunLoopWakeUp(mainLoop);
    });
}

- (void)menuWillOpen:(NSMenu*)menu
{
    [self updatePrivacyMenu];
    if (privacy && (!privacy->lastStatusCheck.isValid() || privacy->lastStatusCheck.hasExpired(3000))) {
        [self requestPrivacy:AuroraPrivacyOperation::Status];
    }
}

- (void)togglePrivacy:(NSMenuItem*)sender
{
    if (!privacy || privacy->busy) return;
    if (privacy->state == AuroraPrivacyState::On) {
        [self requestPrivacy:AuroraPrivacyOperation::Disable];
    } else if (privacy->state == AuroraPrivacyState::Off) {
        [self requestPrivacy:AuroraPrivacyOperation::Enable];
    }
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    _controlMenu.delegate = nil;
    [_controlMenu release];
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

    [controller setVideoWidth:videoWidth height:videoHeight fullscreen:fullscreen];
    [controller showFullscreenControls:fullscreen];
    if (fullscreen) return false;
    if (native.toolbar.delegate == controller) {
        [controller showIfWindowed];
        return true;
    }

    installSessionToolbar(native, controller);
    if (privacy && !privacy->lastStatusCheck.isValid()) {
        [controller requestPrivacy:AuroraPrivacyOperation::Status];
    }
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
