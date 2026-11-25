// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include <QEvent>
#include <QQuickItem>
#include <QQuickView>
#include <QString>
#include <QUrl>

#include <functional>

class AuroraConnectionView final : public QQuickView {
    Q_OBJECT

public:
    enum class Stage { Connecting, Failed, ConfirmQuit };

    AuroraConnectionView()
    {
        setResizeMode(SizeRootObjectToView);
        setColor(QColor(0xf9, 0xfa, 0xfc));
        setSource(QUrl(QStringLiteral("qrc:/aurora/session/ConnectionStage.qml")));
        if (auto* stage = rootObject()) {
            connect(stage, SIGNAL(retryRequested()), this, SLOT(retry()));
            connect(stage, SIGNAL(quitPreviousRequested()), this, SLOT(quitPrevious()));
        }
    }

    void showStage(Stage state, const QString& heading, const QString& detail, bool reduceMotion)
    {
        auto* stage = rootObject();
        stage->setProperty("heading", heading);
        stage->setProperty("detail", detail);
        stage->setProperty("reduceMotion", reduceMotion);
        stage->setProperty("connecting", state == Stage::Connecting);
        stage->setProperty("failed", state == Stage::Failed);
        stage->setProperty("offerQuit", state == Stage::ConfirmQuit);
    }

    std::function<void()> onDismiss;
    std::function<void()> onRetry;
    std::function<void()> onQuitPrevious;

protected:
    bool event(QEvent* event) override
    {
        if (event->type() == QEvent::Close && onDismiss) {
            event->ignore();
            onDismiss();
            return true;
        }
        return QQuickView::event(event);
    }

private slots:
    void retry() { if (onRetry) onRetry(); }
    void quitPrevious() { if (onQuitPrevious) onQuitPrevious(); }
};
