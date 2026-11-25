#pragma once

#include <algorithm>

struct AuroraSessionToolbarLayout {
    int device;
    int status;
    int fullscreen;
    int controls;
    int disconnect;
    bool brand;

    int actionsWidth() const {
        return fullscreen + controls + disconnect + 8 + (brand ? 28 : 0);
    }
};

inline AuroraSessionToolbarLayout auroraSessionToolbarLayout(
        int width, int trafficRight, int nameWidth, bool brandAvailable)
{
    AuroraSessionToolbarLayout layout{
        0, width < 490 ? 25 : 94,
        width < 760 ? 32 : 80, width < 760 ? 32 : 94,
        width < 490 ? 32 : 58, brandAvailable};
    // Leave room for AppKit's toolbar margins and the flexible gap between groups.
    const int available = width - std::max(78, trafficRight) - 40 - layout.status - 8;
    if (layout.brand && available - layout.actionsWidth() < 64) {
        layout.brand = false;
    }
    layout.device = std::max(36, std::min({nameWidth, 240, available - layout.actionsWidth()}));
    return layout;
}
