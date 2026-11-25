#include "nvcomputer.h"
#ifdef AURORA_STREAM_RUNTIME
#include "../AuroraStreamEntry.h"
#include "aurora-bitrate.h"
#endif
#include <Limelight.h>

#include <QDebug>
#include <QUuid>
#include <QtNetwork/QNetworkReply>
#include <QEventLoop>
#include <QTimer>
#if defined(Q_OS_DARWIN) && defined(AURORA_STREAM_RUNTIME)
#include <QThread>
#endif
#include <QXmlStreamReader>
#include <QSslKey>
#include <QSslSocket>
#include <QImageReader>
#include <QtEndian>
#include <QNetworkProxy>

#define FAST_FAIL_TIMEOUT_MS 2000
#define REQUEST_TIMEOUT_MS 5000
#define LAUNCH_TIMEOUT_MS 120000
#define RESUME_TIMEOUT_MS 30000
#define QUIT_TIMEOUT_MS 30000

static constexpr qint64 AURORA_PAIRED_RESPONSE_LIMIT = 64;

NvHTTP::NvHTTP(NvAddress address, uint16_t httpsPort, QSslCertificate serverCert, bool exactEndpoint) :
    m_ServerCert(serverCert),
    m_ExactEndpoint(exactEndpoint || gameStreamRelayBase(address) != 0)
{
    m_BaseUrlHttp.setScheme("http");
    m_BaseUrlHttps.setScheme("https");

    setAddress(address);
    setHttpsPort(httpsPort);

    // Never use a proxy server
    QNetworkProxy noProxy(QNetworkProxy::NoProxy);
    m_Nam.setProxy(noProxy);

    connect(&m_Nam, &QNetworkAccessManager::sslErrors, this, &NvHTTP::handleSslErrors);
    if (m_ExactEndpoint) {
        // Check the peer before transmitting the request, even if system trust accepts its certificate.
        connect(&m_Nam, &QNetworkAccessManager::encrypted, this, [this](QNetworkReply* reply) {
            if (m_ServerCert.isNull() || reply->sslConfiguration().peerCertificate() != m_ServerCert) {
                reply->setProperty("auroraCertificateMismatch", true);
                reply->abort();
            }
        });
    }
}

NvHTTP::NvHTTP(NvComputer* computer) :
    NvHTTP(computer->activeAddress, computer->activeHttpsPort, computer->serverCert,
           qEnvironmentVariableIsSet("AURORA_GAMESTREAM_PAIRED_HOST_UUID"))
{

}

void NvHTTP::setServerCert(QSslCertificate serverCert)
{
    m_ServerCert = serverCert;
}

void NvHTTP::setAddress(NvAddress address)
{
    Q_ASSERT(!address.isNull());

    m_Address = address;

    m_BaseUrlHttp.setHost(address.address());
    m_BaseUrlHttps.setHost(address.address());

    m_BaseUrlHttp.setPort(address.port());
}

NvAddress NvHTTP::gameStreamRelayAddress()
{
#ifdef AURORA_STREAM_RUNTIME
    const int base = auroraGameStreamRelayBase();
    if (base > 0) {
        return NvAddress(QStringLiteral("127.0.0.1"), static_cast<uint16_t>(base));
    }
#endif
    return NvAddress();
}

uint16_t NvHTTP::gameStreamRelayBase(const NvAddress& address)
{
    const auto relayAddress = gameStreamRelayAddress();
    return !relayAddress.isNull() && address == relayAddress ? relayAddress.port() : 0;
}

void NvHTTP::setHttpsPort(uint16_t port)
{
    const auto relayBase = gameStreamRelayBase(m_Address);
    m_BaseUrlHttps.setPort(relayBase != 0 ? relayBase - 5 : port);
}

NvAddress NvHTTP::address()
{
    return m_Address;
}

QSslCertificate NvHTTP::serverCert()
{
    return m_ServerCert;
}

uint16_t NvHTTP::httpPort()
{
    return m_BaseUrlHttp.port();
}

uint16_t NvHTTP::httpsPort()
{
    return m_BaseUrlHttps.port();
}

