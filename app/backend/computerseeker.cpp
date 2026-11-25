#include "computerseeker.h"
#include "computermanager.h"
#include "nvhttp.h"
#include <QPointer>
#include <QTimer>

ComputerSeeker::ComputerSeeker(ComputerManager *manager, QString computerName, QObject *parent, bool loadApps)
    : QObject(parent), m_ComputerManager(manager), m_ComputerName(computerName),
      m_TimeoutTimer(new QTimer(this)), m_LoadApps(loadApps)
{
    // A paired Aurora connection already has a verified route and an awake host.
    if (m_LoadApps) {
        m_ExpectedPairedHost = qEnvironmentVariable("AURORA_GAMESTREAM_PAIRED_HOST_UUID");
    }
#ifndef AURORA_STREAM_RUNTIME
    // If we know this computer, send a WOL packet to wake it up in case it is asleep.
    for (NvComputer * computer: m_ComputerManager->getComputers()) {
        if (m_ExpectedPairedHost.isEmpty() && NvHTTP::gameStreamRelayAddress().isNull() && this->matchComputer(computer)) {
            computer->wake();
        }
    }

#endif

    m_TimeoutTimer->setSingleShot(true);
    connect(m_TimeoutTimer, &QTimer::timeout,
            this, &ComputerSeeker::onTimeout);
    connect(m_ComputerManager, &ComputerManager::computerStateChanged,
            this, &ComputerSeeker::onComputerUpdated);
}

void ComputerSeeker::start(int timeout)
{
    m_TimeoutTimer->start(timeout);
    if (!m_ExpectedPairedHost.isEmpty()) {
        connect(m_ComputerManager, &ComputerManager::computerAddCompleted, this,
                [this](const QVariant& success, const QVariant&) {
            if (!success.toBool() && m_TimeoutTimer->isActive()) {
                onTimeout();
            }
        });
        m_ComputerManager->addNewHostManually(m_ComputerName);
        return;
    }
    const auto relayAddress = NvHTTP::gameStreamRelayAddress();
    if (!relayAddress.isNull()) {
        m_ComputerManager->addNewHostManually(relayAddress.toString());
        return;
    }

    // Seek desired computer by both connecting to it directly (this may fail
    // if m_ComputerName is UUID, or the name that doesn't resolve to an IP
    // address) and by polling it using mDNS, hopefully one of these methods
    // would find the host
    m_ComputerManager->addNewHostManually(m_ComputerName);
#ifndef AURORA_STREAM_RUNTIME
    m_ComputerManager->startPolling();
#endif
}

void ComputerSeeker::onComputerUpdated(NvComputer *computer)
{
    if (!m_TimeoutTimer->isActive()) {
        return;
    }
    if (matchComputer(computer) && isOnline(computer)) {
        if (m_ExpectedPairedHost.isEmpty() && NvHTTP::gameStreamRelayAddress().isNull()) {
            m_ComputerManager->stopPollingAsync();
        }
        m_TimeoutTimer->stop();
        if (m_LoadApps) {
            QPointer<ComputerSeeker> self(this);
            computer->loadPairedApps();
            if (!self) return;
        }
        emit computerFound(computer);
    }
}

bool ComputerSeeker::matchComputer(NvComputer *computer) const
{
    const auto relayAddress = NvHTTP::gameStreamRelayAddress();
    if (!relayAddress.isNull()) {
        return computer->activeAddress == relayAddress &&
               computer->uuid == qEnvironmentVariable("AURORA_GAMESTREAM_HOST_UUID");
    }
    if (!m_ExpectedPairedHost.isEmpty()) {
        return computer->activeAddress.toString().compare(m_ComputerName, Qt::CaseInsensitive) == 0 &&
               computer->uuid.compare(m_ExpectedPairedHost, Qt::CaseInsensitive) == 0;
    }
    QString value = m_ComputerName.toLower();

    if (computer->name.toLower() == value || computer->uuid.toLower() == value) {
        return true;
    }

    for (const NvAddress& addr : computer->uniqueAddresses()) {
        if (addr.address().toLower() == value || addr.toString().toLower() == value) {
            return true;
        }
    }

    return false;
}

bool ComputerSeeker::isOnline(NvComputer *computer) const
{
    return computer->state == NvComputer::CS_ONLINE;
}

void ComputerSeeker::onTimeout()
{
    m_TimeoutTimer->stop();
    if (m_ExpectedPairedHost.isEmpty() && NvHTTP::gameStreamRelayAddress().isNull()) {
        m_ComputerManager->stopPollingAsync();
    }
    emit errorTimeout();
}
