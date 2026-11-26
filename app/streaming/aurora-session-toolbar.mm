#include "aurora-session-toolbar.h"
#include "aurora-session-toolbar-layout.h"
#include "aurora-connection-details.h"
#include <vector>
#include "aurora-session-privacy.h"
#include "../backend/aurora-bitrate.h"
#include "../qt-session/AuroraMacControlsView.h"
#include "../qt-session/AuroraMacPrivacyAppearanceView.h"
#include "../qt-session/AuroraPrivacyArtwork.h"
#include "../qt-session/AuroraMacTitleBarView.h"
#include "../qt-session/AuroraDisplayControls.h"
#include <QCryptographicHash>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QRegularExpression>
#include <QTemporaryDir>
#include <bitset>

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
    constexpr CGFloat DisplayTabTopInset = 7;
    constexpr CGFloat BrandSize = 28;
    constexpr CGFloat ButtonHeight = 32;
    constexpr CGFloat FloatingButtonSize = 40;
    constexpr CGFloat FloatingButtonRadius = 13;
    constexpr CGFloat FloatingButtonInset = 14;
    NSString* const ControlCenterSymbol = @"AuroraSessionControlCenter";
    NSString* const ContextItem = @"AuroraSessionContext";
    NSString* const ActionsItem = @"AuroraSessionActions";
    NSString* const QtTitleItem = @"AuroraQtSessionTitle";
    bool qtTitleVisible = false;
    bool qtAppearanceVisible = false;

    // Shared by the Cocoa owner and in-flight workers. The directory survives
    // until a canceled decoder or helper has finished with its files.
    struct AppearanceEdit {
        QTemporaryDir files;
        std::atomic<bool> live{true};
    };

    bool writeAppearanceImage(const QString& path, const QByteArray& png)
    {
        QFile file(path);
        return !png.isEmpty() && file.open(QIODevice::WriteOnly | QIODevice::NewOnly) &&
               file.write(png) == png.size() && file.flush();
    }

    NSRect cocoaAnchor(NSView* view, const QRectF& rect)
    {
        const CGFloat y = view.isFlipped ? rect.y() : NSHeight(view.bounds) - rect.bottom();
        return NSMakeRect(rect.x(), y, rect.width(), rect.height());
    }
    char ControllerKey;
    bool qtControlsVisible = false;  // Accessed on the SDL/Cocoa main thread.

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

    constexpr CGFloat ToolbarIconSize = 16;
    constexpr CGFloat DisplayIconSize = 14;
    constexpr CGFloat CaptionGap = 5;
    constexpr CGFloat CaptionPadding = 4;

    CGFloat textWidth(NSString* text, NSFont* font)
    {
        return std::ceil([text sizeWithAttributes:@{NSFontAttributeName:font}].width) + CaptionPadding;
    }

    CGFloat captionWidth(NSTextField* caption)
    {
        return textWidth(caption.stringValue, caption.font);
    }

    BOOL isKeyboardInput(NSEvent* event)
    {
        return event && (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp);
    }

    NSImage* monitorImage(CGFloat size)
    {
        auto* icon = [NSImage imageWithSize:NSMakeSize(size, size) flipped:YES drawingHandler:^BOOL(NSRect bounds) {
            const CGFloat stroke = size / 12;
            const CGFloat inset = stroke / 2;
            auto* shape = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(inset, 2 * inset,
                size - stroke, size * .68) xRadius:1.5 yRadius:1.5];
            const CGFloat x = NSMidX(bounds);
            const CGFloat y = size - inset;
            [shape moveToPoint:NSMakePoint(x, 2 * inset + size * .68)];
            [shape lineToPoint:NSMakePoint(x, y)];
            [shape moveToPoint:NSMakePoint(x - size * .2, y)];
            [shape lineToPoint:NSMakePoint(x + size * .2, y)];
            shape.lineWidth = stroke;
            shape.lineCapStyle = NSRoundLineCapStyle;
            [NSColor.blackColor setStroke];
            [shape stroke];
            return YES;
        }];
        [icon setTemplate:YES];
        return icon;
    }

    NSImage* controlCenterImage()
    {
        auto* icon = [NSImage imageWithSize:NSMakeSize(ToolbarIconSize, ToolbarIconSize) flipped:YES
            drawingHandler:^BOOL(NSRect bounds) {
            [NSGraphicsContext saveGraphicsState];
            auto* scale = [NSAffineTransform transform];
            [scale scaleBy:ToolbarIconSize / 24];
            [scale concat];
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
            [NSGraphicsContext restoreGraphicsState];
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

// A native toolbar item hosts only the Qt title content. Its blank space is
// still part of AppKit's drag surface, and the SDL content view stays separate.
@interface AuroraQtTitleHost : AuroraToolbarGroup
@property(nonatomic, assign) AuroraMacTitleBarView* quick;
@property(nonatomic, assign) NSView* quickView;
@end

@implementation AuroraQtTitleHost
- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    self.quickView.frame = self.bounds;
}

- (NSView*)hitTest:(NSPoint)point
{
    NSView* hit = [super hitTest:point];
    if (!self.quick || hit != self.quickView) return hit;
    const NSPoint local = [self.quickView convertPoint:point fromView:self.superview];
    const CGFloat y = self.quickView.isFlipped ? local.y : NSHeight(self.quickView.bounds) - local.y;
    return self.quick->hasButtonAt(QPointF(local.x, y)) ? hit : self;
}
@end

@interface AuroraFocusButton : NSButton {
    BOOL _showsKeyboardFocus;
}
- (void)showKeyboardFocus:(BOOL)visible;
- (CGFloat)keyboardFocusRadius;
@end

@implementation AuroraFocusButton
- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) self.focusRingType = NSFocusRingTypeNone;
    return self;
}

- (void)showKeyboardFocus:(BOOL)visible
{
    if (_showsKeyboardFocus == visible) return;
    _showsKeyboardFocus = visible;
    self.needsDisplay = YES;
}

- (BOOL)becomeFirstResponder
{
    if (![super becomeFirstResponder]) return NO;
    [self showKeyboardFocus:isKeyboardInput(NSApp.currentEvent)];
    return YES;
}

- (BOOL)resignFirstResponder
{
    if (![super resignFirstResponder]) return NO;
    [self showKeyboardFocus:NO];
    return YES;
}

- (void)mouseDown:(NSEvent*)event
{
    [self showKeyboardFocus:NO];
    [super mouseDown:event];
}

- (void)keyDown:(NSEvent*)event
{
    if (self.window.firstResponder == self) [self showKeyboardFocus:YES];
    [super keyDown:event];
}

- (CGFloat)keyboardFocusRadius { return 5; }

- (void)drawRect:(NSRect)dirtyRect
{
    [super drawRect:dirtyRect];
    if (!_showsKeyboardFocus || !self.enabled || !self.window.isKeyWindow ||
        self.window.firstResponder != self) return;
    const CGFloat radius = [self keyboardFocusRadius];
    auto* outline = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2, 2)
                                                   xRadius:radius yRadius:radius];
    outline.lineWidth = 1.5;
    [rgb(0x087cf5) setStroke];
    [outline stroke];
}
@end

@interface AuroraToolbarButton : AuroraFocusButton {
    NSImageView* _glyph;
    NSString* _label;
    NSRect _textRect;
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
- (CGFloat)preferredWidth;
- (void)markMenuOpen:(BOOL)open;
- (void)useMenuLayout:(BOOL)next;
- (void)useOptionStyle:(BOOL)selected;
- (void)selectOption:(BOOL)selected;
- (NSColor*)buttonFillColor;
- (void)drawButtonBackground;
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
        self.toolTip = label;
        [self setAccessibilityLabel:label];

        _glyph = [[[NSImageView alloc] initWithFrame:NSZeroRect] autorelease];
        _glyph.imageScaling = NSImageScaleProportionallyDown;
        if ([symbol isEqualToString:ControlCenterSymbol]) {
            _glyph.image = controlCenterImage();
        } else if ([symbol isEqualToString:@"display"]) {
            _glyph.image = monitorImage(ToolbarIconSize);
        } else if (symbol.length > 0) {
            NSImage* image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
            _glyph.image = [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration
                configurationWithPointSize:15 weight:NSFontWeightRegular]];
        }
        [_glyph setAccessibilityElement:NO];
        [self addSubview:_glyph];

        _label = [label copy];
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
    self.needsDisplay = YES;
}

- (void)showLabel:(BOOL)show
{
    _showsLabel = show;
    self.needsLayout = YES;
    self.needsDisplay = YES;
}

- (CGFloat)glyphWidth
{
    return _glyph.image ? std::max(ToolbarIconSize, std::ceil(_glyph.image.size.width)) : 0;
}

- (NSFont*)labelFont
{
    return [NSFont systemFontOfSize:_menuRow ? 13 : 12];
}

- (CGFloat)preferredWidth
{
    const CGFloat glyph = [self glyphWidth];
    return 2 * 6 + glyph + (glyph ? CaptionGap : 0) + textWidth(_label, [self labelFont]);
}