QVector<int>
NvHTTP::parseQuad(QString quad)
{
    QVector<int> ret;

    // Return an empty vector for old GFE versions
    // that were missing GfeVersion.
    if (quad.isEmpty()) {
        return ret;
    }

    QStringList parts = quad.split(".");
    ret.reserve(parts.length());
    for (int i = 0; i < parts.length(); i++)
    {
        ret.append(parts.at(i).toInt());
    }

    return ret;
}

int
NvHTTP::getCurrentGame(QString serverInfo)
{
    // GFE 2.8 started keeping currentgame set to the last game played. As a result, it no longer
    // has the semantics that its name would indicate. To contain the effects of this change as much
    // as possible, we'll force the current game to zero if the server isn't in a streaming session.
    QString serverState = getXmlString(serverInfo, "state");
    if (serverState != nullptr && serverState.endsWith("_SERVER_BUSY"))
    {
        return getXmlString(serverInfo, "currentgame").toInt();
    }
    else
    {
        return 0;
    }
}

QString
NvHTTP::getServerInfo(NvLogLevel logLevel, bool fastFail)
{
#ifdef AURORA_STREAM_RUNTIME
    m_PinnedServerInfo = false;
#endif
    QString serverInfo;

    // Check if we have a pinned cert and HTTPS port for this host yet
    if (!m_ServerCert.isNull() && httpsPort() != 0)
    {
        try
        {
            // Always try HTTPS first, since it properly reports
            // pairing status (and a few other attributes).
            serverInfo = openConnectionToString(m_BaseUrlHttps,
                                                "serverinfo",
                                                nullptr,
                                                fastFail ? FAST_FAIL_TIMEOUT_MS : REQUEST_TIMEOUT_MS,
                                                logLevel);
            // Throws if the request failed
            verifyResponseStatus(serverInfo);
#ifdef AURORA_STREAM_RUNTIME
            m_PinnedServerInfo = true;
#endif
        }
        catch (const GfeHttpResponseException& e)
        {
            if (e.getStatusCode() == 401 && !m_ExactEndpoint)
            {
                // Certificate validation error, fallback to HTTP
                serverInfo = openConnectionToString(m_BaseUrlHttp,
                                                    "serverinfo",
                                                    nullptr,
                                                    fastFail ? FAST_FAIL_TIMEOUT_MS : REQUEST_TIMEOUT_MS,
                                                    logLevel);
                verifyResponseStatus(serverInfo);
            }
            else
            {
                // Rethrow real errors
                throw e;
            }
        }
    }
    else
    {
        // Only use HTTP prior to pairing or fetching HTTPS port
        serverInfo = openConnectionToString(m_BaseUrlHttp,
                                            "serverinfo",
                                            nullptr,
                                            fastFail ? FAST_FAIL_TIMEOUT_MS : REQUEST_TIMEOUT_MS,
                                            logLevel);
        verifyResponseStatus(serverInfo);

        // Populate the HTTPS port
        uint16_t httpsPort = getXmlString(serverInfo, "HttpsPort").toUShort();
        if (httpsPort == 0) {
            httpsPort = DEFAULT_HTTPS_PORT;
        }
        setHttpsPort(httpsPort);

        // If we just needed to determine the HTTPS port, we'll try again over
        // HTTPS now that we have the port number
        if (!m_ServerCert.isNull()) {
            return getServerInfo(logLevel, fastFail);
        }
    }

    if (gameStreamRelayBase(m_Address) != 0 &&
        getXmlString(serverInfo, "uniqueid") != qEnvironmentVariable("AURORA_GAMESTREAM_HOST_UUID")) {
        throw GfeHttpResponseException(409, QStringLiteral("GameStream relay reached an unexpected host UUID"));
    }
    return serverInfo;
}

