#include "aurora-mac-stream.h"
#include "startstream.h"
#include "backend/computermanager.h"
#include "streaming/aurora-session-toolbar.h"
#include "streaming/session.h"
#include "qt-session/AuroraConnectionView.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <QDebug>
#include <QGuiApplication>
#include <QScreen>
#include <QThreadPool>
#include <QTimer>
#include <functional>
#include <memory>

namespace {
constexpr int RetryConnection = 75;
constexpr CGFloat ProgressSize = 26;

NSString* nativeText(const QString& text)
{
    return [NSString stringWithUTF8String:text.toUtf8().constData()];
}

NSColor* rgb(unsigned color)
{
    return [NSColor colorWithSRGBRed:((color >> 16) & 255) / 255.0
                               green:((color >> 8) & 255) / 255.0 blue:(color & 255) / 255.0 alpha:1];
}
}

@interface AuroraConnectSpinner : NSView {
    CAShapeLayer* _arc;
}
- (void)setRunning:(BOOL)running;
@end

@implementation AuroraConnectSpinner
- (instancetype)init
{
    self = [super initWithFrame:NSMakeRect(0, 0, ProgressSize, ProgressSize)];
    if (self) {
        self.wantsLayer = YES;
        auto* track = [CAShapeLayer layer];
        _arc = [CAShapeLayer layer];
        const auto circle = CGPathCreateWithEllipseInRect(CGRectInset(NSRectToCGRect(self.bounds), 1, 1), nullptr);
        for (CAShapeLayer* part in @[track, _arc]) {
            part.frame = self.bounds;
            part.fillColor = NSColor.clearColor.CGColor;
            part.lineWidth = 2;
            part.path = circle;
            [self.layer addSublayer:part];
        }
        CGPathRelease(circle);
        track.strokeColor = rgb(0xd4e0f2).CGColor;
        _arc.strokeColor = rgb(0x087cf5).CGColor;
        _arc.strokeEnd = .26;
        _arc.lineCap = kCALineCapRound;
        [self setAccessibilityElement:NO];
    }
    return self;
}

- (void)setRunning:(BOOL)running
{
    self.hidden = !running;
    if (!running || NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        [_arc removeAnimationForKey:@"rotation"];
    } else if (![_arc animationForKey:@"rotation"]) {
        auto* rotate = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        rotate.toValue = @(-6.28318530718);
        rotate.duration = .85;
        rotate.repeatCount = HUGE_VALF;
        [_arc addAnimation:rotate forKey:@"rotation"];
    }
}
@end

@interface AuroraConnectWindow : NSWindowController <NSWindowDelegate> {
@public
    std::function<void()> dismiss;
    std::function<void()> retry;
    std::function<void()> confirmQuit;
@private
    AuroraConnectionView* _qtView;
    NSTextField* _title;
    NSTextView* _detail;
    NSScrollView* _detailScroll;
    AuroraConnectSpinner* _spinner;
    NSButton* _retryButton;
    NSButton* _quitButton;
}
- (instancetype)initWithDeviceName:(NSString*)deviceName;
- (void)showTitle:(NSString*)title detail:(NSString*)detail
         progress:(BOOL)progress failure:(BOOL)failure offerQuit:(BOOL)offerQuit;
- (void)hideConnection;
- (void)finish;
@end

