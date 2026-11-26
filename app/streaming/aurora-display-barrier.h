// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include "../AuroraStreamSessionProtocol.h"

#include <array>
#include <cstddef>
#include <atomic>
#include <cstdint>
#include <limits>
#include <string_view>

namespace Aurora {

inline bool serialAfter(uint32_t value, uint32_t previous)
{
    const uint32_t distance = value - previous;
    return distance != 0 && distance < 0x80000000u;
}

// Owned by one renderer. Metal callbacks may retain it after that renderer
// is destroyed, but a replacement renderer has its own presentation record.
class PresentedFrame {
public:
    void record(uint32_t frame)
    {
        const uint64_t value = Present | frame;
        auto previous = latest_.load(std::memory_order_relaxed);
        while (!(previous & Present) || serialAfter(frame, static_cast<uint32_t>(previous))) {
            if (latest_.compare_exchange_weak(previous, value, std::memory_order_release,
                                               std::memory_order_relaxed))
                return;
        }
    }

    bool latest(uint32_t& frame) const
    {
        const auto value = latest_.load(std::memory_order_acquire);
        if (!(value & Present)) return false;
        frame = static_cast<uint32_t>(value);
        return true;
    }

private:
    static constexpr uint64_t Present = uint64_t{1} << 32;
    std::atomic<uint64_t> latest_{0};
};

// DXGI presents are asynchronous and can skip queued frames. Only an exact
// present-ID match identifies the video frame that the compositor displayed.
class PresentIds {
public:
    void submit(uint32_t presentId, uint32_t frame)
    {
        slots_[next_++ % slots_.size()] = {true, presentId, frame};
    }

    bool find(uint32_t presentId, uint32_t& frame) const
    {
        for (const auto& slot : slots_) {
            if (slot.valid && slot.id == presentId) {
                frame = slot.frame;
                return true;
            }
        }
        return false;
    }

    void clear() { slots_ = {}; }

private:
    struct Slot {
        bool valid = false;
        uint32_t id = 0;
        uint32_t frame = 0;
    };
    std::array<Slot, 32> slots_{};
    std::size_t next_ = 0;
};

class DisplayBarrier {
public:
    bool pause()
    {
        if (paused_) return false;
        paused_ = true;
        return true;
    }

    bool queue(uint32_t generation, uint32_t firstFrame)
    {
        if (!paused_ || requested_ || !generation ||
            (generation_ && !serialAfter(generation, generation_))) return false;
        generation_ = generation;
        firstFrame_ = firstFrame;
        requested_ = true;
        pending_ = true;
        return true;
    }

    bool release()
    {
        if (!paused_) return false;
        paused_ = false;
        requested_ = false;
        pending_ = false;
        sent_ = false;
        return true;
    }

    bool pending() const { return pending_; }
    bool sent() const { return sent_; }

    template<class Sender>
    bool service(uint32_t presented, Sender&& send)
    {
        if (!pending_ || (presented != firstFrame_ && !serialAfter(presented, firstFrame_))) return false;
        if (!send(generation_, presented)) return false;
        pending_ = false;
        sent_ = true;
        return true;
    }

private:
    uint32_t generation_ = 0;
    uint32_t firstFrame_ = 0;
    bool paused_ = false;
    bool requested_ = false;
    bool pending_ = false;
    bool sent_ = false;
};

class DisplayControlReader {
public:
    enum class Command { Pause, Present, Release };

    template<class Dispatch>
    void feed(std::string_view bytes, Dispatch&& dispatch)
    {
        for (const auto byte : bytes) {
            if (byte == '\n') {
                if (!overflow_) dispatchLine({line_.data(), length_}, dispatch);
                length_ = 0;
                overflow_ = false;
            } else if (length_ == line_.size()) {
                overflow_ = true;
            } else {
                line_[length_++] = byte;
            }
        }
    }

private:
    static bool uint32(std::string_view text, uint32_t& value)
    {
        if (text.empty() || text.size() > 10 || (text.size() > 1 && text.front() == '0')) return false;
        value = 0;
        for (const auto character : text) {
            if (character < '0' || character > '9') return false;
            const auto digit = static_cast<uint32_t>(character - '0');
            if (value > ((std::numeric_limits<uint32_t>::max)() - digit) / 10) return false;
            value = value * 10 + digit;
        }
        return true;
    }

    template<class Dispatch>
    static void dispatchLine(std::string_view line, Dispatch& dispatch)
    {
        constexpr std::string_view pause = StreamSession::DisplayPause;
        constexpr std::string_view release = StreamSession::DisplayRelease;
        constexpr std::string_view present = StreamSession::DisplayPresent;
        if (line == pause.substr(0, pause.size() - 1)) dispatch(Command::Pause, 0, 0);
        else if (line == release.substr(0, release.size() - 1)) dispatch(Command::Release, 0, 0);
        else if (line.substr(0, present.size()) == present) {
            line.remove_prefix(present.size());
            const auto comma = line.find(',');
            uint32_t generation = 0;
            uint32_t frame = 0;
            if (comma != std::string_view::npos && uint32(line.substr(0, comma), generation) &&
                generation && uint32(line.substr(comma + 1), frame))
                dispatch(Command::Present, generation, frame);
        }
    }

    std::array<char, 64> line_{};
    std::size_t length_ = 0;
    bool overflow_ = false;
};

} // namespace Aurora