void
NvHTTP::startApp(QString verb,
                 bool isGfe,
                 int appId,
                 PSTREAM_CONFIGURATION streamConfig,
                 bool sops,
                 bool localAudio,
                 int gamepadMask,
                 bool persistGameControllersOnDisconnect,
                 QString& rtspSessionUrl)
{
#ifdef AURORA_STREAM_RUNTIME
    if (streamConfig->requireEncryption && (!m_ExactEndpoint || m_ServerCert.isNull() || !httpsPort())) {
        throw GfeHttpResponseException(401, "Encrypted streaming requires a verified host certificate");
    }
#endif
    int riKeyId;

    memcpy(&riKeyId, streamConfig->remoteInputAesIv, sizeof(riKeyId));
    riKeyId = qFromBigEndian(riKeyId);

    QString response =
            openConnectionToString(m_BaseUrlHttps,
                                   verb,
                                   "appid="+QString::number(appId)+
                                   "&mode="+QString::number(streamConfig->width)+"x"+
                                   QString::number(streamConfig->height)+"x"+
                                   // Using an FPS value over 60 causes SOPS to default to 720p60,
                                   // so force it to 0 to ensure the correct resolution is set. We
                                   // used to use 60 here but that locked the frame rate to 60 FPS
                                   // on GFE 3.20.3. We don't need this hack for Sunshine.
                                   QString::number((streamConfig->fps > 60 && isGfe) ? 0 : streamConfig->fps)+
                                   "&additionalStates=1&sops="+QString::number(sops ? 1 : 0)+
                                   "&rikey="+QByteArray(streamConfig->remoteInputAesKey, sizeof(streamConfig->remoteInputAesKey)).toHex()+
                                   "&rikeyid="+QString::number(riKeyId)+
                                   ((streamConfig->supportedVideoFormats & VIDEO_FORMAT_MASK_10BIT) ?
                                       "&hdrMode=1&clientHdrCapVersion=0&clientHdrCapSupportedFlagsInUint32=0&clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1&clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0" :
                                        "")+
                                   "&localAudioPlayMode="+QString::number(localAudio ? 1 : 0)+
                                   "&surroundAudioInfo="+QString::number(SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION(streamConfig->audioConfiguration))+
                                   "&remoteControllersBitmap="+QString::number(gamepadMask)+
                                   "&gcmap="+QString::number(gamepadMask)+
                                   "&gcpersist="+QString::number(persistGameControllersOnDisconnect ? 1 : 0)+
                                   LiGetLaunchUrlQueryParameters(),
                                   LAUNCH_TIMEOUT_MS);

    qInfo() << "Launch response:" << response;

    // Throws if the request failed
    verifyResponseStatus(response);

    rtspSessionUrl = getXmlString(response, "sessionUrl0");
}

void
NvHTTP::quitApp()
{
    QString response =
            openConnectionToString(m_BaseUrlHttps,
                                   "cancel",
                                   nullptr,
                                   QUIT_TIMEOUT_MS);

    qInfo() << "Quit response:" << response;

    // Throws if the request failed
    verifyResponseStatus(response);

    // Newer GFE versions will just return success even if quitting fails
    // if we're not the original requester.
    if (getCurrentGame(getServerInfo(NvHTTP::NVLL_ERROR)) != 0) {
        // Generate a synthetic GfeResponseException letting the caller know
        // that they can't kill someone else's stream.
        throw GfeHttpResponseException(599, "");
    }
}

QVector<NvDisplayMode>
NvHTTP::getDisplayModeList(QString serverInfo)
{
    QXmlStreamReader xmlReader(serverInfo);
    QVector<NvDisplayMode> modes;

    while (!xmlReader.atEnd()) {
        while (xmlReader.readNextStartElement()) {
            auto name = xmlReader.name();
            if (name == QString("DisplayMode")) {
                modes.append(NvDisplayMode());
            }
            else if (name == QString("Width")) {
                modes.last().width = xmlReader.readElementText().toInt();
            }
            else if (name == QString("Height")) {
                modes.last().height = xmlReader.readElementText().toInt();
            }
            else if (name == QString("RefreshRate")) {
                modes.last().refreshRate = xmlReader.readElementText().toInt();
            }
        }
    }

    return modes;
}

