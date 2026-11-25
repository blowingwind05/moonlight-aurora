#pragma once

#include <QSize>

inline QSize auroraStreamCaptureSize(const QSize& announced, bool automatic)
{
    // A source comes from one selected display. Limit unrecognized giant modes
    // before passing the dimensions to renderers and allocating decode surfaces.
    constexpr int maxDimension = 8192;
    constexpr int maxPixels = 7680 * 4320;
    if (!automatic || announced.width() < 2 || announced.height() < 2 ||
        announced.width() > maxDimension || announced.height() > maxDimension ||
        announced.width() * announced.height() > maxPixels) {
        return {};
    }

    // The 4:2:0 paths require whole pairs of pixels. Odd modes lose at most one
    // requested pixel per axis while the host still sends the entire display.
    return QSize(announced.width() & ~1, announced.height() & ~1);
}
