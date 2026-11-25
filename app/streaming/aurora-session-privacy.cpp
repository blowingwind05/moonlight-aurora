#include "aurora-session-privacy.h"
#include "../AuroraStreamEntry.h"
#include "../backend/aurora-bitrate.h"
#include "../backend/nvaddress.h"

#include <QCoreApplication>
#include <QDir>
#include <QEventLoop>
#include <QFileInfo>
#include <QHostAddress>
#include <QProcess>
#include <QRegularExpression>
#include <QStringList>
#include <QTimer>

AuroraPrivacyTarget makeAuroraPrivacyTarget(const NvAddress& address, int httpsPort,
                                           const QString& uuid, bool hasPinnedCertificate)
{
    const auto program = QCoreApplication::applicationFilePath();
    const QFileInfo programInfo(program);
    const QHostAddress host(address.address());
    const QRegularExpression uuidPattern(QStringLiteral(
        R"(\A[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\z)"));
    if (!hasPinnedCertificate || programInfo.completeBaseName() != QStringLiteral("AuroraStream") ||
        !programInfo.isAbsolute() || !programInfo.isExecutable() ||
        !uuidPattern.match(uuid).hasMatch() || host.isNull() || !host.scopeId().isEmpty() ||
        httpsPort <= 0 || httpsPort != address.port() + DEFAULT_HTTPS_PORT - DEFAULT_HTTP_PORT) {
        return {};
    }

    auto environment = QProcessEnvironment::systemEnvironment();
    const auto relayPortKey = QStringLiteral("AURORA_GAMESTREAM_RELAY_BASE");
    const auto relayHostKey = QStringLiteral("AURORA_GAMESTREAM_HOST_UUID");
    const int relayPort = auroraGameStreamRelayBase();
    const auto relayHost = environment.value(relayHostKey);
    if (relayPort < 0 || (relayPort == 0 && environment.contains(relayHostKey)) ||
        (relayPort > 0 && (address != NvAddress(QStringLiteral("127.0.0.1"), static_cast<uint16_t>(relayPort)) ||
                          uuid.compare(relayHost, Qt::CaseInsensitive) != 0))) {
        return {};
    }

    environment.remove(relayPortKey);
    environment.remove(relayHostKey);
    if (relayPort > 0) {
        environment.insert(relayPortKey, QString::number(relayPort));
        environment.insert(relayHostKey, relayHost);
    }
    return {program, QDir::currentPath(), NvAddress(host, address.port()).toString(), uuid, environment};
}

static QByteArray runAuroraSessionCommand(const AuroraPrivacyTarget& target, const QString& command,
                                          const QStringList& options, int maxOutput, const std::atomic<bool>& live)
{
    if (!live || target.program.isEmpty()) {
        return {};
    }

    QProcess child;
    child.setProgram(target.program);
    child.setWorkingDirectory(target.workingDirectory);
    child.setProcessEnvironment(target.environment);
    child.setStandardInputFile(QProcess::nullDevice());
    child.setStandardErrorFile(QProcess::nullDevice());
    child.setArguments(QStringList{QStringLiteral("--aurora-runtime"), command, target.endpoint, target.uuid} +
                       options);

    QEventLoop loop;
    QTimer timeout;
    timeout.setSingleShot(true);
    QTimer cancellation;
    QByteArray output;
    bool completed = false;
    bool invalid = false;
    auto readOutput = [&]() {
        output += child.readAllStandardOutput();
        if (output.size() > maxOutput) {
            invalid = true;
            loop.quit();
        }
    };

    QObject::connect(&child, &QProcess::readyReadStandardOutput, &loop, readOutput);
    QObject::connect(&child, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), &loop,
                     [&](int, QProcess::ExitStatus) {
        completed = true;
        loop.quit();
    });
    QObject::connect(&child, &QProcess::errorOccurred, &loop, [&](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) {
            invalid = true;
            loop.quit();
        }
    });
    QObject::connect(&timeout, &QTimer::timeout, &loop, [&]() {
        invalid = true;
        loop.quit();
    });
    QObject::connect(&cancellation, &QTimer::timeout, &loop, [&]() {
        if (!live) {
            loop.quit();
        }
    });

    // This event loop runs only in the worker. SDL owns the AppKit thread during streaming.
    timeout.start(8000);
    cancellation.start(80);
    child.start();
    if (!completed && !invalid && live) {
        loop.exec();
    }
    if (!completed) {
        child.kill();
        child.waitForFinished(300);
    }
    readOutput();
    if (!live || !completed || invalid || child.exitStatus() != QProcess::NormalExit || child.exitCode() != 0) {
        return {};
    }
    if (output.endsWith("\r\n")) {
        output.chop(2);
    } else if (output.endsWith('\n')) {
        output.chop(1);
    }
    if (output.contains('\r') || output.contains('\n')) {
        return {};
    }
    return output;
}

AuroraPrivacyState runAuroraPrivacyCommand(const AuroraPrivacyTarget& target, AuroraPrivacyOperation operation,
                                          const std::atomic<bool>& live)
{
    if (!live || target.program.isEmpty()) {
        return AuroraPrivacyState::Unavailable;
    }

    const char* verb = "status";
    switch (operation) {
    case AuroraPrivacyOperation::Status: break;
    case AuroraPrivacyOperation::Enable: verb = "on"; break;
    case AuroraPrivacyOperation::Disable: verb = "off"; break;
    case AuroraPrivacyOperation::DisplayOff: verb = "display-off"; break;
    }
    const auto output = runAuroraSessionCommand(target, QStringLiteral("privacy"),
        {QString::fromLatin1(verb)}, 16, live);
    if (output == "on") return AuroraPrivacyState::On;
    if (output == "off") return AuroraPrivacyState::Off;
    if (output == "display-off") return AuroraPrivacyState::DisplayOff;
    if (output == "unavailable") return AuroraPrivacyState::Unavailable;
    return AuroraPrivacyState::Error;
}

QByteArray runAuroraBitrateCommand(const AuroraPrivacyTarget& target, const AuroraBitrate::Request& request,
                                  const std::atomic<bool>& live)
{
    QStringList options{QStringLiteral("status")};
    if (request.setting()) {
        if (!AuroraBitrate::validSession(request.session) ||
                !AuroraBitrate::canonicalKbps(request.kbps, AuroraBitrate::MinRequestedKbps)) {
            return {};
        }
        options = QStringList{QStringLiteral("set"), QString::fromLatin1(request.session),
                              QString::fromLatin1(request.kbps), QString::number(request.revision)};
    }
    // The paired helper calls NvHTTP::sendAuroraBitrate and prints one validated line.
    const auto output = runAuroraSessionCommand(target, QStringLiteral("bitrate"),
        options, AuroraBitrate::MaxReplyBytes + 2, live);
    return AuroraBitrate::validatedLine(request, output);
}
