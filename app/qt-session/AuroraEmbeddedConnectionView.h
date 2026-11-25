// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include "AuroraConnectionView.h"

#include <QTimer>
#include <memory>
#include <windows.h>

class AuroraEmbeddedConnectionView final : public QObject {
public:
    explicit AuroraEmbeddedConnectionView(HWND hostWindow, QObject* owner)
        : QObject(owner), hostWindow(hostWindow)
    {
    }

    AuroraConnectionView* show()
    {
        host.reset(QWindow::fromWinId(reinterpret_cast<WId>(hostWindow)));
        if (!host) return nullptr;

        view = std::make_unique<AuroraConnectionView>();
        if (view->status() != QQuickView::Ready) return nullptr;
        view->setFlag(Qt::WindowTransparentForInput);
        view->setParent(host.get());
        if (GetParent(reinterpret_cast<HWND>(view->winId())) != hostWindow) return nullptr;

        resize();
        view->show();
        resizeTimer.setInterval(80);
        connect(&resizeTimer, &QTimer::timeout, this, [this] { resize(); });
        connect(view.get(), &QWindow::visibleChanged, &resizeTimer, [this](bool visible) {
            if (!visible) resizeTimer.stop();
        });
        resizeTimer.start();
        return view.get();
    }

private:
    void resize()
    {
        RECT bounds{};
        if (!IsIconic(GetAncestor(hostWindow, GA_ROOT)) && GetClientRect(hostWindow, &bounds) &&
                bounds.right > 0 && bounds.bottom > 0) {
            // Win32 reports physical pixels while QWindow geometry is in logical units.
            const auto scale = view->devicePixelRatio();
            const QSize size(qRound(bounds.right / scale), qRound(bounds.bottom / scale));
            if (view->size() != size) view->resize(size);
        }
    }

    HWND hostWindow;
    std::unique_ptr<QWindow> host;
    std::unique_ptr<AuroraConnectionView> view;
    QTimer resizeTimer;
};
