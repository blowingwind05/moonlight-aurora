#pragma once

#include <SDL.h>
#include <QString>

#include <memory>

struct AuroraSessionPrivacy;

// Reserved alongside Session's SDL_USEREVENT codes.
enum class AuroraToolbarAction : Sint32 {
    Disconnect = 105,
    ToggleFullscreen,
    ToggleStats,
    ReleaseMouse,
    ConnectionQualityChanged,
};

bool installAuroraSessionToolbar(SDL_Window* window, const QString& deviceName, bool connectionPoor,
                                 const std::shared_ptr<AuroraSessionPrivacy>& privacy);
void hideAuroraSessionToolbar(SDL_Window* window);
void closeAuroraFullscreenControls(SDL_Window* window);
void setAuroraSessionToolbarConnectionQuality(SDL_Window* window, bool poor);