QVector<NvApp>
NvHTTP::getAppList()
{
    QString appxml = openConnectionToString(m_BaseUrlHttps,
                                            "applist",
                                            nullptr,
                                            REQUEST_TIMEOUT_MS,
                                            NvLogLevel::NVLL_ERROR);
    verifyResponseStatus(appxml);

    QXmlStreamReader xmlReader(appxml);
    QVector<NvApp> apps;
    while (!xmlReader.atEnd()) {
        while (xmlReader.readNextStartElement()) {
            auto name = xmlReader.name();
            if (name == QString("App")) {
                // We must have a valid app before advancing to the next one
                if (!apps.isEmpty() && !apps.last().isInitialized()) {
                    qWarning() << "Invalid applist XML";
                    Q_ASSERT(false);
                    return QVector<NvApp>();
                }
                apps.append(NvApp());
            }
            else if (name == QString("AppTitle")) {
                apps.last().name = xmlReader.readElementText();
            }
            else if (name == QString("ID")) {
                apps.last().id = xmlReader.readElementText().toInt();
            }
            else if (name == QString("IsHdrSupported")) {
                apps.last().hdrSupported = xmlReader.readElementText() == "1";
            }
            else if (name == QString("IsAppCollectorGame")) {
                apps.last().isAppCollectorGame = xmlReader.readElementText() == "1";
            }
        }
    }

    return apps;
}

void
NvHTTP::verifyResponseStatus(QString xml)
{
    QXmlStreamReader xmlReader(xml);

    while (xmlReader.readNextStartElement())
    {
        if (xmlReader.name() == QString("root"))
        {
            // Status code can be 0xFFFFFFFF in some rare cases on GFE 3.20.3, and
            // QString::toInt() will fail in that case, so use QString::toUInt()
            // and cast the result to an int instead.
            int statusCode = (int)xmlReader.attributes().value("status_code").toUInt();
            if (statusCode == 200)
            {
                // Successful
                return;
            }
            else
            {
                QString statusMessage = xmlReader.attributes().value("status_message").toString();
                if (statusCode != 401) {
                    // 401 is expected for unpaired PCs when we fetch serverinfo over HTTPS
                    qWarning() << "Request failed:" << statusCode << statusMessage;
                }
                if (statusCode == -1 && statusMessage == "Invalid") {
                    // Special case handling an audio capture error which GFE doesn't
                    // provide any useful status message for.
                    statusCode = 418;
                    statusMessage = tr("Missing audio capture device. Reinstalling GeForce Experience should resolve this error.");
                }
                throw GfeHttpResponseException(statusCode, statusMessage);
            }
        }
    }

    throw GfeHttpResponseException(-1, "Malformed XML (missing root element)");
}

QImage
NvHTTP::getBoxArt(int appId)
{
    QNetworkReply* reply = openConnection(m_BaseUrlHttps,
                                          "appasset",
                                          "appid="+QString::number(appId)+
                                          "&AssetType=2&AssetIdx=0",
                                          REQUEST_TIMEOUT_MS,
                                          NvLogLevel::NVLL_VERBOSE);
    QImage image = QImageReader(reply).read();
    delete reply;

    return image;
}

QByteArray NvHTTP::getAuroraWallpaper(const QString& revision)
{
    constexpr qint64 maxBytes = 512 * 1024;
    QScopedPointer<QNetworkReply> reply(openConnection(m_BaseUrlHttps, "aurora-wallpaper",
        "revision=" + revision, 3500, NvLogLevel::NVLL_ERROR, maxBytes));
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (status == 204) {
        return {};
    }
    if (status != 200 || reply->header(QNetworkRequest::ContentTypeHeader).toString() != "image/jpeg" ||
        reply->bytesAvailable() <= 0 || reply->bytesAvailable() > maxBytes) {
        throw GfeHttpResponseException(400, "Invalid wallpaper preview");
    }
    return reply->readAll();
}

QNetworkReply* NvHTTP::openAuroraPairedPost(const QString& command, const QString& action,
                                           const QSslConfiguration& clientIdentity)
{
    if (!m_ExactEndpoint || m_ServerCert.isNull() || m_BaseUrlHttps.scheme() != "https") {
        throw GfeHttpResponseException(400, "Invalid Aurora paired endpoint");
    }

    return openConnection(m_BaseUrlHttps, command, "action=" + action, REQUEST_TIMEOUT_MS, NVLL_NONE,
                          AURORA_PAIRED_RESPONSE_LIMIT, &clientIdentity);
}

