#pragma once

#include <QByteArray>
#include <QElapsedTimer>
#include <QProcessEnvironment>
#include <QString>

#include <atomic>
#include <utility>

class NvAddress;
namespace AuroraBitrate { struct Request; }

enum class AuroraPrivacyOperation {
    Status,
    Enable,
    Disable,
    DisplayOff,
};

enum class AuroraPrivacyState {
    Unknown,
    On,
    Off,
    DisplayOff,
    Unavailable,
    Unsupported,
    Error,
};

struct AuroraPrivacyTarget {
    QString program;
    QString workingDirectory;
    QString endpoint;
    QString uuid;
    QProcessEnvironment environment;
};

AuroraPrivacyTarget makeAuroraPrivacyTarget(const NvAddress& address, int httpsPort,
                                           const QString& uuid, bool hasPinnedCertificate);

AuroraPrivacyState runAuroraPrivacyCommand(const AuroraPrivacyTarget& target, AuroraPrivacyOperation operation,
                                          const std::atomic<bool>& live);
QByteArray runAuroraBitrateCommand(const AuroraPrivacyTarget& target, const AuroraBitrate::Request& request,
                                  const std::atomic<bool>& live);

enum class AuroraPrivacyAppearanceAction { Read, Reset, Save };
enum class AuroraPrivacyAppearanceState { Default, Image, Saved, Unsupported, Failed, Unconfirmed };

struct AuroraPrivacyAppearanceReply {
    AuroraPrivacyAppearanceState state = AuroraPrivacyAppearanceState::Failed;
    QByteArray png;
};

AuroraPrivacyAppearanceReply runAuroraPrivacyAppearance(const AuroraPrivacyTarget& target,
    AuroraPrivacyAppearanceAction action, const QString& file,
    const std::atomic<bool>& sessionLive, const std::atomic<bool>& editorLive);

QByteArray runAuroraDisplayCommand(const AuroraPrivacyTarget& target, const QString& operation, const QString& id,
                                   const std::atomic<bool>& live);

struct AuroraSessionPrivacy {
    explicit AuroraSessionPrivacy(AuroraPrivacyTarget target) : target(std::move(target)) {}

    const AuroraPrivacyTarget target;
    std::atomic<bool> live{true};

    // Menu state belongs to the AppKit thread. The worker only reads live and target.
    AuroraPrivacyState state = AuroraPrivacyState::Unknown;
    QElapsedTimer lastStatusCheck;
    bool busy = false;
    bool bitrateBusy = false;
    bool displayBusy = false;
    bool changeRejected = false;

    bool canKeepApplication() const {
        return live && !busy && !bitrateBusy && !displayBusy &&
            (state == AuroraPrivacyState::Off || state == AuroraPrivacyState::Unsupported);
    }
};
