#include "computerseeker.h"
#include "computermanager.h"
#include "nvhttp.h"
#include <QPointer>
#include <QTimer>

ComputerSeeker::ComputerSeeker(ComputerManager *manager, QString computerName, QObject *parent, bool loadApps)
    : QObject(parent), m_ComputerManager(manager), m_ComputerName(computerName),
      m_TimeoutTimer(new QTimer(this)), m_LoadApps(loadApps)
{
    // If we know this computer, send a WOL packet to wake it up in case it is asleep.
    for (NvComputer * computer: m_ComputerManager->getComputers()) {
        if (NvHTTP::gameStreamRelayAddress().isNull() && this->matchComputer(computer)) {
            computer->wake();
        }
    }

    m_TimeoutTimer->setSingleShot(true);
    connect(m_TimeoutTimer, &QTimer::timeout,
            this, &ComputerSeeker::onTimeout);
    connect(m_ComputerManager, &ComputerManager::computerStateChanged,
            this, &ComputerSeeker::onComputerUpdated);
}

void ComputerSeeker::start(int timeout)
{
    m_TimeoutTimer->start(timeout);
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
    m_ComputerManager->startPolling();
}

void ComputerSeeker::onComputerUpdated(NvComputer *computer)
{
    if (!m_TimeoutTimer->isActive()) {
        return;
    }
    if (matchComputer(computer) && isOnline(computer)) {
        if (NvHTTP::gameStreamRelayAddress().isNull()) {
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
    if (NvHTTP::gameStreamRelayAddress().isNull()) {
        m_ComputerManager->stopPollingAsync();
    }
    emit errorTimeout();
}