void NvHTTP::sendAuroraPower(const QString& action, const QSslConfiguration& clientIdentity)
{
    if (action != "restart" && action != "shutdown") {
        throw GfeHttpResponseException(400, "Invalid Aurora power request");
    }

    QScopedPointer<QNetworkReply> reply(openAuroraPairedPost("aurora-power", action, clientIdentity));
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (status < 200 || status >= 300 || reply->bytesAvailable() > AURORA_PAIRED_RESPONSE_LIMIT ||
            reply->readAll().trimmed() != "accepted") {
        throw GfeHttpResponseException(400, "Invalid Aurora power response");
    }
}

QByteArray NvHTTP::sendAuroraPrivacy(const QString& action, const QSslConfiguration& clientIdentity)
{
    if (action != "status" && action != "on" && action != "off") {
        throw GfeHttpResponseException(400, "Invalid Aurora privacy request");
    }

    QScopedPointer<QNetworkReply> reply(openAuroraPairedPost("aurora-session-privacy", action, clientIdentity));
    const auto response = reply->read(AURORA_PAIRED_RESPONSE_LIMIT + 1);
    if (reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200 ||
            (response != QByteArrayLiteral("on") && response != QByteArrayLiteral("off") &&
             response != QByteArrayLiteral("unavailable"))) {
        throw GfeHttpResponseException(400, "Invalid Aurora privacy response");
    }
    return response;
}

#ifdef AURORA_STREAM_RUNTIME
QByteArray NvHTTP::sendAuroraBitrate(const AuroraBitrate::Request& request,
                                    const QSslConfiguration& clientIdentity)
{
    if (!m_ExactEndpoint || m_ServerCert.isNull() || m_BaseUrlHttps.scheme() != "https") {
        throw GfeHttpResponseException(400, "Invalid Aurora paired endpoint");
    }

    bool notFound = false;
    QScopedPointer<QNetworkReply> reply(openConnection(m_BaseUrlHttps, "aurora-video-bitrate-v2",
        QString::fromLatin1(AuroraBitrate::query(request)), REQUEST_TIMEOUT_MS, NVLL_NONE,
        AuroraBitrate::MaxReplyBytes, &clientIdentity, &notFound));
    if (notFound) {
        return QByteArrayLiteral("unsupported");
    }
    if (reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200) {
        throw GfeHttpResponseException(400, "Invalid Aurora bitrate response status");
    }
    const auto line = AuroraBitrate::validatedLine(request, reply->read(AuroraBitrate::MaxReplyBytes + 1));
    if (line.isEmpty()) {
        throw GfeHttpResponseException(400, "Invalid Aurora bitrate response");
    }
    return line;
}
#endif

QByteArray
NvHTTP::getXmlStringFromHex(QString xml,
                            QString tagName)
{
    QString str = getXmlString(xml, tagName);
    if (str == nullptr)
    {
        return nullptr;
    }

    return QByteArray::fromHex(str.toLatin1());
}

QString
NvHTTP::getXmlString(QString xml,
                     QString tagName)
{
    QXmlStreamReader xmlReader(xml);

    while (!xmlReader.atEnd())
    {
        if (xmlReader.readNext() != QXmlStreamReader::StartElement)
        {
            continue;
        }

        if (xmlReader.name() == tagName)
        {
            return xmlReader.readElementText();
        }
    }

    return nullptr;
}

void NvHTTP::handleSslErrors(QNetworkReply* reply, const QList<QSslError>& errors)
{
    bool ignoreErrors = true;

    if (m_ServerCert.isNull()) {
        // We should never make an HTTPS request without a cert
        Q_ASSERT(!m_ServerCert.isNull());
        return;
    }

    if (reply->operation() == QNetworkAccessManager::PostOperation &&
            reply->sslConfiguration().peerCertificate() != m_ServerCert) {
        return;
    }

    for (const QSslError& error : errors) {
        if (m_ServerCert != error.certificate()) {
            ignoreErrors = false;
            break;
        }
    }

    if (ignoreErrors) {
        reply->ignoreSslErrors(errors);
    }
}