@implementation AuroraConnectWindow
- (instancetype)initWithDeviceName:(NSString*)deviceName
{
    const auto usable = NSScreen.mainScreen.visibleFrame;
    const CGFloat width = std::max<CGFloat>(400, std::min<CGFloat>(1000, NSWidth(usable) - 36));
    const CGFloat height = std::max<CGFloat>(236, std::min<CGFloat>(576, NSHeight(usable) - 72));
    std::unique_ptr<AuroraConnectionView> qt;
    NSWindow* window = nil;
    if (qEnvironmentVariableIntValue("AURORA_QT_SESSION") == 1 &&
        QGuiApplication::platformName() == QStringLiteral("cocoa")) {
        qt = std::make_unique<AuroraConnectionView>();
        if (qt->status() == QQuickView::Ready) {
            qt->setFlags(Qt::Window | Qt::CustomizeWindowHint | Qt::WindowTitleHint |
                         Qt::WindowCloseButtonHint | Qt::WindowMinimizeButtonHint);
            qt->setTitle(QString::fromNSString(deviceName));
            qt->resize(qRound(width), qRound(height));
            qt->setMinimumSize(QSize(400, 236));
            // On Cocoa, QWindow::winId() refers to the platform NSView.
            auto* view = reinterpret_cast<NSView*>(qt->winId());
            window = [view.window retain];
        }
        if (!window) {
            qWarning("Aurora Qt connection view could not be initialized. Using the native connection view.");
            qt.reset();
        }
    }
    if (!window) {
        window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                      NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
    }
    if (!window) {
        [self release];
        return nil;
    }
    window.title = deviceName;
    window.releasedWhenClosed = NO;
    window.contentMinSize = NSMakeSize(400, 236);
    self = [super initWithWindow:window];
    [window release];
    if (!self) return nil;

    installAuroraConnectionToolbar(self.window, deviceName, self, @selector(dismissWindow:));
    [self.window center];
    if (qt) {
        // Keep the Qt platform delegate responsible for the window lifecycle.
        _qtView = qt.release();
        _qtView->onDismiss = [self]() { [self dismissWindow:nil]; };
        _qtView->onRetry = [self]() { [self retryConnection:nil]; };
        _qtView->onQuitPrevious = [self]() { [self quitPreviousApp:nil]; };
        return self;
    }
    self.window.delegate = self;
    NSView* content = self.window.contentView;
    content.wantsLayer = YES;
    content.layer.backgroundColor = rgb(0xf9fafc).CGColor;

    _title = [NSTextField labelWithString:@""];
    _title.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    _title.textColor = rgb(0x19283f);
    _title.alignment = NSTextAlignmentCenter;
    _title.lineBreakMode = NSLineBreakByTruncatingTail;
    [content addSubview:_title];

    _spinner = [[[AuroraConnectSpinner alloc] init] autorelease];
    [content addSubview:_spinner];

    _detailScroll = [[[NSScrollView alloc] initWithFrame:NSZeroRect] autorelease];
    _detailScroll.drawsBackground = NO;
    _detailScroll.hasVerticalScroller = YES;
    _detailScroll.autohidesScrollers = YES;
    _detail = [[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 380, 72)] autorelease];
    _detail.drawsBackground = NO;
    _detail.editable = NO;
    _detail.selectable = YES;
    _detail.verticallyResizable = YES;
    _detail.autoresizingMask = NSViewWidthSizable;
    _detail.textContainer.widthTracksTextView = YES;
    _detail.textContainer.lineFragmentPadding = 0;
    _detailScroll.documentView = _detail;
    [content addSubview:_detailScroll];

    _retryButton = [NSButton buttonWithTitle:@"重试" target:self action:@selector(retryConnection:)];
    _retryButton.bezelStyle = NSBezelStyleRounded;
    _retryButton.bezelColor = rgb(0x087cf5);
    [content addSubview:_retryButton];
    _quitButton = [NSButton buttonWithTitle:@"退出应用" target:self action:@selector(quitPreviousApp:)];
    _quitButton.bezelStyle = NSBezelStyleRounded;
    [content addSubview:_quitButton];
    return self;
}

- (void)layoutBody
{
    const NSRect area = self.window.contentView.bounds;
    const CGFloat width = std::min<CGFloat>(420, NSWidth(area) - 40);
    const CGFloat left = NSMidX(area) - width / 2;
    const CGFloat middle = NSMidY(area);
    if (!_spinner.hidden) {
        // The ring and heading share the video's visual center.
        _spinner.frame = NSMakeRect(NSMidX(area) - ProgressSize / 2, middle + 5, ProgressSize, ProgressSize);
        _title.frame = NSMakeRect(left, middle - 31, width, 24);
        return;
    }

    _title.frame = NSMakeRect(left, middle + 57, width, 24);
    _detailScroll.frame = NSMakeRect(left, middle - 34, width, 72);
    const auto buttonFrame = NSMakeRect(NSMidX(area) - 48, middle - 75, 96, 32);
    _retryButton.frame = buttonFrame;
    _quitButton.frame = buttonFrame;
}

