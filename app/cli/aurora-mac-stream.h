#pragma once

class QGuiApplication;
class QString;
class StreamingPreferences;

int runAuroraMacStream(QGuiApplication& app, const QString& host, const QString& appName,
                       StreamingPreferences* preferences);