QString
NvHTTP::openConnectionToString(QUrl baseUrl,
                               QString command,
                               QString arguments,
                               int timeoutMs,
                               NvLogLevel logLevel)
{
    QNetworkReply* reply = openConnection(baseUrl, command, arguments, timeoutMs, logLevel);
    QString ret;

    QTextStream stream(reply);

#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
    stream.setEncoding(QStringConverter::Utf8);
#else
    stream.setCodec("UTF-8");
#endif

    ret = stream.readAll();
    delete reply;

    return ret;
}

QNetworkReply*
NvHTTP::openConnection(QUrl baseUrl,
                       QString command,
                       QString arguments,
                       int timeoutMs,
                       NvLogLevel logLevel,
                       qint64 maxBytes,
                       const QSslConfiguration* pinnedPostIdentity,
                       bool* pairedNotFound)
{
    // Port must be set
    Q_ASSERT(baseUrl.port(0) != 0);

    // Build a URL for the request
    QUrl url(baseUrl);
    url.setPath("/" + command);

    // Use a common UID for Moonlight clients to allow them to quit
    // games for each other (otherwise GFE gets screwed up and it requires
    // manual intervention to solve).
    if (pinnedPostIdentity) {
        url.setQuery(arguments);
    } else {
        url.setQuery("uniqueid=0123456789ABCDEF&uuid=" +
                     QUuid::createUuid().toRfc4122().toHex() +
                     ((arguments != nullptr) ? ("&" + arguments) : ""));
    }

    QNetworkRequest request(url);
    if (maxBytes > 0) {
        request.setAttribute(QNetworkRequest::Http2AllowedAttribute, false);
        request.setRawHeader("Accept-Encoding", "identity");
        request.setRawHeader("Connection", "close");
    }

    if (m_ExactEndpoint) {
        request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
    }

    // Add our client certificate
    if (pinnedPostIdentity) {
        // Trust only the paired leaf, even when another leaf has a system-trusted chain.
        auto sslConfig = *pinnedPostIdentity;
        sslConfig.setCaCertificates({});
        sslConfig.setPeerVerifyMode(QSslSocket::VerifyPeer);
        sslConfig.setSslOption(QSsl::SslOptionDisableSessionTickets, true);
        sslConfig.setSslOption(QSsl::SslOptionDisableSessionSharing, true);
        request.setSslConfiguration(sslConfig);
        request.setHeader(QNetworkRequest::ContentTypeHeader, "application/x-www-form-urlencoded");
        m_Nam.clearConnectionCache();
    } else {
        request.setSslConfiguration(IdentityManager::get()->getSslConfig());
    }

#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
    // Disable HTTP/2 (GFE 3.22 doesn't like it) and Qt 6 enables it by default
    request.setAttribute(QNetworkRequest::Http2AllowedAttribute, false);
#endif

#if QT_VERSION >= QT_VERSION_CHECK(5, 14, 0) && QT_VERSION < QT_VERSION_CHECK(5, 15, 1) && !defined(QT_NO_BEARERMANAGEMENT)
    // HACK: Set network accessibility to work around QTBUG-80947 (introduced in Qt 5.14.0 and fixed in Qt 5.15.1)
    QT_WARNING_PUSH
    QT_WARNING_DISABLE_DEPRECATED
    m_Nam.setNetworkAccessible(QNetworkAccessManager::Accessible);
    QT_WARNING_POP
#endif

    QNetworkReply* reply = pinnedPostIdentity ? m_Nam.post(request, QByteArray()) : m_Nam.get(request);
    if (pinnedPostIdentity) {
        reply->setReadBufferSize(maxBytes + 1);
        connect(reply, &QNetworkReply::encrypted, reply, [this, reply, handshakeSeen = false]() mutable {
            // Qt emits this before writing the HTTP request. Do not resend a paired POST
            // on a new connection if the response was interrupted.
            if (handshakeSeen || reply->sslConfiguration().peerCertificate() != m_ServerCert) {
                reply->abort();
            }
            handshakeSeen = true;
        });
    }
    if (maxBytes > 0) {
        connect(reply, &QIODevice::readyRead, reply, [reply, maxBytes]() {
            if (reply->bytesAvailable() > maxBytes) {
                reply->abort();
            }
        });
    }

    // Run the request with a timeout if requested
    QEventLoop loop;
    if (pairedNotFound && pinnedPostIdentity && m_ExactEndpoint && url.scheme() == "https") {
        // Old paired hosts may return an HTML 404. Authenticate the headers and
        // stop reading the body so it cannot exceed the control response limit.
        connect(reply, &QNetworkReply::metaDataChanged, &loop, [this, reply, pairedNotFound]() {
            if (!*pairedNotFound && reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() == 404 &&
                    !reply->attribute(QNetworkRequest::RedirectionTargetAttribute).isValid() &&
                    reply->sslConfiguration().peerCertificate() == m_ServerCert) {
                *pairedNotFound = true;
                reply->abort();
            }
        });
    }
    connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);
    connect(QCoreApplication::instance(), &QCoreApplication::aboutToQuit, &loop, &QEventLoop::quit);
