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
    RouteSwitch,
};

bool installAuroraSessionToolbar(SDL_Window* window, const QString& deviceName, bool connectionPoor,
                                 const std::shared_ptr<AuroraSessionPrivacy>& privacy, int videoWidth, int videoHeight);
void prepareAuroraSessionToolbarForFullscreenChange(SDL_Window* window, bool enteringFullscreen);
void closeAuroraFullscreenControls(SDL_Window* window);
void setAuroraSessionToolbarConnectionQuality(SDL_Window* window, bool poor);

#ifdef __OBJC__
  #import <objc/objc.h>
@class NSWindow;
@class NSString;
void installAuroraConnectionToolbar(NSWindow* window, NSString* deviceName, id cancelTarget, SEL cancelAction);
void setAuroraConnectionToolbarFailed(NSWindow* window, bool failed);
#endif
