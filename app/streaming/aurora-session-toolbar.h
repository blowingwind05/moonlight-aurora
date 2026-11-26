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
    SyncFullscreenChrome,
};

bool installAuroraSessionToolbar(SDL_Window* window, const QString& deviceName, bool connectionPoor,
                                 const std::shared_ptr<AuroraSessionPrivacy>& privacy, int videoWidth, int videoHeight);
bool serviceAuroraQtChrome(SDL_Window* window);
bool auroraRouteLocalSessionKey(SDL_Window* window, const SDL_KeyboardEvent& key, bool captureActive);
void auroraRestoreSessionVideoFocus(SDL_Window* window);
bool auroraSessionToolbarTransitioning(SDL_Window* window);
void prepareAuroraSessionToolbarForFullscreenChange(SDL_Window* window);
void finishAuroraSessionToolbarFullscreenChange(SDL_Window* window, bool accepted);
void syncAuroraSessionFullscreenChrome(SDL_Window* window);
void closeAuroraFullscreenControls(SDL_Window* window);
void setAuroraSessionToolbarConnectionQuality(SDL_Window* window, bool poor);

#ifdef __OBJC__
  #import <objc/objc.h>
@class NSWindow;
@class NSString;
void installAuroraConnectionToolbar(NSWindow* window, NSString* deviceName, id cancelTarget, SEL cancelAction);
void setAuroraConnectionToolbarFailed(NSWindow* window, bool failed);
#endif
