#include "aurora-mac-stream.h"
#include "startstream.h"
#include "backend/computermanager.h"
#include "streaming/session.h"

#import <AppKit/AppKit.h>

#include <QDebug>
#include <QGuiApplication>
#include <QScreen>
#include <QThreadPool>
#include <QTimer>
#include <functional>

namespace {
NSString* nativeText(const QString& text)
{
    return [NSString stringWithUTF8String:text.toUtf8().constData()];
}
}

@interface AuroraConnectWindow : NSWindowController <NSWindowDelegate> {
@public
    std::function<void()> dismiss;
    std::function<void()> confirmQuit;
@private
    NSTextField* _title;
    NSTextView* _detail;
    NSScrollView* _detailScroll;
    NSProgressIndicator* _spinner;
    NSButton* _dismissButton;
    NSButton* _quitButton;
}
- (void)showTitle:(NSString*)title detail:(NSString*)detail
         progress:(BOOL)progress failure:(BOOL)failure offerQuit:(BOOL)offerQuit;
@end

@implementation AuroraConnectWindow
- (instancetype)init
{
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 310)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    if (!window) {
        [self release];
        return nil;
    }
    window.title = @"Aurora";
    window.releasedWhenClosed = NO;
    self = [super initWithWindow:window];
    [window release];
    if (!self) return nil;

    self.window.delegate = self;
    [self.window center];
    NSView* content = self.window.contentView;

    NSString* brandPath = [NSBundle.mainBundle pathForResource:@"AuroraStreamBrand" ofType:@"png"];
    NSImage* brand = brandPath ? [[[NSImage alloc] initWithContentsOfFile:brandPath] autorelease] : nil;
    NSImageView* logo = [[[NSImageView alloc] initWithFrame:NSMakeRect(30, 226, 52, 52)] autorelease];
    logo.image = brand ?: NSApp.applicationIconImage;
    logo.imageScaling = NSImageScaleProportionallyUpOrDown;
    [content addSubview:logo];

    NSTextField* name = [NSTextField labelWithString:@"Aurora"];
    name.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
    name.frame = NSMakeRect(94, 237, 382, 30);
    [content addSubview:name];

    _title = [NSTextField labelWithString:@""];
    _title.frame = NSMakeRect(30, 178, 460, 30);
    _title.font = [NSFont systemFontOfSize:19 weight:NSFontWeightSemibold];
    _title.lineBreakMode = NSLineBreakByTruncatingTail;
    [content addSubview:_title];

    _detailScroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(25, 75, 470, 96)] autorelease];
    _detailScroll.drawsBackground = NO;
    _detailScroll.hasVerticalScroller = YES;
    _detailScroll.autohidesScrollers = YES;
    _detail = [[[NSTextView alloc] initWithFrame:_detailScroll.contentView.bounds] autorelease];
    _detail.drawsBackground = NO;
    _detail.editable = NO;
    _detail.selectable = YES;
    _detail.verticallyResizable = YES;
    _detail.textContainer.containerSize = NSMakeSize(NSWidth(_detail.bounds), CGFLOAT_MAX);
    _detail.autoresizingMask = NSViewWidthSizable;
    _detail.textContainer.widthTracksTextView = YES;
    _detailScroll.documentView = _detail;
    [content addSubview:_detailScroll];

    _spinner = [[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(30, 27, 22, 22)] autorelease];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.indeterminate = YES;
    _spinner.displayedWhenStopped = NO;
    [content addSubview:_spinner];

    _dismissButton = [NSButton buttonWithTitle:@"" target:self action:@selector(dismissWindow:)];
    _dismissButton.keyEquivalent = @"\033";
    [content addSubview:_dismissButton];

    _quitButton = [NSButton buttonWithTitle:nativeText(QStringLiteral("退出应用"))
                                    target:self action:@selector(quitPreviousApp:)];
    [content addSubview:_quitButton];

    return self;
}

- (void)showTitle:(NSString*)title detail:(NSString*)detail
         progress:(BOOL)progress failure:(BOOL)failure offerQuit:(BOOL)offerQuit
{
    _title.stringValue = title;
    _title.toolTip = title;
    _detail.string = detail;
    _detail.font = [NSFont systemFontOfSize:14];
    _detail.textColor = NSColor.secondaryLabelColor;
    [_detail scrollRangeToVisible:NSMakeRange(0, 0)];
    if (progress) {
        [_spinner startAnimation:nil];
    } else {
        [_spinner stopAnimation:nil];
    }

    _dismissButton.title = nativeText(failure ? QStringLiteral("关闭") : QStringLiteral("取消"));
    _dismissButton.keyEquivalent = failure ? @"\r" : @"\033";
    [_dismissButton sizeToFit];
    [_quitButton sizeToFit];
    const NSSize dismissSize = _dismissButton.frame.size;
    const NSSize quitSize = _quitButton.frame.size;
    _dismissButton.frame = NSMakeRect(490 - dismissSize.width, 22, dismissSize.width, dismissSize.height);
    _quitButton.frame = NSMakeRect(NSMinX(_dismissButton.frame) - quitSize.width - 8, 22,
                                   quitSize.width, quitSize.height);
    _quitButton.hidden = !offerQuit;

    if (!self.window.visible) [self.window makeKeyAndOrderFront:nil];
}

- (void)dismissWindow:(id)sender
{
    dismiss();
}

- (void)quitPreviousApp:(id)sender
{
    confirmQuit();
}

- (BOOL)windowShouldClose:(NSWindow*)sender
{
    dismiss();
    return NO;
}
@end

