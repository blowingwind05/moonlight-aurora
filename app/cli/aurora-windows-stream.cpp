#include <QGuiApplication>
#include <QTimer>

#include "aurora-stream.h"
#include "../AuroraStreamSessionProtocol.h"
#include "cli/startstream.h"
#include "backend/computermanager.h"
#include "qt-session/AuroraEmbeddedConnectionView.h"
#include "settings/streamingpreferences.h"
#include "streaming/aurora-connection-details.h"
#include "streaming/auroraembedded.h"
#include "streaming/session.h"

#include <cstdio>
#include <cstring>

static void startAuroraEmbeddedStream(QGuiApplication& app, CliStartStream::Launcher* launcher,
                                      StreamingPreferences* preferences)
{
    auto manager = new ComputerManager(preferences);
    manager->setParent(&app);
    auto stopTimer = new QTimer(launcher);
    QObject::connect(stopTimer, &QTimer::timeout, &app, [&app]() {
        if (AuroraEmbeddedSession::current().stopRequested()) {
            app.quit();
        }
    });
    auto reportFailure = [&app](const QString& message) {
        qWarning().noquote() << message;
        app.exit(1);
    };
    QObject::connect(launcher, &CliStartStream::Launcher::failed, &app, reportFailure);
    QObject::connect(launcher, &CliStartStream::Launcher::appQuitRequired, &app, [reportFailure](const QString& name) {
        reportFailure(QObject::tr("Close %1 on the host before starting the embedded stream.").arg(name));
    });
    QObject::connect(launcher, &CliStartStream::Launcher::sessionCreated, &app,
                     [&app, stopTimer](const QString&, Session* session) {
        stopTimer->stop();
        session->setParent(&app);
        auto reportSessionFailure = [session](const QString& message) {
            qWarning().noquote() << message;
            session->setProperty("auroraLaunchFailed", true);
        };
        QObject::connect(session, &Session::displayLaunchError, session, reportSessionFailure);
        QObject::connect(session, &Session::stageFailed, session,
                         [reportSessionFailure](const QString& stage, int errorCode, const QString&) {
            reportSessionFailure(QObject::tr("Starting %1 failed: %2").arg(stage).arg(errorCode));
        });
        QObject::connect(session, &Session::readyForDeletion, &app, [&app, session]() {
            if (session->transportLost()) {
                app.exit(Aurora::StreamSession::TransportLost);
            } else {
                app.exit(AuroraEmbeddedSession::current().attachmentFailed() ? AuroraEmbeddedSession::AttachmentFailed :
                         (session->property("auroraLaunchFailed").toBool() ? 1 : 0));
            }
        }, Qt::QueuedConnection);
        session->exec(nullptr);
    }, Qt::QueuedConnection);

    QTimer::singleShot(0, launcher, [launcher, manager, stopTimer]() {
        stopTimer->start(80);
        auto& embedded = AuroraEmbeddedSession::current();
        if (qEnvironmentVariableIntValue("AURORA_QT_SESSION") == 1) {
            if (auto host = embedded.hostWindow()) {
                auto stage = new AuroraEmbeddedConnectionView(host, launcher);
                if (auto view = stage->show()) {
                    embedded.setConnectionView(view);
                    std::fputs("aurora-connection-stage/1,qt\n", stdout);
                    std::fflush(stdout);
                } else {
                    delete stage;
                    qWarning("Aurora could not attach the Qt connection view. Using the host connection view.");
                }
            }
        }
        launcher->execute(manager);
    });
}

int prepareAuroraWindowsStream()
{
    const auto invitation = qgetenv("AURORA_EMBEDDED_SESSION");
    if (!invitation.isEmpty() &&
            !AuroraEmbeddedSession::current().configure(invitation)) {
        return AuroraEmbeddedSession::AttachmentFailed;
    }
    return 0;
}

bool startAuroraWindowsStream(QGuiApplication& app, const QString& host, const QString& appName,
                              StreamingPreferences* preferences)
{
    if (!AuroraEmbeddedSession::current().enabled()) {
        return false;
    }
    preferences->windowMode = StreamingPreferences::WM_WINDOWED;
    preferences->captureSysKeysMode = StreamingPreferences::CSK_OFF;
    if (qEnvironmentVariableIsSet("AURORA_CONNECTION_DETAILS")) {
        AuroraConnectionMonitor::instance().enableParentReporting();
    }
    auto* launcher = new CliStartStream::Launcher(host, appName, preferences, &app);
    startAuroraEmbeddedStream(app, launcher, preferences);
    return true;
}
