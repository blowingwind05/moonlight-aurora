#pragma once

#include "identitymanager.h"
#include "nvhttp.h"

#include <openssl/x509.h>
#include <openssl/evp.h>

class NvPairingManager
{
public:
    enum PairState
    {
        PAIRED,
        PIN_WRONG,
        FAILED,
        ALREADY_IN_PROGRESS,
        ALREADY_PAIRED
    };

    explicit NvPairingManager(NvComputer* computer, const NvAddress& pairAddress);

    ~NvPairingManager();

    PairState
    pair(QString appVersion, QString pin, QSslCertificate& serverCert, const QString& deviceName);

private:
    QByteArray
    generateRandomBytes(int length);

    QByteArray
    saltPin(const QByteArray& salt, QString pin);

    QByteArray
    encrypt(const QByteArray& plaintext, const QByteArray& key);

    QByteArray
    decrypt(const QByteArray& ciphertext, const QByteArray& key);

    QByteArray
    getSignatureFromPemCert(const QByteArray& certificate);

    bool
    verifySignature(const QByteArray& data, const QByteArray& signature, const QByteArray& serverCertificate);

    NvHTTP m_Http;
    bool m_ExactEndpoint;
    QString m_ExpectedHostId;
    X509* m_Cert;
};