- (void)layout
{
    [super layout];
    const CGFloat width = NSWidth(self.bounds);
    const CGFloat middle = NSMidY(self.bounds);
    auto* font = [self labelFont];
    const CGFloat height = std::ceil([_label sizeWithAttributes:@{NSFontAttributeName:font}].height) + 2;
    const CGFloat textY = std::floor(middle - height / 2);
    if (_option) {
        _glyph.hidden = YES;
        _textRect = NSMakeRect(3, textY, std::max<CGFloat>(0, width - 6), height);
    } else {
        const CGFloat glyph = [self glyphWidth];
        const BOOL showText = _showsLabel && (_menuRow || width >= [self preferredWidth]);
        const CGFloat gap = showText && glyph > 0 ? CaptionGap : 0;
        const CGFloat trailing = _nextArrow ? 26 : 8;
        const CGFloat room = std::max<CGFloat>(0, width - glyph - gap - (_menuRow ? 8 + trailing : 8));
        const CGFloat label = !showText ? 0 : _menuRow ? room : textWidth(_label, font);
        const CGFloat left = _menuRow ? 8 : std::floor((width - glyph - gap - label) / 2);
        _glyph.frame = NSMakeRect(left, middle - ToolbarIconSize / 2, glyph, ToolbarIconSize);
        _nextArrow.frame = NSMakeRect(width - 19, middle - 6, 12, 12);
        _textRect = NSMakeRect(left + glyph + gap, textY, label, height);
    }
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
    [self selectOption:selected];
    self.needsLayout = YES;
}

- (void)selectOption:(BOOL)selected
{
    _selectedOption = selected;
    self.needsDisplay = YES;
}

- (NSColor*)buttonFillColor
{
    if (_option) return rgb(_selectedOption ? 0xe2e7ef : _hover ? 0xe8edf4 : 0xf4f6fa);
    if (!self.enabled || !(_hover || _menuOpen || self.cell.highlighted)) return nil;
    return rgb(_warning ? 0xf6e4e7 : (_menuOpen || self.cell.highlighted) ? 0xe2e7ef : 0xe8edf4);
}

- (void)drawButtonBackground
{
    if (auto* color = [self buttonFillColor]) {
        [color setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
    }
}

- (void)drawRect:(NSRect)dirtyRect
{
    [self drawButtonBackground];
    const unsigned ink = !self.enabled ? (_option ? 0x8390a1 : 0x9ba7b7) :
        _warning && (_hover || self.cell.highlighted) ? 0x9a3241 :
        _option && _selectedOption ? 0x2350b4 : 0x19283f;
    NSColor* foreground = rgb(ink);
    if (![_glyph.contentTintColor isEqual:foreground]) _glyph.contentTintColor = foreground;
    if (_showsLabel && !NSIsEmptyRect(_textRect)) {
        // Measure and draw with the same font. An NSTextField cell adds its own
        // drawing insets inside its assigned frame, which can elide even a two-character label.
        auto* paragraph = [[[NSMutableParagraphStyle alloc] init] autorelease];
        paragraph.alignment = _option ? NSTextAlignmentCenter : NSTextAlignmentLeft;
        paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
        [_label drawWithRect:_textRect
                     options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                  attributes:@{NSFontAttributeName:[self labelFont], NSForegroundColorAttributeName:foreground,
                               NSParagraphStyleAttributeName:paragraph}
                     context:nil];
    }
    [super drawRect:dirtyRect];
}

- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)dealloc
{
    if (_tracking) [self removeTrackingArea:_tracking];
    [_tracking release];
    [_label release];
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

- (CGFloat)keyboardFocusRadius { return FloatingButtonRadius - 2; }

- (void)drawButtonBackground
{
    auto* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                                 xRadius:FloatingButtonRadius yRadius:FloatingButtonRadius];
    [([self buttonFillColor] ?: rgb(0xf7f9fd)) setFill];
    [shape fill];
    [rgb(0xc6d1e0) setStroke];
    [shape stroke];
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
- (CGFloat)preferredWidth;
@end

@implementation AuroraDisplayTab
- (instancetype)init
{
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _glyph = [[[NSImageView alloc] initWithFrame:NSZeroRect] autorelease];
        _glyph.imageScaling = NSImageScaleProportionallyDown;
        _glyph.image = monitorImage(DisplayIconSize);
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
    const CGFloat groupWidth = _caption.hidden ? DisplayIconSize : DisplayIconSize + CaptionGap + captionWidth(_caption);
    const CGFloat left = _caption.hidden ? std::floor((NSWidth(self.bounds) - groupWidth) / 2) : foot + 11;
    _glyph.frame = NSMakeRect(left, middle - DisplayIconSize / 2, DisplayIconSize, DisplayIconSize);
    const CGFloat height = std::ceil(_caption.intrinsicContentSize.height);
    _caption.frame = NSMakeRect(left + DisplayIconSize + CaptionGap, std::floor(middle - height / 2),
                                std::max<CGFloat>(0, NSWidth(self.bounds) - foot - 11 - left - DisplayIconSize - CaptionGap),
                                height);
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

- (CGFloat)preferredWidth
{
    return 2 * 11 + DisplayIconSize + CaptionGap + captionWidth(_caption);
}

- (NSView*)hitTest:(NSPoint)point { return nil; }
@end

@interface AuroraConnectionStatus : AuroraFocusButton
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

@interface AuroraControlPanel : NSPanel {
    NSControl* _keyboardControl;
    BOOL _keyboardNavigation;
}
@property(nonatomic) BOOL keyboardNavigation;
@end

@implementation AuroraControlPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)keyboardNavigation { return _keyboardNavigation; }

- (void)refreshKeyboardFocus
{
    auto* responder = self.firstResponder;
    NSControl* control = _keyboardNavigation && [responder isKindOfClass:NSControl.class] ? (NSControl*)responder : nil;
    if (control == _keyboardControl) return;
    if ([_keyboardControl isKindOfClass:AuroraFocusButton.class]) {
        [(AuroraFocusButton*)_keyboardControl showKeyboardFocus:NO];
    } else if (_keyboardControl) {
        _keyboardControl.focusRingType = NSFocusRingTypeNone;
        [_keyboardControl setKeyboardFocusRingNeedsDisplayInRect:_keyboardControl.bounds];
    }
    [_keyboardControl release];
    _keyboardControl = [control retain];
    if ([control isKindOfClass:AuroraFocusButton.class]) {
        [(AuroraFocusButton*)control showKeyboardFocus:YES];
    } else if (control) {
        control.focusRingType = NSFocusRingTypeDefault;
        [control setKeyboardFocusRingNeedsDisplayInRect:control.bounds];
    }
}

- (void)setKeyboardNavigation:(BOOL)keyboard
{
    _keyboardNavigation = keyboard;
    [self refreshKeyboardFocus];
}

- (BOOL)makeFirstResponder:(NSResponder*)responder
{
    const BOOL changed = [super makeFirstResponder:responder];
    [self refreshKeyboardFocus];
    return changed;
}

- (void)sendEvent:(NSEvent*)event
{
    switch (event.type) {
    case NSEventTypeKeyDown:
    case NSEventTypeKeyUp:
        self.keyboardNavigation = YES;
        break;
    case NSEventTypeLeftMouseDown:
    case NSEventTypeRightMouseDown:
    case NSEventTypeOtherMouseDown:
        self.keyboardNavigation = NO;
        break;
    default:
        break;
    }
    [super sendEvent:event];
}

- (void)dealloc
{
    [_keyboardControl release];
    _keyboardControl = nil;
    [super dealloc];
}
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
    NSRect _displaySlot;
    BOOL _connectionWindow;
    AuroraToolbarButton* _controls;
    AuroraToolbarButton* _disconnect;
    NSImageView* _brand;
    AuroraControlPanel* _controlCenter;
    AuroraMacControlsView* _qtControls;
    AuroraMacPrivacyAppearanceView* _appearanceEditor;
    NSOpenPanel* _appearancePicker;
    std::shared_ptr<AppearanceEdit> _appearanceEdit;
    std::bitset<256> _appearanceMouseButtons;
    NSView* _controlAnchor;
    AuroraMacTitleBarView* _qtTitle;
    AuroraQtTitleHost* _qtTitleHost;
    QVariantMap _displayState;
    QElapsedTimer _lastDisplayProbe;
    int _displayProbeCount;
    BOOL _displayProbePending;
    BOOL _displayUnsupported;
    QElapsedTimer _qtTitleProbe;
    BOOL _qtTitleFailed;
    BOOL _qtTitleHasFrame;
    BOOL _qtTitleOwnsKeyboard;
    std::bitset<SDL_NUM_SCANCODES> _localKeys;
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
    BOOL _nativeFullscreenTransition;
    BOOL _sdlFullscreenRequest;
    NSSize _videoAspect;
}
- (instancetype)initWithWindow:(NSWindow*)window deviceName:(NSString*)name connecting:(BOOL)connecting;
- (void)setConnectionFailed:(BOOL)failed cancelTarget:(id)target cancelAction:(SEL)action;
- (void)updateConnectionResult:(BOOL)failed;
- (AuroraToolbarButton*)addButton:(NSString*)title symbol:(NSString*)symbol action:(SEL)action
                            code:(AuroraToolbarAction)code warning:(BOOL)warning;