#if defined(Q_OS_DARWIN) && defined(AURORA_STREAM_RUNTIME)
    // The native connection window can cancel while the worker awaits /launch or /resume.
    QTimer cancelTimer;
    if (command == QStringLiteral("launch") || command == QStringLiteral("resume")) {
        connect(&cancelTimer, &QTimer::timeout, &loop, [&loop]() {
            if (QThread::currentThread()->isInterruptionRequested()) loop.quit();
        });
        cancelTimer.start(50);
    }
#endif
    if (timeoutMs) {
        QTimer::singleShot(timeoutMs, &loop, &QEventLoop::quit);
    }
    if (logLevel >= NvLogLevel::NVLL_VERBOSE) {
        qInfo() << "Executing request:" << url.toString();
    }
    loop.exec(QEventLoop::ExcludeUserInputEvents);

    // Abort the request if it timed out
    if (!reply->isFinished())
    {
        if (logLevel >= NvLogLevel::NVLL_ERROR) {
            qWarning() << "Aborting timed out request for" << url.toString();
        }
        reply->abort();
    }

    // We must clear out cached authentication and connections or
    // GFE will puke next time
    m_Nam.clearAccessCache();

    if (m_ExactEndpoint && reply->property("auroraCertificateMismatch").toBool()) {
        delete reply;
        throw GfeHttpResponseException(401, "Server certificate mismatch");
    }

    if (pairedNotFound && *pairedNotFound) {
        return reply;
    }

    // Handle error
    if (reply->error() != QNetworkReply::NoError)
    {
        if (logLevel >= NvLogLevel::NVLL_ERROR) {
            qWarning() << command << "request failed with error:" << reply->error();
        }

        if (reply->error() == QNetworkReply::SslHandshakeFailedError) {
            // This will trigger falling back to HTTP for the serverinfo query
            // then pairing again to get the updated certificate.
            GfeHttpResponseException exception(401, "Server certificate mismatch");
            delete reply;
            throw exception;
        }
        else if (reply->error() == QNetworkReply::OperationCanceledError) {
            QtNetworkReplyException exception(QNetworkReply::TimeoutError, "Request timed out");
            delete reply;
            throw exception;
        }
        else {
            QtNetworkReplyException exception(reply->error(), reply->errorString());
            delete reply;
            throw exception;
        }
    }

    if (m_ExactEndpoint) {
        if (reply->attribute(QNetworkRequest::RedirectionTargetAttribute).isValid()) {
            delete reply;
            throw GfeHttpResponseException(400, "Unexpected redirect from the requested pairing endpoint");
        }
        if (url.scheme() == "https" && (m_ServerCert.isNull() ||
                reply->sslConfiguration().peerCertificate() != m_ServerCert)) {
            delete reply;
            throw GfeHttpResponseException(401, "Server certificate mismatch");
        }
    }

    return reply;
}
