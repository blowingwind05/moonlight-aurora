#pragma once

// Private Windows interface used only by the AuroraStream build.
#if defined(Q_OS_WIN32) && defined(AURORA_STREAM_RUNTIME)

#include <SDL.h>
#include <SDL_syswm.h>
#include <QByteArray>
#include <QString>

class AuroraEmbeddedSession
{
public:
    static constexpr int AttachmentFailed = 74;

    static AuroraEmbeddedSession& current()
    {
        static AuroraEmbeddedSession instance;
        return instance;
    }

    bool configure(const QByteArray& invitation)
    {
        const auto fields = invitation.split(':');
        if (fields.size() != 3 || fields[2].size() != 32) {
            return false;
        }
        for (char ch : fields[2]) {
            if ((ch < '0' || ch > '9') && (ch < 'a' || ch > 'f')) {
                return false;
            }
        }

        m_Parent = reinterpret_cast<HWND>(static_cast<uintptr_t>(fields[0].toLongLong()));
        m_ParentPid = fields[1].toUInt();
        m_Name = QStringLiteral("Aurora.Embedded.") + QString::fromLatin1(fields[2]);
        if (!hasHost()) {
            return false;
        }

        m_Ready = openEvent(QStringLiteral(".ready"), EVENT_MODIFY_STATE);
        m_Stop = openEvent(QStringLiteral(".stop"), SYNCHRONIZE);
        m_Fullscreen = openEvent(QStringLiteral(".fullscreen"), EVENT_MODIFY_STATE);
        return m_Ready && m_Stop && m_Fullscreen;
    }

    bool enabled() const { return m_Parent != nullptr; }
    bool attachmentFailed() const { return m_AttachmentFailed; }

    bool stopRequested() const
    {
        return enabled() && (WaitForSingleObject(m_Stop, 0) == WAIT_OBJECT_0 || !hasHost());
    }

    SDL_Window* createWindow()
    {
        RECT bounds;
        if (!hasHost() || !GetClientRect(m_Parent, &bounds)) {
            m_AttachmentFailed = true;
            return nullptr;
        }

        const auto instance = GetModuleHandleW(nullptr);
        WNDCLASSW windowClass = {};
        windowClass.style = CS_OWNDC | CS_DBLCLKS;
        windowClass.lpfnWndProc = DefWindowProcW;
        windowClass.hInstance = instance;
        windowClass.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512)); // Arrow
        windowClass.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
        windowClass.lpszClassName = L"AuroraEmbeddedStreamSurface";
        if (!RegisterClassW(&windowClass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
            m_AttachmentFailed = true;
            return nullptr;
        }

        m_Window = CreateWindowExW(0, windowClass.lpszClassName, L"", WS_CHILD | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
                                   0, 0, qMax(1L, bounds.right), qMax(1L, bounds.bottom),
                                   m_Parent, nullptr, instance, nullptr);
        if (!m_Window || GetParent(m_Window) != m_Parent) {
            destroyWindow(nullptr);
            m_AttachmentFailed = true;
            return nullptr;
        }

        SDL_SetHint(SDL_HINT_VIDEO_FOREIGN_WINDOW_OPENGL, "1");
        auto window = SDL_CreateWindowFrom(m_Window);
        if (!window) {
            destroyWindow(nullptr);
            m_AttachmentFailed = true;
            return nullptr;
        }

        // Keep SDL's window procedure in the chain. Clicking this child gives it
        // keyboard focus within the Aurora window and leaves toolbar clicks local.
        m_SdlProc = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(m_Window, GWLP_WNDPROC,
                                                              reinterpret_cast<LONG_PTR>(focusOnClick)));
        if (!m_SdlProc) {
            destroyWindow(window);
            m_AttachmentFailed = true;
            return nullptr;
        }
        return window;
    }

    void destroyWindow(SDL_Window* window)
    {
        if (m_SdlProc && IsWindow(m_Window)) {
            SetWindowLongPtrW(m_Window, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(m_SdlProc));
        }
        if (window) {
            SDL_DestroyWindow(window);
        }
        if (m_Window) {
            DestroyWindow(m_Window);
        }
        m_SdlProc = nullptr;
        m_Window = nullptr;
    }

    void show(SDL_Window* window)
    {
        ShowWindow(m_Window, SW_SHOWNOACTIVATE);

        // A foreign SDL window may already be marked shown. Queue the initial
        // decoder setup explicitly even when Windows doesn't send a show event.
        SDL_Event event = {};
        event.type = SDL_WINDOWEVENT;
        event.window.windowID = SDL_GetWindowID(window);
        event.window.event = SDL_WINDOWEVENT_SHOWN;
        SDL_PushEvent(&event);
    }

    void resize()
    {
        RECT parentBounds, childBounds;
        if (!IsIconic(GetAncestor(m_Parent, GA_ROOT)) && GetClientRect(m_Parent, &parentBounds) &&
                GetClientRect(m_Window, &childBounds) && parentBounds.right > 0 && parentBounds.bottom > 0 &&
                (parentBounds.right != childBounds.right || parentBounds.bottom != childBounds.bottom)) {
            SetWindowPos(m_Window, nullptr, 0, 0, parentBounds.right, parentBounds.bottom,
                         SWP_NOZORDER | SWP_NOACTIVATE);
        }
    }

    void ready() const { SetEvent(m_Ready); }
    void toggleFullscreen() const { SetEvent(m_Fullscreen); }
    void minimize() const { PostMessageW(GetAncestor(m_Parent, GA_ROOT), WM_SYSCOMMAND, SC_MINIMIZE, 0); }

private:
    ~AuroraEmbeddedSession()
    {
        if (m_Ready) CloseHandle(m_Ready);
        if (m_Stop) CloseHandle(m_Stop);
        if (m_Fullscreen) CloseHandle(m_Fullscreen);
    }

    bool hasHost() const
    {
        DWORD pid = 0;
        return m_Parent && GetWindowThreadProcessId(m_Parent, &pid) && pid == m_ParentPid &&
                (GetWindowLongPtrW(m_Parent, GWL_STYLE) & WS_CHILD) &&
                GetPropW(m_Parent, reinterpret_cast<LPCWSTR>(m_Name.utf16())) == reinterpret_cast<HANDLE>(1);
    }

    HANDLE openEvent(const QString& suffix, DWORD access) const
    {
        const auto name = QStringLiteral("Local\\") + m_Name + suffix;
        return OpenEventW(access, FALSE, reinterpret_cast<LPCWSTR>(name.utf16()));
    }

    static LRESULT CALLBACK focusOnClick(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam)
    {
        switch (message) {
        case WM_LBUTTONDOWN:
        case WM_RBUTTONDOWN:
        case WM_MBUTTONDOWN:
        case WM_XBUTTONDOWN:
            SetFocus(hwnd);
            break;
        }
        return CallWindowProcW(current().m_SdlProc, hwnd, message, wParam, lParam);
    }

    QString m_Name;
    HWND m_Parent = nullptr;
    HWND m_Window = nullptr;
    DWORD m_ParentPid = 0;
    WNDPROC m_SdlProc = nullptr;
    HANDLE m_Ready = nullptr;
    HANDLE m_Stop = nullptr;
    HANDLE m_Fullscreen = nullptr;
    bool m_AttachmentFailed = false;
};

#endif
