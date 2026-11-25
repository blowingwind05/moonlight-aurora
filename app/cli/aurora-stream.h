#pragma once

#include <QtGlobal>

class QGuiApplication;
class QString;
class StreamingPreferences;

#if defined(Q_OS_WIN32)
int prepareAuroraWindowsStream(const char* verb);
bool startAuroraWindowsStream(QGuiApplication& app, const QString& host, const QString& appName,
                              StreamingPreferences* preferences);
#elif defined(Q_OS_DARWIN)
int runAuroraMacStream(QGuiApplication& app, const QString& host, const QString& appName,
                      StreamingPreferences* preferences);
#endif
