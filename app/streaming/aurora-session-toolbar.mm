#include "aurora-session-toolbar.h"

#import <AppKit/AppKit.h>
#include <SDL_syswm.h>

@interface AuroraSessionToolbarController : NSTitlebarAccessoryViewController {
@public
    Uint32 streamWindowId;
}
@end

@implementation AuroraSessionToolbarController

- (void)sendAction:(NSButton*)sender
{
    SDL_Event event = {};
    event.type = SDL_USEREVENT;
    event.user.timestamp = SDL_GetTicks();
    event.user.windowID = streamWindowId;
    event.user.code = static_cast<Sint32>(sender.tag);
    if (SDL_PushEvent(&event) != 1) {
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Could not enqueue Aurora toolbar action");
    }
}

- (void)loadView
{
    NSView* strip = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 36)];
    self.view = strip;
    [strip release];

    NSButton* fullscreen = [NSButton buttonWithTitle:@"全屏" target:self action:@selector(sendAction:)];
    NSButton* stats = [NSButton buttonWithTitle:@"统计" target:self action:@selector(sendAction:)];
    NSButton* disconnect = [NSButton buttonWithTitle:@"断开" target:self action:@selector(sendAction:)];
    fullscreen.tag = static_cast<NSInteger>(AuroraToolbarAction::ToggleFullscreen);
    stats.tag = static_cast<NSInteger>(AuroraToolbarAction::ToggleStats);
    disconnect.tag = static_cast<NSInteger>(AuroraToolbarAction::Disconnect);
    for (NSButton* button in @[fullscreen, stats, disconnect]) {
        button.refusesFirstResponder = YES;
        [button setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    }

    NSTextField* hint = [NSTextField labelWithString:@"释放鼠标  ⌃⌥⇧Z"];
    hint.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    hint.textColor = [NSColor secondaryLabelColor];
    hint.lineBreakMode = NSLineBreakByTruncatingTail;
    [hint setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView* row = [NSStackView stackViewWithViews:@[fullscreen, stats, disconnect, hint]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 8;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [strip addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:strip.leadingAnchor constant:12],
        [row.trailingAnchor constraintLessThanOrEqualToAnchor:strip.trailingAnchor constant:-12],
        [row.centerYAnchor constraintEqualToAnchor:strip.centerYAnchor],
    ]];
}

@end

bool installAuroraSessionToolbar(SDL_Window* window)
{
    if (![NSThread isMainThread] || (SDL_GetWindowFlags(window) & SDL_WINDOW_FULLSCREEN)) {
        return false;
    }

    SDL_SysWMinfo info = {};
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_COCOA) {
        return false;
    }

    NSWindow* nativeWindow = info.info.cocoa.window;
    if (!(nativeWindow.styleMask & NSWindowStyleMaskTitled) ||
        (nativeWindow.styleMask & NSWindowStyleMaskFullSizeContentView)) {
        return false;
    }

    for (NSTitlebarAccessoryViewController* accessory in nativeWindow.titlebarAccessoryViewControllers) {
        if ([accessory isKindOfClass:[AuroraSessionToolbarController class]]) {
            return true;
        }
    }

    // NSWindow owns the accessory and its controls. It can be installed again
    // if SDL recreates the Cocoa window for a different renderer.
    AuroraSessionToolbarController* controller = [[AuroraSessionToolbarController alloc] init];
    controller->streamWindowId = SDL_GetWindowID(window);
    controller.layoutAttribute = NSLayoutAttributeBottom;
    controller.fullScreenMinHeight = 0;
    [nativeWindow addTitlebarAccessoryViewController:controller];
    [controller release];
    return true;
}
