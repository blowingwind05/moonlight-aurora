#include "aurora-session-toolbar.h"
#include "aurora-session-privacy.h"

#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#include <SDL_syswm.h>
#include <QThreadPool>

static NSWindow* auroraNativeWindow(SDL_Window* window)
{
    SDL_SysWMinfo info = {};
    SDL_VERSION(&info.version);
    if (!window || !SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_COCOA) {
        return nil;
    }
    return info.info.cocoa.window;
}

@interface AuroraSessionToolbarController : NSTitlebarAccessoryViewController <NSMenuDelegate> {
@public
    Uint32 streamWindowId;
    std::shared_ptr<AuroraSessionPrivacy> privacy;
@private
    NSPopUpButton* _controlCenter;
    NSMenuItem* _privacyItem;
    NSMenuItem* _privacyNote;
}
- (void)requestPrivacy:(AuroraPrivacyOperation)operation;
- (void)updatePrivacyMenu;
@end

static AuroraSessionToolbarController* auroraToolbar(NSWindow* nativeWindow)
{
    for (NSTitlebarAccessoryViewController* accessory in nativeWindow.titlebarAccessoryViewControllers) {
        if ([accessory isKindOfClass:[AuroraSessionToolbarController class]]) {
            return (AuroraSessionToolbarController*)accessory;
        }
    }
    return nil;
}

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
            AuroraSessionToolbarController* toolbar = auroraToolbar(auroraNativeWindow(SDL_GetWindowFromID(windowId)));
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
    if (!privacy || privacy->busy) {
        return;
    }
    if (privacy->state == AuroraPrivacyState::On) {
        [self requestPrivacy:AuroraPrivacyOperation::Disable];
    } else if (privacy->state == AuroraPrivacyState::Off) {
        [self requestPrivacy:AuroraPrivacyOperation::Enable];
    }
}

- (void)dealloc
{
    _controlCenter.menu.delegate = nil;
    [_controlCenter release];
    [super dealloc];
}

- (void)loadView
{
    NSView* strip = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 36)];
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

    _controlCenter = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [_controlCenter addItemWithTitle:@"控制中心"];
    _controlCenter.refusesFirstResponder = YES;
    [_controlCenter setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                              forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSMenu* controlMenu = _controlCenter.menu;
    controlMenu.autoenablesItems = NO;
    controlMenu.delegate = self;
    _privacyItem = [[NSMenuItem alloc] initWithTitle:@"隐私保护" action:@selector(togglePrivacy:) keyEquivalent:@""];
    _privacyItem.target = self;
    [controlMenu addItem:_privacyItem];
    [_privacyItem release];
    _privacyNote = [[NSMenuItem alloc] initWithTitle:@"" action:nullptr keyEquivalent:@""];
    _privacyNote.enabled = NO;
    [controlMenu addItem:_privacyNote];
    [_privacyNote release];
    [self updatePrivacyMenu];

    NSTextField* hint = [NSTextField labelWithString:@"释放鼠标  ⌃⌥⇧Z"];
    hint.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    hint.textColor = [NSColor secondaryLabelColor];
    hint.lineBreakMode = NSLineBreakByTruncatingTail;
    [hint setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView* row = [NSStackView stackViewWithViews:@[fullscreen, stats, _controlCenter, disconnect, hint]];
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

bool installAuroraSessionToolbar(SDL_Window* window, const std::shared_ptr<AuroraSessionPrivacy>& privacy)
{
    if (![NSThread isMainThread] || (SDL_GetWindowFlags(window) & SDL_WINDOW_FULLSCREEN)) {
        return false;
    }

    NSWindow* nativeWindow = auroraNativeWindow(window);
    if (!nativeWindow || !(nativeWindow.styleMask & NSWindowStyleMaskTitled) ||
        (nativeWindow.styleMask & NSWindowStyleMaskFullSizeContentView)) {
        return false;
    }

    if (auroraToolbar(nativeWindow)) {
        return true;
    }

    // NSWindow owns the accessory and its controls. It can be installed again
    // if SDL recreates the Cocoa window for a different renderer.
    AuroraSessionToolbarController* controller = [[AuroraSessionToolbarController alloc] init];
    controller->streamWindowId = SDL_GetWindowID(window);
    controller->privacy = privacy;
    controller.layoutAttribute = NSLayoutAttributeBottom;
    controller.fullScreenMinHeight = 0;
    [nativeWindow addTitlebarAccessoryViewController:controller];
    if (privacy && !privacy->lastStatusCheck.isValid()) {
        [controller requestPrivacy:AuroraPrivacyOperation::Status];
    }
    [controller release];
    return true;
}
