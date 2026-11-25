#pragma once

#include <algorithm>

struct AuroraSessionToolbarLayout {
    static constexpr int DisplayFoot = 11;

    int device;
    int status;
    int display;
    int controls;
    int disconnect;
    bool brand;

    int contextWidth() const { return device + status + display + 2 * DisplayFoot + 14; }
    int actionsWidth() const { return controls + disconnect + 4 + (brand ? 36 : 0); }
};

inline AuroraSessionToolbarLayout auroraSessionToolbarLayout(
        int width, int trafficRight, int nameWidth, bool brandAvailable)
{
    const bool compact = width < 760;
    AuroraSessionToolbarLayout layout{
        0, width < 490 ? 25 : 94, compact ? 32 : 152,
        compact ? 32 : 94, width < 490 ? 32 : 58, brandAvailable};

    // Leave breathing room for the native traffic lights and toolbar margins.
    const int content = width - std::max(78, trafficRight) - 40;
    if (layout.brand && content - layout.contextWidth() - layout.actionsWidth() < 48) {
        layout.brand = false;
    }
    if (content - layout.contextWidth() - layout.actionsWidth() < 40) {
        layout.display = 32;
    }
    layout.device = std::max(36, std::min({nameWidth, 240, content - layout.contextWidth() - layout.actionsWidth()}));
    return layout;
}
