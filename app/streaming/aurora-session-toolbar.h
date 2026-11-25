#pragma once

#include <SDL.h>

#include <memory>

struct AuroraSessionPrivacy;

// Reserved alongside Session's SDL_USEREVENT codes.
enum class AuroraToolbarAction : Sint32 {
    Disconnect = 105,
    ToggleFullscreen,
    ToggleStats,
};

bool installAuroraSessionToolbar(SDL_Window* window, const std::shared_ptr<AuroraSessionPrivacy>& privacy);
