#pragma once

#include <QByteArray>
#include <QList>

#include <algorithm>
#include <limits>
#include <utility>

namespace AuroraBitrate {

constexpr int MaxReplyBytes = 96;
constexpr int MinRequestedKbps = 500;
constexpr int MaxKbps = 150000;

struct Request
{
    QByteArray session;
    QByteArray kbps;
    quint32 revision;

    Request(QByteArray session = {}, QByteArray kbps = {}, quint32 revision = 0)
        : session(std::move(session)), kbps(std::move(kbps)), revision(revision) {}

    bool setting() const { return !session.isEmpty(); }
};

inline bool validSession(const QByteArray& session)
{
    return session.size() == 32 && std::all_of(session.cbegin(), session.cend(), [](char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
    });
}

inline int canonicalKbps(const QByteArray& value, int minimum)
{
    if (value.isEmpty() || value.size() > 6) {
        return 0;
    }
    const int parsed = value.toInt();
    return parsed >= minimum && parsed <= MaxKbps && QByteArray::number(parsed) == value ? parsed : 0;
}

inline bool parseRevision(const QByteArray& value, quint32& revision)
{
    bool ok;
    const quint32 parsed = value.toUInt(&ok);
    if (!ok || QByteArray::number(parsed) != value) {
        return false;
    }
    revision = parsed;
    return true;
}

inline bool parseRequest(int argc, char** argv, Request& request)
{
    if (argc == 5 && QByteArray(argv[4]) == "status") {
        request = {};
        return true;
    }
    if (argc != 8 || QByteArray(argv[4]) != "set") {
        return false;
    }
    Request setting{QByteArray(argv[5]), QByteArray(argv[6])};
    if (!parseRevision(QByteArray(argv[7]), setting.revision) ||
            !validSession(setting.session) || !canonicalKbps(setting.kbps, MinRequestedKbps)) {
        return false;
    }
    request = setting;
    return true;
}

inline QByteArray query(const Request& request)
{
    return request.setting() ? "action=set&session=" + request.session +
                               "&revision=" + QByteArray::number(request.revision) + "&kbps=" + request.kbps :
                               QByteArray("action=status");
}

struct Confirmation
{
    QByteArray session;
    int requestedKbps;
    int encoderKbps;
    int maximumKbps;
    quint32 revision;
};

inline bool parseConfirmation(const Request& request, const QByteArray& line, Confirmation& confirmation)
{
    if (line.size() > MaxReplyBytes) {
        return false;
    }
    const auto fields = line.split(' ');
    if (fields.size() != 6 || fields[0] != (request.setting() ? "applied" : "status") ||
            !validSession(fields[1])) {
        return false;
    }

    const int requested = canonicalKbps(fields[2], MinRequestedKbps);
    const int encoder = canonicalKbps(fields[3], 1);
    const int maximum = canonicalKbps(fields[4], MinRequestedKbps);
    quint32 revision;
    if (!parseRevision(fields[5], revision) || !requested || !encoder || requested > maximum || encoder > requested) {
        return false;
    }
    if (request.setting() &&
            (request.revision == (std::numeric_limits<quint32>::max)() || revision != request.revision + 1 ||
             fields[1] != request.session || fields[2] != request.kbps)) {
        return false;
    }
    confirmation = {fields[1], requested, encoder, maximum, revision};
    return true;
}

inline QByteArray validatedLine(const Request& request, QByteArray response)
{
    if (response.size() > MaxReplyBytes) {
        return {};
    }
    if (response.endsWith('\n')) {
        response.chop(1);
    }
    if (response == "unsupported" || response == "unavailable" || response == "busy" ||
            response == "pending" || response == "expired" || response == "stale" ||
            response == "failed" || response == "rejected") {
        return response;
    }
    Confirmation confirmation;
    return parseConfirmation(request, response, confirmation) ? response : QByteArray{};
}

} // namespace AuroraBitrate
