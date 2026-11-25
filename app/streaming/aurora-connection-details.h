#pragma once

#include <mutex>
#include <cstdio>

struct AuroraConnectionDetails {
    int width = 0;
    int height = 0;
    int codec = 0;
    int fpsHundredths = 0;
    int videoKbps = 0;
    int lossHundredths = -1;
    int decodeMicroseconds = -1;
    int roundTripMs = 0;
    bool poor = false;
};

class AuroraConnectionMonitor {
public:
    static AuroraConnectionMonitor& instance()
    {
        static AuroraConnectionMonitor monitor;
        return monitor;
    }

    void setPoor(bool poor)
    {
        std::lock_guard<std::mutex> guard(m_Lock);
        m_Latest.poor = poor;
    }

    void publish(AuroraConnectionDetails details)
    {
        {
            std::lock_guard<std::mutex> guard(m_Lock);
            details.poor = m_Latest.poor;
            m_Latest = details;
        }
#ifdef Q_OS_WIN32
        if (m_WriteToParent) {
            std::fprintf(stdout, "aurora-connection/1,%d,%d,%d,%d,%d,%d,%d,%d,%d\n",
                         details.width, details.height, details.codec, details.fpsHundredths,
                         details.videoKbps, details.lossHundredths, details.decodeMicroseconds,
                         details.roundTripMs, details.poor ? 1 : 0);
            std::fflush(stdout);
        }
#endif
    }

    AuroraConnectionDetails latest()
    {
        std::lock_guard<std::mutex> guard(m_Lock);
        return m_Latest;
    }

#ifdef Q_OS_WIN32
    void enableParentReporting() { m_WriteToParent = true; }
#endif

private:
    std::mutex m_Lock;
    AuroraConnectionDetails m_Latest;
#ifdef Q_OS_WIN32
    bool m_WriteToParent = false;
#endif
};
