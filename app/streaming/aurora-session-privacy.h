#pragma once

#include <QElapsedTimer>
#include <QProcessEnvironment>
#include <QString>

#include <atomic>
#include <utility>

class NvAddress;

enum class AuroraPrivacyOperation {
    Status,
    Enable,
    Disable,
};

enum class AuroraPrivacyState {
    Unknown,
    On,
    Off,
    Unavailable,
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

struct AuroraSessionPrivacy {
    explicit AuroraSessionPrivacy(AuroraPrivacyTarget target) : target(std::move(target)) {}

    const AuroraPrivacyTarget target;
    std::atomic<bool> live{true};

    // Menu state belongs to the AppKit thread. The worker only reads live and target.
    AuroraPrivacyState state = AuroraPrivacyState::Unknown;
    QElapsedTimer lastStatusCheck;
    bool busy = false;
    bool changeRejected = false;
};