- (void)showTitle:(NSString*)title detail:(NSString*)detail
         progress:(BOOL)progress failure:(BOOL)failure offerQuit:(BOOL)offerQuit
{
    setAuroraConnectionToolbarFailed(self.window, failure);
    if (_qtView) {
        using Stage = AuroraConnectionView::Stage;
        const auto state = progress ? Stage::Connecting : failure ? Stage::Failed : Stage::ConfirmQuit;
        _qtView->showStage(state, QString::fromNSString(title), QString::fromNSString(detail ?: @""),
                           NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion);
        if (!_qtView->isVisible()) {
            _qtView->show();
            _qtView->requestActivate();
        }
        return;
    }
    _title.stringValue = title;
    _title.toolTip = progress ? detail : title;
    if (progress && detail.length) {
        [_title setAccessibilityHelp:detail];
    } else {
        [_title setAccessibilityHelp:nil];
    }
    _detailScroll.hidden = progress || !detail.length;
    _detail.string = progress ? @"" : detail;
    _detail.font = [NSFont systemFontOfSize:13];
    _detail.textColor = rgb(0x526176);
    _detail.alignment = NSTextAlignmentCenter;
    [_detail scrollRangeToVisible:NSMakeRange(0, 0)];
    _retryButton.hidden = !failure;
    _retryButton.keyEquivalent = failure ? @"\r" : @"";
    _quitButton.hidden = !offerQuit;
    [_spinner setRunning:progress];
    [self layoutBody];
    if (!self.window.visible) [self.window makeKeyAndOrderFront:nil];
}

- (void)windowDidResize:(NSNotification*)notification { [self layoutBody]; }
- (void)hideConnection
{
    if (_qtView) {
        _qtView->hide();
    } else {
        [_spinner setRunning:NO];
        [self.window orderOut:nil];
    }
}

- (void)finish
{
    [self hideConnection];
    if (_qtView) {
        // Release the controller's native reference before Qt destroys its window.
        self.window = nil;
        delete _qtView;
        _qtView = nullptr;
    } else {
        self.window.delegate = nil;
        [self.window close];
    }
}
- (void)dismissWindow:(id)sender { if (dismiss) dismiss(); }
- (void)retryConnection:(id)sender { if (retry) retry(); }
- (void)quitPreviousApp:(id)sender { if (confirmQuit) confirmQuit(); }

- (BOOL)windowShouldClose:(NSWindow*)sender
{
    if (dismiss) dismiss();
    return NO;
}
@end

static int runConnectionAttempt(QGuiApplication& app, const QString& host, const QString& appName,
                                StreamingPreferences* preferences, AuroraConnectWindow* window)
{
    @autoreleasepool {
        ComputerManager manager(preferences);
        CliStartStream::Launcher launcher(host, appName, preferences);

        Session* session = nullptr;
        bool cancelled = false;
        bool failed = false;
        bool quittingPreviousApp = false;
        bool connected = false;
        QString sessionError;

        auto showProgress = [&](const QString& detail) {
            if (cancelled) return;
            [window showTitle:@"正在连接…" detail:nativeText(detail) progress:YES failure:NO offerQuit:NO];
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
            [window hideConnection];
            if (failed || session == nullptr) {
                cancelled = !failed;
                app.exit(failed ? 1 : 0);
                return;
            }
            cancelled = true;
            session->cancelAuroraConnection();
        };
        window->retry = [&]() {
            if (failed && session == nullptr) app.exit(RetryConnection);
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
                [window hideConnection];
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
        window->dismiss = {};
        window->confirmQuit = {};
        window->retry = {};
        return result;
    }
}

int runAuroraMacStream(QGuiApplication& app, const QString& host, const QString& appName,
                       StreamingPreferences* preferences)
{
    @autoreleasepool {
        app.setApplicationDisplayName(QStringLiteral("Aurora"));
        const auto preferred = qEnvironmentVariable("AURORA_STREAM_DEVICE_NAME").simplified();
        auto* window = [[AuroraConnectWindow alloc] initWithDeviceName:
            preferred.isEmpty() ? @"远程设备" : nativeText(preferred)];
        if (!window) return 1;

        int result;
        do {
            result = runConnectionAttempt(app, host, appName, preferences, window);
        } while (result == RetryConnection);

        [window finish];
        [window release];
        return result;
    }
}