int runAuroraMacStream(QGuiApplication& app, const QString& host, const QString& appName,
                       StreamingPreferences* preferences)
{
    @autoreleasepool {
        app.setApplicationDisplayName(QStringLiteral("Aurora"));
        ComputerManager manager(preferences);
        CliStartStream::Launcher launcher(host, appName, preferences);
        auto* window = [[AuroraConnectWindow alloc] init];
        if (!window) return 1;

        Session* session = nullptr;
        bool cancelled = false;
        bool failed = false;
        bool quittingPreviousApp = false;
        bool connected = false;
        QString sessionError;

        auto showProgress = [&](const QString& detail) {
            if (cancelled) return;
            [window showTitle:nativeText(QStringLiteral("正在连接 %1").arg(host))
                       detail:nativeText(detail) progress:YES failure:NO offerQuit:NO];
        };
        auto showFailure = [&](const QString& detail) {
            if (cancelled || failed) return;
            failed = true;
            qWarning().noquote() << detail;
            const auto title = connected ? QStringLiteral("串流已结束") : QStringLiteral("连接失败");
            [window showTitle:nativeText(title)
                       detail:nativeText(detail) progress:NO failure:YES offerQuit:NO];
        };
        window->dismiss = [&]() {
            [window.window orderOut:nil];
            if (failed || session == nullptr) {
                cancelled = !failed;
                app.exit(failed ? 1 : 0);
                return;
            }
            cancelled = true;
            session->cancelAuroraConnection();
        };
        window->confirmQuit = [&]() {
            quittingPreviousApp = true;
            showProgress(QStringLiteral("正在关闭运行中的应用…"));
            launcher.quitRunningApp();
        };

        QObject::connect(&launcher, &CliStartStream::Launcher::searchingApp, &launcher, [&]() {
            showProgress(QStringLiteral("正在读取被控端的应用列表…"));
        });
        QObject::connect(&launcher, &CliStartStream::Launcher::failed, &launcher, showFailure);
        QObject::connect(&launcher, &CliStartStream::Launcher::appQuitRequired, &launcher,
                         [&](const QString& runningApp) {
            if (quittingPreviousApp || cancelled || failed) return;
            const auto message = QStringLiteral("要退出 %1 并启动 %2 吗？未保存的进度可能丢失。")
                                     .arg(runningApp, appName);
            [window showTitle:nativeText(QStringLiteral("已有应用正在运行"))
                       detail:nativeText(message) progress:NO failure:NO offerQuit:YES];
        });
        QObject::connect(&launcher, &CliStartStream::Launcher::sessionCreated, &launcher,
                         [&](const QString& launchedApp, Session* created) {
            created->setParent(&launcher);
            if (cancelled || failed) return;
            session = created;

            QObject::connect(session, &Session::stageStarting, &launcher, [&](const QString& stage) {
                if (!cancelled && !connected) showProgress(QStringLiteral("正在启动 %1…").arg(stage));
            });
            QObject::connect(session, &Session::stageFailed, &launcher,
                             [&](const QString& stage, int code, const QString& ports) {
                sessionError = QStringLiteral("启动 %1 失败（错误 %2）。").arg(stage).arg(code);
                if (!ports.isEmpty()) {
                    sessionError += QStringLiteral("\n\n") +
                        QStringLiteral("请检查以下端口的防火墙和转发设置：%1").arg(ports);
                }
            });
            QObject::connect(session, &Session::displayLaunchError, &launcher, [&](const QString& text) {
                sessionError = text;
            });
            QObject::connect(session, &Session::connectionStarted, &launcher, [&]() {
                connected = true;
                [window.window orderOut:nil];
            });
            QObject::connect(session, &Session::sessionFinished, &launcher, [&](int portTestResult) {
                if (!sessionError.isEmpty() && portTestResult > 0) {
                    sessionError += QStringLiteral("\n\n") +
                        QStringLiteral("当前网络可能阻止了串流连接。");
                }
            });
            QObject::connect(session, &Session::readyForDeletion, &launcher, [&]() {
                session->deleteLater();
                session = nullptr;
                if (cancelled) {
                    app.exit(0);
                } else if (!sessionError.isEmpty() || !connected) {
                    showFailure(sessionError.isEmpty() ? QStringLiteral("Aurora 未能启动串流。") : sessionError);
                } else {
                    app.exit(0);
                }
            }, Qt::QueuedConnection);

            showProgress(QStringLiteral("正在启动 %1…").arg(launchedApp));
            QTimer::singleShot(0, &launcher, [&]() {
                if (cancelled) {
                    app.exit(0);
                    return;
                }
                // Cocoa's screen coordinates grow up from the primary screen.
                const NSRect screen = window.window.screen.frame;
                const NSRect primary = NSScreen.screens.firstObject.frame;
                const QPoint center(qRound(NSMidX(screen)), qRound(NSMaxY(primary) - NSMidY(screen)));
                auto* targetScreen = QGuiApplication::screenAt(center);
                session->execAurora(targetScreen ? targetScreen->geometry() : QRect());
            });
        });

        QTimer::singleShot(0, &launcher, [&]() {
            showProgress(QStringLiteral("正在查找被控端并验证配对…"));
            [NSApp activateIgnoringOtherApps:YES];
            launcher.execute(&manager);
        });
        const int result = app.exec();

        // Keep the paired host and Session alive until deferred stream cleanup has finished.
        QThreadPool::globalInstance()->waitForDone();
        window.window.delegate = nil;
        [window.window close];
        [window release];
        return result;
    }
}