- (void)resizeItems;
- (void)positionDisplayTab:(NSNotification*)notification;
- (void)showConnectionDetails:(id)sender;
- (void)closeConnectionDetails;
- (void)refreshConnectionDetails:(NSTimer*)timer;
- (void)showIfWindowed;
- (void)setVideoWidth:(int)width height:(int)height fullscreen:(BOOL)fullscreen;
- (void)showFullscreenControls:(BOOL)visible;
- (void)positionFullscreenControls;
- (BOOL)fullscreenTransitioning;
- (void)beginFullscreenRequest;
- (void)finishFullscreenRequest:(BOOL)accepted;
- (void)syncFullscreenChrome;
- (void)updateConnectionQuality:(BOOL)poor;
- (void)requestPrivacy:(AuroraPrivacyOperation)operation;
- (void)updatePrivacyMenu;
- (void)updateBitrateControls;
- (void)requestBitrate:(const AuroraBitrate::Request&)request;
- (void)finishBitrateRequest:(const AuroraBitrate::Request&)request reply:(const QByteArray&)reply;
- (void)closeControlCenter;
- (void)positionControlCenter;
- (void)openPrivacyAppearance:(id)sender;
- (void)endPrivacyAppearance;
- (void)pickPrivacyAppearance:(int)request;
- (void)submitPrivacyAppearance:(int)request style:(const QVariantMap&)style;
- (void)runPrivacyAppearance:(AuroraPrivacyAppearanceAction)action request:(int)request file:(const QString&)file;
- (BOOL)routePrivacyEditorMouseButton:(const SDL_MouseButtonEvent&)button;
- (void)prepareQtTitleBar;
- (void)checkDisplays;
- (void)requestDisplay:(const QString&)operation id:(const QString&)id;
- (void)showDisplaysFrom:(const QRectF&)rect;
- (void)selectDisplayFromMenu:(NSMenuItem*)sender;
- (void)removeDisplayFromMenu:(NSMenuItem*)sender;
- (void)createDisplayFromMenu:(NSMenuItem*)sender;
- (NSWindowToolbarStyle)sessionToolbarStyle;
- (void)checkQtTitleBar;
- (void)hideQtTitleBar;
- (void)destroyQtTitleBar;
- (void)openControlsFrom:(NSView*)source keyboard:(BOOL)keyboard;
- (void)showDetailsFrom:(NSView*)source bounds:(NSRect)bounds;
- (BOOL)routeLocalKey:(const SDL_KeyboardEvent&)key captureActive:(BOOL)captureActive;
- (void)restoreVideoFocus;
- (void)showControlPage:(NSInteger)page;
- (void)dispatchControlAction:(AuroraToolbarAction)action;
@end

static AuroraSessionToolbarController* auroraToolbar(NSWindow* window)
{
    return window ? objc_getAssociatedObject(window, &ControllerKey) : nil;
}

static void installSessionToolbar(NSWindow* native, AuroraSessionToolbarController* controller);

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
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightMedium]];
    _statusChevron.imageScaling = NSImageScaleProportionallyDown;
    _statusChevron.contentTintColor = rgb(0x526176);
    [_statusChevron setAccessibilityElement:NO];
    [_status addSubview:_statusChevron];
    _dot = [[[AuroraStatusDot alloc] initWithFrame:NSZeroRect] autorelease];
    [_status addSubview:_dot];
    _statusText = [NSTextField labelWithString:@""];
    [_statusText setAccessibilityElement:NO];
    _statusText.font = [NSFont systemFontOfSize:12];
    [_status addSubview:_statusText];

    _display = [[AuroraDisplayTab alloc] init];
    _display.hidden = YES;

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
    [notifications addObserver:self selector:@selector(dismissControlCenter:) name:NSWindowWillMoveNotification object:window];
    [notifications addObserver:self selector:@selector(windowResized:) name:NSWindowDidResizeNotification object:window];
    [notifications addObserver:self selector:@selector(positionDisplayTab:) name:NSWindowDidUpdateNotification object:window];
    [notifications addObserver:self selector:@selector(windowWillEnterFullscreen:) name:NSWindowWillEnterFullScreenNotification object:window];
    [notifications addObserver:self selector:@selector(windowDidEnterFullscreen:) name:NSWindowDidEnterFullScreenNotification object:window];
    [notifications addObserver:self selector:@selector(windowWillExitFullscreen:) name:NSWindowWillExitFullScreenNotification object:window];
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

- (void)prepareQtTitleBar
{
    if (_connectionWindow || _qtTitle || _qtTitleFailed || !auroraMacSessionChromeEnabled() ||
        qEnvironmentVariable("AURORA_QT_SESSION_TOOLBAR") == QStringLiteral("0")) return;

    auto title = std::make_unique<AuroraMacTitleBarView>(auroraMacSessionQml(QStringLiteral("MacConnectedTitleBar.qml")));
    if (!title->ready() || title->rootObject()->property("barHeight").toInt() != GroupHeight) {
        qWarning("Aurora could not load the Qt stream titlebar. Using the native toolbar.");
        _qtTitleFailed = YES;
        return;
    }

    auto* chrome = title->rootObject();
    chrome->setProperty("deviceName", QString::fromNSString(_device.stringValue));
    chrome->setProperty("networkPoor", _dot->poor == YES);
    chrome->setProperty("reduceMotion", NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion == YES);

    auto* view = reinterpret_cast<NSView*>(title->winId());
    if (!view) {
        _qtTitleFailed = YES;
        return;
    }

    _qtTitle = title.release();
    _qtTitleHost = [[AuroraQtTitleHost alloc] init];
    _qtTitleHost.quick = _qtTitle;
    _qtTitleHost.quickView = view;
    view.frame = _qtTitleHost.bounds;
    [_qtTitleHost addSubview:view];

    _qtTitle->onControls = [self](bool keyboard) {
        _qtTitleOwnsKeyboard = YES;
        [self openControlsFrom:_qtTitleHost.quickView keyboard:keyboard];
    };
    _qtTitle->onConnection = [self](const QRectF& anchor) {
        _qtTitleOwnsKeyboard = YES;
        sendAction(streamWindowId, AuroraToolbarAction::ReleaseMouse);
        NSView* view = _qtTitleHost.quickView;
        [self showDetailsFrom:_qtTitleHost
                      bounds:[view convertRect:cocoaAnchor(view, anchor) toView:_qtTitleHost]];
    };
    _qtTitle->onDisplayAction = [self](const QString& operation, const QString& id) {
        [self requestDisplay:operation id:id];
    };
    _qtTitle->onDisplays = [self](const QRectF& rect) { [self showDisplaysFrom:rect]; };
    _qtTitle->rootObject()->setProperty("displaySnapshot", _displayState);
    QObject::connect(_qtTitle, &QQuickWindow::frameSwapped, _qtTitle, [self] {
        _qtTitleHasFrame = YES;
    }, Qt::QueuedConnection);
    QObject::connect(_qtTitle, &QQuickWindow::sceneGraphError, _qtTitle, [self](QQuickWindow::SceneGraphError, const QString&) {
        _qtTitleFailed = YES;
    }, Qt::QueuedConnection);
}

- (NSWindowToolbarStyle)sessionToolbarStyle
{
    return _qtTitle ? NSWindowToolbarStyleUnified : NSWindowToolbarStyleUnifiedCompact;
}

- (void)hideQtTitleBar
{
    if (!_qtTitle) return;
    qtTitleVisible = false;
    _qtTitleProbe.invalidate();
    [self restoreVideoFocus];
    _qtTitle->hide();
}

- (void)destroyQtTitleBar
{
    if (!_qtTitle) return;
    qtTitleVisible = false;
    _qtTitleHost.quick = nullptr;
    [_qtTitleHost.quickView removeFromSuperview];
    _qtTitleHost.quickView = nil;
    delete _qtTitle;
    _qtTitle = nullptr;
    [_qtTitleHost release];
    _qtTitleHost = nil;
}

- (void)checkQtTitleBar
{
    if (!_qtTitle || !_window.toolbar.visible || [self fullscreenTransitioning] ||
        !_window.visible || !(_window.occlusionState & NSWindowOcclusionStateVisible)) {
        _qtTitleProbe.invalidate();
        return;
    }

    if (!_qtTitleProbe.isValid()) _qtTitleProbe.start();
    if (!_qtTitleFailed) {
        NSView* view = _qtTitleHost.quickView;
        const NSRect extent = [view convertRect:view.bounds toView:nil];
        NSView* video = _window.contentView;
        const NSRect videoRect = [video convertRect:video.bounds toView:nil];
        NSButton* zoom = [_window standardWindowButton:NSWindowZoomButton];
        const CGFloat leftBound = NSMaxX([zoom convertRect:zoom.bounds toView:nil]);
        const BOOL correctPlacement = view.window == _window && !view.hiddenOrHasHiddenAncestor &&
            NSWidth(extent) >= 240 && NSHeight(extent) >= GroupHeight &&
            NSMinX(extent) >= leftBound && NSMinY(extent) >= NSMaxY(videoRect) - 1 &&
            NSMaxX(extent) <= NSWidth(_window.frame) + 1;
        if (correctPlacement && _qtTitleHasFrame) {
            _qtTitleProbe.restart();
            return;
        }
        if (!_qtTitleProbe.hasExpired(1500)) return;
    }

    qWarning("Aurora's Qt stream titlebar could not present outside the video area. Using the native toolbar.");
    _qtTitleFailed = YES;
    [self closeControlCenter];
    [self closeConnectionDetails];
    [self hideQtTitleBar];
    [self destroyQtTitleBar];
    installSessionToolbar(_window, self);
}

