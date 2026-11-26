#include "aurora-session-privacy.h"
#include "../AuroraStreamEntry.h"
#include "../backend/aurora-bitrate.h"
#include "../backend/nvaddress.h"
#include "../qt-session/AuroraPrivacyArtwork.h"

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

struct SessionCommandOutcome {
    bool started = false;
    int exitCode = -1;
};

static QByteArray runAuroraSessionCommand(const AuroraPrivacyTarget& target, const QString& command,
                                          const QStringList& options, int maxOutput, const std::atomic<bool>& live,
                                          int timeoutMs = 8000, const std::atomic<bool>* editorLive = nullptr,
                                          SessionCommandOutcome* outcome = nullptr)
{
    const auto canRun = [&] { return live && (!editorLive || *editorLive); };
    if (!canRun() || target.program.isEmpty()) {
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
        if (!invalid)
            output += child.read(maxOutput + 1 - output.size());
        if (output.size() > maxOutput) {
            invalid = true;
            loop.quit();
        }
    };

    QObject::connect(&child, &QProcess::readyReadStandardOutput, &loop, readOutput);
    QObject::connect(&child, &QProcess::started, &loop, [&] {
        if (outcome) outcome->started = true;
    });
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
        if (!canRun()) {
            loop.quit();
        }
    });

    // This event loop runs only in the worker. SDL owns the AppKit thread during streaming.
    timeout.start(timeoutMs);
    cancellation.start(80);
    child.start();
    if (!completed && !invalid && canRun()) {
        loop.exec();
    }
    if (!completed) {
        child.kill();
        child.waitForFinished(300);
    }
    readOutput();
    if (outcome && completed && !invalid && child.exitStatus() == QProcess::NormalExit)
        outcome->exitCode = child.exitCode();
    if (!canRun() || !completed || invalid || child.exitStatus() != QProcess::NormalExit || child.exitCode() != 0) {
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

QByteArray runAuroraDisplayCommand(const AuroraPrivacyTarget& target, const QString& operation, const QString& id,
                                   const std::atomic<bool>& live)
{
    QStringList options{operation};
    if (!id.isEmpty())
        options.append(id);
    return runAuroraSessionCommand(target, QStringLiteral("display-control"), options, 8194, live);
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
    if (output == "unsupported") return AuroraPrivacyState::Unsupported;
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

AuroraPrivacyAppearanceReply runAuroraPrivacyAppearance(const AuroraPrivacyTarget& target,
    AuroraPrivacyAppearanceAction action, const QString& file,
    const std::atomic<bool>& sessionLive, const std::atomic<bool>& editorLive)
{
    using State = AuroraPrivacyAppearanceState;
    const bool read = action == AuroraPrivacyAppearanceAction::Read;
    QStringList args;
    switch (action) {
    case AuroraPrivacyAppearanceAction::Read:
        args << QStringLiteral("read");
        break;
    case AuroraPrivacyAppearanceAction::Reset:
        args << QStringLiteral("reset");
        break;
    case AuroraPrivacyAppearanceAction::Save:
        if (file.isEmpty() || !QFileInfo(file).isAbsolute()) return {};
        args << QStringLiteral("save") << file;
        break;
    }

    constexpr int maxImageLine = 6 + 4 * ((AuroraPrivacyArtwork::MaxEncodedBytes + 2) / 3);
    SessionCommandOutcome outcome;
    // The appearance HTTP command allows 10 seconds for the request itself.
    const auto reply = runAuroraSessionCommand(target, QStringLiteral("privacy-appearance"), args,
        (read ? maxImageLine : 16) + 2, sessionLive, 20000, &editorLive, &outcome);
    if (reply == "unsupported") return {State::Unsupported, {}};
    if (!read && reply == "saved") return {State::Saved, {}};
    if (read && reply == "default") return {State::Default, {}};
    if (read && reply.startsWith("image=")) {
        const auto payload = reply.mid(6);
        const auto png = QByteArray::fromBase64(payload, QByteArray::AbortOnBase64DecodingErrors);
        if (png.isEmpty() || png.size() > AuroraPrivacyArtwork::MaxEncodedBytes || png.toBase64() != payload ||
            !png.startsWith(QByteArray::fromHex("89504e470d0a1a0a"))) return {};
        QBuffer buffer;
        buffer.setData(png);
        if (!buffer.open(QIODevice::ReadOnly)) return {};
        QImageReader reader(&buffer, "png");
        const auto size = reader.size();
        if (size.isEmpty() || qMax(size.width(), size.height()) > AuroraPrivacyArtwork::MaxImageEdge ||
            reader.read().isNull()) return {};
        return {State::Image, png};
    }
    // The paired command uses the same exit status for a rejected request and
    // a lost response after submission. Only its preflight exits are definitive.
    if (!read && outcome.started && outcome.exitCode != 2 && outcome.exitCode != 3 && outcome.exitCode != 5)
        return {State::Unconfirmed, {}};
    return {};
}