- (BOOL)routeLocalKey:(const SDL_KeyboardEvent&)key captureActive:(BOOL)captureActive
{
    const auto code = static_cast<unsigned>(key.keysym.scancode);
    if (code >= SDL_NUM_SCANCODES) return NO;
    const bool stillLocal = _localKeys.test(code);
    if (key.type == SDL_KEYUP) _localKeys.reset(code);
    if (stillLocal) return YES;
    if (_appearanceEditor) {
        if (key.type == SDL_KEYDOWN) _localKeys.set(code);
        return YES;
    }
    if (!_qtTitle || !_qtTitle->isVisible()) return NO;

    // F6 gives keyboard access to the titlebar from an uncaptured viewer.
    if (key.type == SDL_KEYDOWN && key.keysym.sym == SDLK_F6 &&
        !(key.keysym.mod & (KMOD_CTRL | KMOD_ALT | KMOD_SHIFT | KMOD_GUI)) &&
        !captureActive && _window.keyWindow && [_window makeFirstResponder:_qtTitleHost.quickView]) {
        sendAction(streamWindowId, AuroraToolbarAction::ReleaseMouse);
        _qtTitleOwnsKeyboard = YES;
        _qtTitle->focusControls();
    }
    if (!_qtTitleOwnsKeyboard && _window.firstResponder != _qtTitleHost.quickView) return NO;
    _qtTitleOwnsKeyboard = YES;
    if (key.type == SDL_KEYDOWN) _localKeys.set(code);
    return YES;
}

- (BOOL)routePrivacyEditorMouseButton:(const SDL_MouseButtonEvent&)button
{
    const bool local = _appearanceMouseButtons.test(button.button);
    if (button.state == SDL_RELEASED) _appearanceMouseButtons.reset(button.button);
    else if (_appearanceEditor) _appearanceMouseButtons.set(button.button);
    return local || _appearanceEditor != nullptr;
}

- (void)restoreVideoFocus
{
    if (!_qtTitle || (!_qtTitleOwnsKeyboard && _window.firstResponder != _qtTitleHost.quickView)) return;
    _qtTitleOwnsKeyboard = NO;
    _qtTitle->clearKeyboardFocus();
    if (_window.firstResponder == _qtTitleHost.quickView) [_window makeFirstResponder:_window.contentView];
}

- (void)resizeItems
{
    if (_qtTitle) {
        // Reserve AppKit's leading window controls and item margins. The actual
        // slot is measured again after it has been laid out by NSToolbar.
        NSButton* zoom = [_window standardWindowButton:NSWindowZoomButton];
        const CGFloat trafficRight = NSMaxX([zoom convertRect:zoom.bounds toView:nil]);
        const CGFloat width = std::max<CGFloat>(240, std::floor(NSWidth(_window.frame) - trafficRight - 32));
        _qtTitle->rootObject()->setProperty("layoutWidth", qRound(NSWidth(_window.frame)));
        [_qtTitleHost resizeToWidth:width];
        _qtTitle->resize(qRound(width), GroupHeight);
        return;
    }
    NSButton* zoom = [_window standardWindowButton:NSWindowZoomButton];
    const auto trafficEdge = zoom ? NSMaxX([zoom convertRect:zoom.bounds toView:nil]) : 0;
    const auto layout = auroraSessionToolbarLayout(
        static_cast<int>(NSWidth(_window.frame)), static_cast<int>(std::ceil(trafficEdge)),
        {static_cast<int>(captionWidth(_device)),
         static_cast<int>(captionWidth(_statusText)) + 32,
         static_cast<int>(std::ceil([_display preferredWidth])),
         static_cast<int>(std::ceil([_controls preferredWidth])),
         static_cast<int>(std::ceil([_disconnect preferredWidth]))}, _brand != nil,
        _connectionWindow && !_disconnect.hidden);
    [_context resizeToWidth:layout.contextWidth()];
    [_actions resizeToWidth:layout.actionsWidth()];

    const CGFloat middle = GroupHeight / 2;
    const CGFloat deviceHeight = std::ceil(_device.intrinsicContentSize.height);
    _device.frame = NSMakeRect(0, std::floor(middle - deviceHeight / 2), layout.device, deviceHeight);
    _status.frame = NSMakeRect(layout.device + 8, middle - 14, layout.status, 28);
    const BOOL compactStatus = layout.status == 25;
    const BOOL arrow = !_connectionWindow && !compactStatus;
    _statusText.hidden = compactStatus;
    _statusChevron.hidden = !arrow;
    const CGFloat dot = _dot->connecting ? 9 : 6;
    const CGFloat leading = compactStatus && !arrow ? (layout.status - dot) / 2 : 4;
    _dot.frame = NSMakeRect(leading, 14 - dot / 2, dot, dot);
    const CGFloat textX = NSMaxX(_dot.frame) + 6;
    const CGFloat textHeight = std::ceil(_statusText.intrinsicContentSize.height);
    const CGFloat textWidth = std::min(captionWidth(_statusText),
        std::max<CGFloat>(0, layout.status - textX - (arrow ? 19 : 0)));
    _statusText.frame = NSMakeRect(textX, std::floor(14 - textHeight / 2), textWidth, textHeight);
    _statusChevron.frame = NSMakeRect(NSMaxX(_statusText.frame) + 5, 7, 14, 14);

    [_display showLabel:layout.display > 32];
    _displaySlot = NSMakeRect(NSMaxX(_status.frame) + 6, 0,
                              layout.display + 2 * AuroraSessionToolbarLayout::DisplayFoot, DisplayTabHeight);
    [self positionDisplayTab:nil];

    [_controls showLabel:layout.controls > 32];
    [_disconnect showLabel:layout.disconnect > 32];
    _disconnect.hidden = layout.disconnect == 0;
    _disconnect.frame = NSMakeRect(0, middle - ButtonHeight / 2, layout.disconnect, ButtonHeight);
    const CGFloat controlsX = layout.disconnect ? layout.disconnect + 4 : 0;
    _controls.frame = NSMakeRect(controlsX, middle - ButtonHeight / 2, layout.controls, ButtonHeight);
    _brand.hidden = !layout.brand;
    _brand.frame = NSMakeRect(NSMaxX(_controls.frame) + 8, middle - BrandSize / 2,
                              BrandSize, BrandSize);
}

- (void)positionDisplayTab:(NSNotification*)notification
{
    if (_qtTitle || [self fullscreenTransitioning] || _nativeFullscreen ||
        (_window.styleMask & NSWindowStyleMaskFullScreen) || !_window.toolbar.visible ||
        _context.window != _window || _context.hiddenOrHasHiddenAncestor ||
        !NSContainsRect(_context.visibleRect, _displaySlot)) {
        if (!_display.hidden) _display.hidden = YES;
        return;
    }

    // NSToolbar vertically centers item views. Anchor the painted tab to the video boundary
    // in window coordinates so the native toolbar's padding cannot leave a seam under its feet.
    NSView* frameView = _window.contentView;
    if (!frameView) return;
    while (frameView.superview) frameView = frameView.superview;
    NSRect tab = [_context convertRect:_displaySlot toView:nil];
    tab.origin.y = NSMaxY(_window.contentLayoutRect);
    const NSRect frame = [frameView convertRect:frameView.bounds toView:nil];
    tab.size.height = std::min(DisplayTabHeight, NSMaxY(frame) - tab.origin.y - DisplayTabTopInset);
    if (NSHeight(tab) < 22) {
        _display.hidden = YES;
        return;
    }
    tab = [frameView convertRect:tab fromView:nil];
    if (_display.superview != frameView) {
        [_display removeFromSuperviewWithoutNeedingDisplay];
        [frameView addSubview:_display positioned:NSWindowAbove relativeTo:nil];
    }
    if (!NSEqualRects(_display.frame, tab)) _display.frame = tab;
    if (_display.hidden) _display.hidden = NO;
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
    if (![self fullscreenTransitioning] && !_nativeFullscreen && !(_window.styleMask & NSWindowStyleMaskFullScreen)) {
        if (!_window.toolbar.visible) _window.toolbar.visible = YES;
        [self resizeItems];
        if (_qtTitle && !_qtTitle->isVisible()) {
            _qtTitleHasFrame = NO;
            _qtTitle->show();
            qtTitleVisible = true;
        }
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
    if ([self fullscreenTransitioning]) return;
    if (_floatingPanel.parentWindow == _window) [self positionFullscreenControls];
    if (_appearanceEditor) [self positionControlCenter];
    else if (_controlCenter.visible) [self closeControlCenter];
    if (!_nativeFullscreen && !(_window.styleMask & NSWindowStyleMaskFullScreen)) {
        [self resizeItems];
    }
}

- (void)setVideoWidth:(int)width height:(int)height fullscreen:(BOOL)fullscreen
{
    _videoAspect = width > 0 && height > 0 ? NSMakeSize(static_cast<CGFloat>(width) / height, 1) : NSZeroSize;
    const NSSize aspect = fullscreen || _nativeFullscreen ? NSZeroSize : _videoAspect;
    // Constrain the video content, leaving titlebar sizing and drag behavior to AppKit.
    if (![self fullscreenTransitioning] && !NSEqualSizes(_window.contentAspectRatio, aspect))
        _window.contentAspectRatio = aspect;
}

- (BOOL)fullscreenTransitioning
{
    return _nativeFullscreenTransition || _sdlFullscreenRequest;
}

- (void)detachFullscreenChrome
{
    [self closeControlCenter];
    [self closeConnectionDetails];
    [self showFullscreenControls:NO];
    [self hideQtTitleBar];
    _display.hidden = YES;
}

- (void)beginFullscreenRequest
{
    _sdlFullscreenRequest = YES;
    [self detachFullscreenChrome];
    if (!NSEqualSizes(_window.contentAspectRatio, NSZeroSize))
        _window.contentAspectRatio = NSZeroSize;
}

- (void)finishFullscreenRequest:(BOOL)accepted
{
    _sdlFullscreenRequest = NO;
    if (!accepted) _nativeFullscreenTransition = NO;
    sendAction(streamWindowId, AuroraToolbarAction::SyncFullscreenChrome);
}

- (void)windowWillEnterFullscreen:(NSNotification*)notification
{
    _nativeFullscreenTransition = YES;
    [self detachFullscreenChrome];
}

- (void)windowDidEnterFullscreen:(NSNotification*)notification
{
    _nativeFullscreenTransition = NO;
    sendAction(streamWindowId, AuroraToolbarAction::SyncFullscreenChrome);
}

- (void)windowWillExitFullscreen:(NSNotification*)notification
{
    _nativeFullscreenTransition = YES;
    [self detachFullscreenChrome];
}

- (void)windowDidExitFullscreen:(NSNotification*)notification
{
    _nativeFullscreenTransition = NO;
    sendAction(streamWindowId, AuroraToolbarAction::SyncFullscreenChrome);
}

- (void)syncFullscreenChrome
{
    // SDL may dispatch Cocoa notifications inside its fullscreen call.
    // Apply layout on the session loop once both transitions have returned.
    if ([self fullscreenTransitioning]) return;
    auto* sdl = SDL_GetWindowFromID(streamWindowId);
    if (!sdl) return;
    _nativeFullscreen = (_window.styleMask & NSWindowStyleMaskFullScreen) ||
                        (SDL_GetWindowFlags(sdl) & SDL_WINDOW_FULLSCREEN);
    const NSSize aspect = _nativeFullscreen ? NSZeroSize : _videoAspect;
    if (!NSEqualSizes(_window.contentAspectRatio, aspect)) _window.contentAspectRatio = aspect;
    if (_nativeFullscreen) {
        [self hideQtTitleBar];
        if (_window.toolbar.visible) _window.toolbar.visible = NO;
        [self showFullscreenControls:YES];
    } else {
        [self showFullscreenControls:NO];
        [self showIfWindowed];
    }
}

- (NSArray<NSToolbarItemIdentifier>*)toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar
{
    return _qtTitle ? @[QtTitleItem] : @[ContextItem, NSToolbarFlexibleSpaceItemIdentifier, ActionsItem];
}

- (NSArray<NSToolbarItemIdentifier>*)toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar
{
    return [self toolbarAllowedItemIdentifiers:toolbar];
}

- (NSToolbarItem*)toolbar:(NSToolbar*)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier
          willBeInsertedIntoToolbar:(BOOL)willInsert
{
    if (_qtTitle && [identifier isEqualToString:QtTitleItem]) {
        auto* item = [[[NSToolbarItem alloc] initWithItemIdentifier:identifier] autorelease];
        item.label = @"串流";
        item.view = _qtTitleHost;
        item.autovalidates = NO;
        item.visibilityPriority = NSToolbarItemVisibilityPriorityHigh;
        return item;
    }
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
    if (_qtTitle) _qtTitle->rootObject()->setProperty("networkPoor", poor == YES);
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
    const BOOL warning = action == @selector(runControlAction:) &&
                         tag == static_cast<NSInteger>(AuroraToolbarAction::Disconnect);
    auto* button = [[[AuroraToolbarButton alloc] initWithLabel:title symbol:symbol
        target:self action:action warning:warning] autorelease];
    button.tag = tag;
    button.frame = NSMakeRect(0, y, 274, 34);
    [button useMenuLayout:next];
    return button;
}

- (BOOL)renderQtControlHome
{
    if (_controlPage != 0 || [self fullscreenTransitioning] || !auroraMacSessionChromeEnabled()) return NO;
    if (!_qtControls) {
        _qtControls = new AuroraMacControlsView(auroraMacSessionQml(QStringLiteral("MacStreamControls.qml")));
        if (_qtControls->status() != QQuickView::Ready) {
            delete _qtControls;
            _qtControls = nullptr;
            qWarning("Aurora Qt controls could not be loaded. Using the native menu.");
            return NO;
        }
        _qtControls->onOpenPage = [self](int page) { [self showControlPage:page]; };
        _qtControls->onToggleFullscreen = [self] { [self dispatchControlAction:AuroraToolbarAction::ToggleFullscreen]; };
        _qtControls->onDisconnect = [self] { [self dispatchControlAction:AuroraToolbarAction::Disconnect]; };
        _qtControls->onShowConnectionDetails = [self] { [self showFullscreenDetails:_controlAnchor]; };
    }

    auto* root = _controlCenter.contentView;
    CGFloat available = NSHeight(_window.contentView.bounds) - 32;
    if (_window.screen) available = std::min(available, NSHeight(_window.screen.visibleFrame) - 100);
    auto* menu = _qtControls->rootObject();
    menu->setProperty("fullScreen", _showFloatingControls == YES);
    menu->setProperty("heightLimit", qRound(std::max(CGFloat(124), available)));
    QMetaObject::invokeMethod(menu, "layoutNativeHome");
    const NSSize size = NSMakeSize(menu->width(), menu->height());
    if (size.width <= 0 || size.height <= 0) return NO;

    _qtControls->resize(qRound(size.width), qRound(size.height));
    auto* view = reinterpret_cast<NSView*>(_qtControls->winId());
    if (!view) return NO;
    [_controlCenter setContentSize:size];
    view.frame = root.bounds;
    [root addSubview:view];
    _qtControls->show();
    _controlCenter.initialFirstResponder = view;
    qtControlsVisible = true;
    if (_controlCenter.visible) {
        [self positionControlCenter];
        [_controlCenter makeFirstResponder:view];
    }
    _qtControls->focusInitial(_controlCenter.keyboardNavigation);
    return YES;
}

- (void)renderControlCenter
{
    if (!_controlCenter || _appearanceEditor) return;
    constexpr CGFloat width = 288;
    NSView* root = _controlCenter.contentView;
    _bitrateLabel = nil;
    _bitrateFeedback = nil;
    _bitrateSlider = nil;
    [_controlCenter makeFirstResponder:nil];
    _controlCenter.initialFirstResponder = nil;
    if (_qtControls && _qtControls->isVisible()) {
        qtControlsVisible = false;
        _qtControls->hide();
    }
    root.subviews = @[];
    if ([self renderQtControlHome]) return;
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
        constexpr CGFloat gap = 4;
        NSFont* font = [NSFont systemFontOfSize:12];
        std::vector<CGFloat> widths;
        CGFloat total = 0;
        for (NSString* text in labels) {
            const CGFloat width = std::ceil([text sizeWithAttributes:@{NSFontAttributeName:font}].width) + 10;
            widths.push_back(width);
            total += width;
        }
        const CGFloat available = NSWidth(group.bounds) - gap * (labels.count - 1);
        const CGFloat scale = std::min<CGFloat>(1, available / total);
        const CGFloat extra = std::max<CGFloat>(0, (available - total) / labels.count);
        CGFloat x = 0;
        for (NSUInteger index = 0; index < labels.count; index++) {
            const CGFloat buttonWidth = index + 1 == labels.count ? NSWidth(group.bounds) - x :
                std::floor(widths[index] * scale + extra);
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
        button.focusRingType = NSFocusRingTypeNone;
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
        if (_showFloatingControls)
            row(@"连接详情", @"info.circle", @selector(showFullscreenDetails:), 0);
        row(_showFloatingControls ? @"退出全屏" : @"全屏", @"arrow.up.left.and.arrow.down.right",
            @selector(runControlAction:), static_cast<NSInteger>(AuroraToolbarAction::ToggleFullscreen));
        row(@"断开远控", @"rectangle.portrait.and.arrow.right", @selector(runControlAction:),
            static_cast<NSInteger>(AuroraToolbarAction::Disconnect));
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
            rate.focusRingType = NSFocusRingTypeNone;
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
            modes.focusRingType = NSFocusRingTypeNone;
            modes.selectedSegment = selected;
            modes.enabled = !busy && selected >= 0;
            [modes setAccessibilityLabel:@"隐私保护"];
            [body addSubview:modes];
            y += 32;

            if (busy) label(@"正在确认隐私保护…", YES);
            else if (!hasTarget || state == AuroraPrivacyState::Unsupported) label(@"当前会话不支持隐私保护", YES);
            else if (privacy->changeRejected) label(@"主机未切换到所选状态", YES);
            else if (selected < 0) {
                label(@"无法确认隐私保护", YES);
                row(@"重新检查", @"shield", @selector(refreshPrivacy:), 0);
            }
            if (auroraMacSessionChromeEnabled()) {
                auto* appearance = [self controlRow:@"设置隐私屏保" symbol:@"photo" y:y
                    action:@selector(openPrivacyAppearance:) tag:0 next:YES];
                appearance.identifier = @"auroraPrivacyAppearance";
                appearance.enabled = hasTarget && !busy && state != AuroraPrivacyState::Unsupported;
                [body addSubview:appearance];
                y += 34;
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
    [_controlCenter recalculateKeyViewLoop];
    _controlCenter.initialFirstResponder = _controlCenter.keyboardNavigation ? body.subviews.firstObject : nil;
    if (_controlCenter.visible) {
        [self positionControlCenter];
        [_controlCenter makeFirstResponder:_controlCenter.initialFirstResponder];
    }
}

- (void)openControlPage:(NSButton*)button
{
    [self showControlPage:button.tag];
}

- (void)showControlPage:(NSInteger)page
{
    _controlPage = page;
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
    [self dispatchControlAction:static_cast<AuroraToolbarAction>(button.tag)];
}

- (void)dispatchControlAction:(AuroraToolbarAction)action
{
    [self closeControlCenter];
    sendAction(streamWindowId, action);
}

- (void)showFullscreenDetails:(id)sender
{
    [self closeControlCenter];
    [self showConnectionDetails:sender];
}

- (NSRect)controlAnchorBounds
{
    if (_qtTitle && _controlAnchor == _qtTitleHost.quickView)
        return cocoaAnchor(_controlAnchor, _qtTitle->controlsRect());
    return _controlAnchor.bounds;
}

- (void)positionControlCenter
{
    if (_appearanceEditor) {
        NSView* content = _window.contentView;
        const NSRect playback = [_window convertRectToScreen:[content convertRect:content.bounds toView:nil]];
        NSScreen* screen = _window.screen ?: NSScreen.mainScreen;
        const NSRect usable = NSIntersectionRect(playback, _nativeFullscreen ? screen.frame : screen.visibleFrame);
        const CGFloat width = std::clamp(NSWidth(usable) - 24, CGFloat(1), CGFloat(686));
        const CGFloat height = std::clamp(NSHeight(usable) - 24, CGFloat(1), CGFloat(520));
        [_controlCenter setContentSize:NSMakeSize(width, height)];
        [_controlCenter setFrameOrigin:NSMakePoint(NSMidX(usable) - width / 2, NSMidY(usable) - height / 2)];
        _appearanceEditor->resize(qRound(width), qRound(height));
        return;
    }
    if (!_controlAnchor.window) return;
    const NSRect windowFrame = _window.frame;
    const NSRect button = [_controlAnchor.window convertRectToScreen:[_controlAnchor convertRect:[self controlAnchorBounds] toView:nil]];
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
    [self endPrivacyAppearance];
    if (_controlMonitor) [NSEvent removeMonitor:_controlMonitor];
    _controlMonitor = nil;
    if (_controlCenter.parentWindow == _window) [_window removeChildWindow:_controlCenter];
    _controlCenter.keyboardNavigation = NO;
    [_controlCenter makeFirstResponder:nil];
    if (_qtControls && _qtControls->isVisible()) {
        qtControlsVisible = false;
        _qtControls->hide();
    }
    [_controlCenter orderOut:nil];
    if (_qtTitle && _controlAnchor == _qtTitleHost.quickView) {
        _qtTitle->setSelectedPanel({});
    } else {
        [(AuroraToolbarButton*)_controlAnchor markMenuOpen:NO];
    }
    _controlAnchor = nil;
}

- (void)dismissControlCenter:(NSNotification*)notification
{
    [self closeControlCenter];
}

- (void)showControls:(AuroraToolbarButton*)sender
{
    [self openControlsFrom:sender keyboard:isKeyboardInput(NSApp.currentEvent)];
}

- (void)openControlsFrom:(NSView*)source keyboard:(BOOL)keyboard
{
    if (!source.window || [self fullscreenTransitioning]) return;
    if (_controlCenter.visible) {
        [self closeControlCenter];
        return;
    }
    [self closeConnectionDetails];
    sendAction(streamWindowId, AuroraToolbarAction::ReleaseMouse);
    _controlAnchor = source;
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
    _controlCenter.keyboardNavigation = keyboard;
    [self renderControlCenter];
    [self positionControlCenter];
    if (_qtTitle && source == _qtTitleHost.quickView) {
        _qtTitle->setSelectedPanel(QStringLiteral("controls"));
    } else {
        [(AuroraToolbarButton*)source markMenuOpen:YES];
    }
    [_window addChildWindow:_controlCenter ordered:NSWindowAbove];
    [_controlCenter makeKeyAndOrderFront:nil];
    [_controlCenter makeFirstResponder:_controlCenter.initialFirstResponder];

    __block AuroraSessionToolbarController* controller = self;
    _controlMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:
        NSEventMaskKeyDown | NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown handler:^NSEvent*(NSEvent* event) {
        if (controller->_appearanceEditor) {
            if (event.window == controller->_window || event.window == controller->_floatingPanel) return nil;
            return event;
        }
        if (event.type != NSEventTypeKeyDown) {
            if (event.window == controller->_controlCenter) return event;
            NSView* trigger = controller->_controlAnchor;
            if (event.window == trigger.window &&
                NSPointInRect([trigger convertPoint:event.locationInWindow fromView:nil],
                              [controller controlAnchorBounds])) return event;
            [controller closeControlCenter];
            return event;
        }
        if (event.keyCode != 53 || event.window != controller->_controlCenter) return event;
        if (controller->_controlPage == 0) {
            auto* anchorButton = controller->_controlAnchor;
            [controller closeControlCenter];
            [controller->_window makeKeyWindow];
            if ([anchorButton.window makeFirstResponder:anchorButton]) {
                if (controller->_qtTitle && anchorButton == controller->_qtTitleHost.quickView)
                    controller->_qtTitle->focusControls();
                else
                    [(AuroraToolbarButton*)anchorButton showKeyboardFocus:YES];
            }
        } else {
            controller->_controlCenter.keyboardNavigation = YES;
            controller->_controlPage = 0;
            [controller renderControlCenter];
        }
        return nil;
    }];
}

- (void)openPrivacyAppearance:(id)sender
{
    if (_appearanceEditor || !_controlCenter.visible || [self fullscreenTransitioning] ||
        !privacy || !privacy->live || privacy->target.program.isEmpty()) return;

    auto editor = std::make_unique<AuroraMacPrivacyAppearanceView>(
        auroraMacSessionQml(QStringLiteral("MacPrivacyScreensaverEditor.qml")));
    if (editor->status() != QQuickView::Ready || !editor->rootObject()) {
        qWarning("Aurora could not load the privacy screensaver editor.");
        return;
    }
    NSView* view = reinterpret_cast<NSView*>(editor->winId());
    if (!view) return;

    _appearanceEdit = std::make_shared<AppearanceEdit>();
    _appearanceEditor = editor.release();
    _appearanceEditor->onClose = [self] {
        [self endPrivacyAppearance];
        [self renderControlCenter];
    };
    _appearanceEditor->onImport = [self](int request) { [self pickPrivacyAppearance:request]; };
    _appearanceEditor->onSave = [self](int request, const QVariantMap& style) {
        [self submitPrivacyAppearance:request style:style];
    };

    sendAction(streamWindowId, AuroraToolbarAction::ReleaseMouse);
    NSView* root = _controlCenter.contentView;
    [_controlCenter makeFirstResponder:nil];
    _controlCenter.initialFirstResponder = nil;
    if (_qtControls) _qtControls->hide();
    qtControlsVisible = false;
    root.subviews = @[];
    root.layer.cornerRadius = 13;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:view];
    [self positionControlCenter];
    view.frame = root.bounds;
    _appearanceEditor->show();
    qtAppearanceVisible = true;
    [_controlCenter makeFirstResponder:view];

    const bool storage = _appearanceEdit->files.isValid();
    _appearanceEditor->capability(false, storage ? QStringLiteral("读取被控设备的已保存样式…")
                                                : QStringLiteral("无法创建本地屏保预览。"));
    _appearanceEditor->begin(QString::fromNSString(_device.stringValue), AuroraMacPrivacyAppearanceView::defaultStyle());
    if (storage) [self runPrivacyAppearance:AuroraPrivacyAppearanceAction::Read request:0 file:QString()];
}

- (void)endPrivacyAppearance
{
    if (!_appearanceEditor) return;
    const auto edit = std::move(_appearanceEdit);
    edit->live = false;
    qtAppearanceVisible = false;
    if (_appearancePicker) {
        NSOpenPanel* picker = _appearancePicker;
        _appearancePicker = nil;
        [picker cancel:nil];
        [picker orderOut:nil];
        [picker release];
    }
    auto* editor = _appearanceEditor;
    _appearanceEditor = nullptr;
    [_controlCenter makeFirstResponder:nil];
    QObject::disconnect(editor->rootObject(), nullptr, editor, nullptr);
    editor->end();
    editor->hide();
    auto* view = reinterpret_cast<NSView*>(editor->winId());
    [view removeFromSuperview];
    editor->deleteLater();
    _controlCenter.contentView.layer.cornerRadius = 9;
}

- (void)pickPrivacyAppearance:(int)request
{
    if (!_appearanceEditor || _appearancePicker) return;
    _appearancePicker = [[NSOpenPanel openPanel] retain];
    _appearancePicker.canChooseDirectories = NO;
    _appearancePicker.canChooseFiles = YES;
    _appearancePicker.allowsMultipleSelection = NO;
    _appearancePicker.allowedFileTypes = @[@"jpg", @"jpeg", @"png", @"webp"];

    const auto edit = _appearanceEdit;
    const std::weak_ptr<AuroraSessionPrivacy> identity(privacy);
    const auto windowId = streamWindowId;
    [_appearancePicker beginSheetModalForWindow:_controlCenter completionHandler:^(NSModalResponse response) {
        if (!edit->live) return;
        const auto session = identity.lock();
        auto* toolbar = auroraToolbar(nativeWindow(SDL_GetWindowFromID(windowId)));
        if (!session || !session->live || !toolbar || toolbar->privacy != session ||
            toolbar->_appearanceEdit != edit) return;

        auto* picker = toolbar->_appearancePicker;
        toolbar->_appearancePicker = nil;
        NSURL* selected = response == NSModalResponseOK ? picker.URL : nil;
        const bool local = selected.isFileURL;
        const auto input = local ? QString::fromNSString(selected.path) : QString();
        const auto name = local ? QString::fromNSString(selected.lastPathComponent) : QString();
        [picker release];
        if (input.isEmpty()) {
            toolbar->_appearanceEditor->finishImport(request, response == NSModalResponseOK
                ? QStringLiteral("无法读取所选图片，请重新选择。") : QString());
            return;
        }

        const auto id = QStringLiteral("mac-import-%1").arg(request);
        const auto file = edit->files.filePath(id + QStringLiteral(".png"));
        QThreadPool::globalInstance()->start([edit, identity, windowId, request, input, name, id, file] {
            const auto session = identity.lock();
            if (!session || !session->live || !edit->live) return;
            const QFileInfo source(input);
            const auto png = source.isFile() ? AuroraPrivacyArtwork::prepare(input) : QByteArray();
            const bool prepared = edit->live && writeAppearanceImage(file, png);
            const auto mainLoop = CFRunLoopGetMain();
            CFRunLoopPerformBlock(mainLoop, kCFRunLoopCommonModes, ^{
                const auto current = identity.lock();
                if (!current || !current->live || !edit->live) return;
                auto* owner = auroraToolbar(nativeWindow(SDL_GetWindowFromID(windowId)));
                if (!owner || owner->privacy != current || owner->_appearanceEdit != edit) return;
                if (prepared) {
                    owner->_appearanceEditor->imported(request, AuroraMacPrivacyAppearanceView::customStyle(id, name, file));
                } else {
                    owner->_appearanceEditor->finishImport(request, QStringLiteral("无法预览这张图片，请重新选择。"));
                }
            });
            CFRunLoopWakeUp(mainLoop);
        });
    }];
}

- (void)submitPrivacyAppearance:(int)request style:(const QVariantMap&)style
{
    if (!_appearanceEditor || !privacy || !privacy->live) return;
    const auto kind = style.value(QStringLiteral("kind")).toString();
    const auto id = style.value(QStringLiteral("id")).toString();
    if (kind == QStringLiteral("default") && id == QStringLiteral("default")) {
        [self runPrivacyAppearance:AuroraPrivacyAppearanceAction::Reset request:request file:QString()];
        return;
    }
    QString file;
    if (kind == QStringLiteral("preset")) {
        file = _appearanceEditor->presetFile(id);
    } else if (kind == QStringLiteral("custom")) {
        static const QRegularExpression imported(QStringLiteral(R"(\Amac-import-[1-9][0-9]{0,9}\z)"));
        if (imported.match(id).hasMatch()) {
            const auto candidate = _appearanceEdit->files.filePath(id + QStringLiteral(".png"));
            if (style.value(QStringLiteral("previewUrl")).toUrl() == QUrl::fromLocalFile(candidate))
                file = candidate;
        }
    }
    if (file.isEmpty() || !QFileInfo(file).isFile()) {
        _appearanceEditor->finishSave(request, QStringLiteral("failed"), QStringLiteral("找不到所选图片，请重新选择。"));
        return;
    }
    [self runPrivacyAppearance:AuroraPrivacyAppearanceAction::Save request:request file:file];
}

- (void)runPrivacyAppearance:(AuroraPrivacyAppearanceAction)action request:(int)request file:(const QString&)file
{
    const auto edit = _appearanceEdit;
    const std::weak_ptr<AuroraSessionPrivacy> identity(privacy);
    const auto windowId = streamWindowId;
    const auto preview = edit->files.filePath(QStringLiteral("confirmed.png"));
    QThreadPool::globalInstance()->start([edit, identity, windowId, action, request, file, preview] {
        using State = AuroraPrivacyAppearanceState;
        const auto session = identity.lock();
        if (!session || !session->live || !edit->live) return;
        auto reply = runAuroraPrivacyAppearance(session->target, action, file, session->live, edit->live);
        if (!session->live || !edit->live) return;
        auto saved = AuroraMacPrivacyAppearanceView::defaultStyle();
        if (reply.state == State::Image) {
            if (writeAppearanceImage(preview, reply.png)) {
                const auto digest = QCryptographicHash::hash(reply.png, QCryptographicHash::Sha256).toHex();
                saved = AuroraMacPrivacyAppearanceView::customStyle(QStringLiteral("remote-") + QString::fromLatin1(digest),
                    QStringLiteral("已保存样式"), preview);
            } else {
                reply.state = State::Failed;
            }
        }
        const auto state = reply.state;
        const auto mainLoop = CFRunLoopGetMain();
        CFRunLoopPerformBlock(mainLoop, kCFRunLoopCommonModes, ^{
            const auto current = identity.lock();
            if (!current || !current->live || !edit->live) return;
            auto* owner = auroraToolbar(nativeWindow(SDL_GetWindowFromID(windowId)));
            if (!owner || owner->privacy != current || owner->_appearanceEdit != edit) return;
            auto* editor = owner->_appearanceEditor;
            const auto unsupported = QStringLiteral("被控端暂不支持自定义屏保。");
            if (action == AuroraPrivacyAppearanceAction::Read) {
                if (state == State::Default || state == State::Image) {
                    editor->begin(QString::fromNSString(owner->_device.stringValue), saved);
                    editor->capability(true, QString());
                } else {
                    editor->capability(false, state == State::Unsupported ? unsupported
                        : QStringLiteral("当前无法读取被控设备的屏保设置。"));
                }
            } else if (state == State::Saved) {
                editor->finishSave(request, QStringLiteral("saved"), QString());
            } else if (state == State::Unconfirmed) {
                editor->finishSave(request, QStringLiteral("unconfirmed"),
                    QStringLiteral("保存结果待确认。重新打开设置可核对设备上的样式。"));
            } else {
                editor->finishSave(request, QStringLiteral("failed"), state == State::Unsupported
                    ? unsupported : QStringLiteral("无法保存屏保样式，请重试。"));
                if (state == State::Unsupported) editor->capability(false, unsupported);
            }
        });
        CFRunLoopWakeUp(mainLoop);
    });
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
    NSView* anchor = sender == _status ? _status : _floatingPanel.contentView;
    [self showDetailsFrom:anchor bounds:anchor.bounds];
}

- (void)showDetailsFrom:(NSView*)anchor bounds:(NSRect)bounds
{
    [self closeControlCenter];
    if (_connectionDetails.shown) {
        [self closeConnectionDetails];
        return;
    }

    if (!anchor.window || NSIsEmptyRect(bounds)) return;
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
    [_connectionDetails showRelativeToRect:bounds ofView:anchor
                              preferredEdge:NSRectEdgeMinY];
    if (_connectionDetails.shown) {
        if (_qtTitle && anchor == _qtTitleHost)
            _qtTitle->setSelectedPanel(QStringLiteral("connection"));
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
    if (_qtTitle && _qtTitle->rootObject()->property("panelKind").toString() == QStringLiteral("connection"))
        _qtTitle->setSelectedPanel({});
    [_connectionRefresh invalidate];
    [_connectionRefresh release];
    _connectionRefresh = nil;
}

- (void)showDisplaysFrom:(const QRectF&)rect
{
    if (!_qtTitle || !_qtTitleHost.quickView || _displayState.isEmpty()) return;
    [self closeControlCenter];
    [self closeConnectionDetails];
    sendAction(streamWindowId, AuroraToolbarAction::ReleaseMouse);

    NSMenu* menu = [[[NSMenu alloc] initWithTitle:@"显示器"] autorelease];
    menu.autoenablesItems = NO;
    const bool busy = privacy && privacy->displayBusy;
    for (const auto& value : _displayState.value(QStringLiteral("displays")).toList()) {
        const auto item = value.toMap();
        const auto id = item.value(QStringLiteral("id")).toString();
        NSMenuItem* entry = [menu addItemWithTitle:item.value(QStringLiteral("name")).toString().toNSString()
            action:@selector(selectDisplayFromMenu:) keyEquivalent:@""];
        entry.target = self;
        entry.representedObject = id.toNSString();
        const bool selected = _displayState.value(QStringLiteral("activeDisplayId")).toString() == id;
        entry.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
        entry.enabled = !selected && !busy && _displayState.value(QStringLiteral("canSelect")).toBool() &&
            item.value(QStringLiteral("ready")).toBool();
        if (item.value(QStringLiteral("removable")).toBool()) {
            NSMenuItem* remove = [menu addItemWithTitle:[NSString stringWithFormat:@"关闭 %@", entry.title]
                action:@selector(removeDisplayFromMenu:) keyEquivalent:@""];
            remove.target = self;
            remove.representedObject = id.toNSString();
            remove.enabled = !busy;
            remove.indentationLevel = 1;
        }
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem* create = [menu addItemWithTitle:@"新增虚拟显示器" action:@selector(createDisplayFromMenu:) keyEquivalent:@""];
    create.target = self;
    create.enabled = !busy && _displayState.value(QStringLiteral("canCreate")).toBool();
    NSView* view = _qtTitleHost.quickView;
    const auto anchor = cocoaAnchor(view, rect);
    const auto edge = view.isFlipped ? NSMaxY(anchor) : NSMinY(anchor);
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSMinX(anchor), edge) inView:view];
}

- (void)selectDisplayFromMenu:(NSMenuItem*)sender
{
    [self requestDisplay:QStringLiteral("select") id:QString::fromNSString(sender.representedObject)];
}

- (void)removeDisplayFromMenu:(NSMenuItem*)sender
{
    [self requestDisplay:QStringLiteral("remove") id:QString::fromNSString(sender.representedObject)];
}

- (void)createDisplayFromMenu:(NSMenuItem*)sender
{
    (void)sender;
    [self requestDisplay:QStringLiteral("create") id:QString()];
}

- (void)checkDisplays
{
    if (!_qtTitle || !_qtTitle->isVisible() || !_displayState.isEmpty() ||
        _displayUnsupported || _displayProbePending || _displayProbeCount >= 4) return;
    if (_lastDisplayProbe.isValid() && !_lastDisplayProbe.hasExpired(900)) return;
    [self requestDisplay:QStringLiteral("list") id:QString()];
}

- (void)requestDisplay:(const QString&)operation id:(const QString&)id
{
    if (!privacy || !privacy->live || privacy->target.program.isEmpty() || privacy->displayBusy || !_qtTitle) return;
    if (operation == QLatin1String("select") && !_displayState.value(QStringLiteral("canSelect")).toBool()) return;
    const bool reading = operation == QLatin1String("list");
    if (!reading && (privacy->busy || (privacy->state != AuroraPrivacyState::Off &&
                                      privacy->state != AuroraPrivacyState::Unsupported))) {
        _qtTitle->rootObject()->setProperty("displayActionError", QStringLiteral("暂时无法更改显示器，请确认隐私保护已关闭。"));
        [self requestPrivacy:AuroraPrivacyOperation::Status];
        return;
    }

    if (reading) {
        if (_displayProbePending) return;
        _displayProbePending = YES;
        _lastDisplayProbe.start();
        ++_displayProbeCount;
    }
    privacy->displayBusy = !reading;
    _qtTitle->rootObject()->setProperty("displayRequestBusy", !reading);
    _qtTitle->rootObject()->setProperty("creatingDisplay", operation == QLatin1String("create"));
    _qtTitle->rootObject()->setProperty("displayActionError", QString());
    const std::weak_ptr<AuroraSessionPrivacy> weak(privacy);
    const auto windowId = streamWindowId;
    QThreadPool::globalInstance()->start([weak, windowId, operation, id]() {
        const auto session = weak.lock();
        if (!session || !session->live) return;
        const auto response = runAuroraDisplayCommand(session->target, operation, id, session->live);
        const auto snapshot = AuroraDisplayControls::snapshot(response);
        const bool unsupported = response == "unsupported";
        if (!session->live) return;

        const auto mainLoop = CFRunLoopGetMain();
        CFRunLoopPerformBlock(mainLoop, kCFRunLoopCommonModes, ^{
            const auto current = weak.lock();
            if (!current || !current->live) return;
            current->displayBusy = false;
            AuroraSessionToolbarController* toolbar = auroraToolbar(nativeWindow(SDL_GetWindowFromID(windowId)));
            if (!toolbar || toolbar->privacy != current || !toolbar->_qtTitle) return;
            if (operation == QLatin1String("list")) {
                toolbar->_displayProbePending = NO;
                toolbar->_displayUnsupported = unsupported;
            }
            auto* chrome = toolbar->_qtTitle->rootObject();
            chrome->setProperty("displayRequestBusy", false);
            chrome->setProperty("creatingDisplay", false);
            if (!snapshot.isEmpty()) {
                toolbar->_displayState = snapshot;
                chrome->setProperty("displaySnapshot", snapshot);
            }
            if (operation != QLatin1String("list") &&
                (snapshot.value(QStringLiteral("status")).toString() != QLatin1String("ok") ||
                 (operation == QLatin1String("select") && snapshot.value(QStringLiteral("activeDisplayId")).toString() != id))) {
                if (snapshot.isEmpty()) [toolbar requestDisplay:QStringLiteral("list") id:QString()];
                chrome->setProperty("displayActionError", QStringLiteral("被控端未确认显示器变更。"));
            }
        });
        CFRunLoopWakeUp(mainLoop);
    });
}

- (void)updatePrivacyMenu
{
    if (_controlCenter.visible && _controlPage == 4) [self renderControlCenter];
}

- (void)requestPrivacy:(AuroraPrivacyOperation)operation
{
    if (!privacy || !privacy->live || privacy->target.program.isEmpty() || privacy->busy || privacy->displayBusy) {
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
    [self destroyQtTitleBar];
    if (_qtControls) {
        auto* view = reinterpret_cast<NSView*>(_qtControls->winId());
        [view removeFromSuperview];
        delete _qtControls;
    }
    [_controlCenter release];
    [_preferences release];
    _connectionDetails.delegate = nil;
    [self closeConnectionDetails];
    [_connectionDetails release];
    [_floatingPanel release];
    [_display removeFromSuperviewWithoutNeedingDisplay];
    [_display release];
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
    native.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    native.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    native.backgroundColor = rgb(0xedf1f8);
    native.titlebarAppearsTransparent = YES;

    [controller prepareQtTitleBar];
    native.toolbarStyle = [controller sessionToolbarStyle];
    [controller resizeItems];
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
    [controller showIfWindowed];
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
    if ([controller fullscreenTransitioning]) return false;
    if (fullscreen) {
        [controller syncFullscreenChrome];
        return false;
    }
    if (native.toolbar.delegate == controller) {
        [controller showIfWindowed];
        return true;
    }

    installSessionToolbar(native, controller);
    return true;
}

bool serviceAuroraQtChrome(SDL_Window* window)
{
    if (!qtTitleVisible && !qtControlsVisible && !qtAppearanceVisible) return false;
    // Cocoa's common run-loop sources flush QPA/Quick without taking native
    // NSEvents away from SDL_WaitEventTimeout's Cocoa dispatcher.
    @autoreleasepool {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true);
        if (qtTitleVisible) {
            auto* toolbar = auroraToolbar(nativeWindow(window));
            [toolbar checkQtTitleBar];
            [toolbar checkDisplays];
        }
    }
    return qtTitleVisible || qtControlsVisible || qtAppearanceVisible;
}

bool auroraRouteLocalSessionKey(SDL_Window* window, const SDL_KeyboardEvent& key, bool captureActive)
{
    return [auroraToolbar(nativeWindow(window)) routeLocalKey:key captureActive:captureActive];
}

bool auroraPrivacyEditorOwnsInput()
{
    return qtAppearanceVisible;
}

bool auroraRoutePrivacyEditorMouseButton(SDL_Window* window, const SDL_MouseButtonEvent& button)
{
    return [auroraToolbar(nativeWindow(window)) routePrivacyEditorMouseButton:button];
}

void auroraRestoreSessionVideoFocus(SDL_Window* window)
{
    [auroraToolbar(nativeWindow(window)) restoreVideoFocus];
}

bool auroraSessionToolbarTransitioning(SDL_Window* window)
{
    return [auroraToolbar(nativeWindow(window)) fullscreenTransitioning];
}

void prepareAuroraSessionToolbarForFullscreenChange(SDL_Window* window)
{
    [auroraToolbar(nativeWindow(window)) beginFullscreenRequest];
}

void finishAuroraSessionToolbarFullscreenChange(SDL_Window* window, bool accepted)
{
    [auroraToolbar(nativeWindow(window)) finishFullscreenRequest:accepted];
}

void syncAuroraSessionFullscreenChrome(SDL_Window* window)
{
    [auroraToolbar(nativeWindow(window)) syncFullscreenChrome];
}

void closeAuroraFullscreenControls(SDL_Window* window)
{
    auto* controller = auroraToolbar(nativeWindow(window));
    [controller closeConnectionDetails];
    [controller closeControlCenter];
    [controller hideQtTitleBar];
    [controller showFullscreenControls:NO];
}

void setAuroraSessionToolbarConnectionQuality(SDL_Window* window, bool poor)
{
    [auroraToolbar(nativeWindow(window)) updateConnectionQuality:poor];
}
