// SPDX-License-Identifier: GPL-3.0-only
#include "../app/streaming/aurora-display-barrier.h"

#include <cstdlib>
#include <cstdio>
#include <string>
#include <tuple>
#include <vector>

static void require(bool result)
{
    if (!result) std::abort();
}

int main()
{
    using namespace Aurora;
    DisplayBarrier barrier;
    PresentedFrame renderer;
    uint32_t frame;
    std::vector<std::pair<uint32_t, uint32_t>> markers;
    auto sample = [&] {
        return renderer.latest(frame) && barrier.service(frame, [&](uint32_t generation, uint32_t presented) {
            markers.emplace_back(generation, presented);
            return true;
        });
    };

    require(!barrier.queue(1, 5));
    require(barrier.pause() && !barrier.pause());
    require(!barrier.queue(0, 5));
    require(barrier.queue(0xffffffffu, 0));
    require(!barrier.queue(1, 0));
    require(!sample());
    renderer.record(0xfffffffeu);
    require(!sample());
    renderer.record(1);
    renderer.record(0xffffffffu); // Late asynchronous callback.
    require(sample());
    require(markers.size() == 1 && markers[0].first == 0xffffffffu && markers[0].second == 1);
    require(!sample());
    require(!barrier.queue(1, 1)); // Host has yet to authorize release.
    require(barrier.release() && !barrier.release());
    require(barrier.pause());
    require(!barrier.queue(0xffffffffu, 1)); // Duplicate after release.
    require(!barrier.queue(0xfffffffeu, 1));
    require(barrier.queue(1, 2)); // 0 is reserved, generation wraps to 1.
    require(!sample());
    require(barrier.release());
    renderer.record(2);
    require(!sample()); // Releasing a failed/rolled back switch cancels the request.

    DisplayBarrier newWorker;
    PresentedFrame replacementRenderer;
    require(newWorker.pause() && newWorker.queue(1, 0));
    require(!replacementRenderer.latest(frame));
    replacementRenderer.record(0);
    require(replacementRenderer.latest(frame) && frame == 0);
    require(!newWorker.service(frame, [](uint32_t, uint32_t) { return false; }));
    require(newWorker.pending() && !newWorker.sent());
    require(newWorker.service(frame, [](uint32_t generation, uint32_t frame) {
        require(generation == 1 && frame == 0);
        return true;
    }));
    require(newWorker.sent() && !newWorker.pending());

    PresentIds dxgi;
    dxgi.submit(0xffffffffu, 7);
    dxgi.submit(0, 8);
    dxgi.submit(2, 10);
    require(!dxgi.find(1, frame)); // A dropped/missing present cannot confirm a frame.
    require(dxgi.find(0, frame) && frame == 8);
    require(dxgi.find(2, frame) && frame == 10);
    dxgi.clear();
    require(!dxgi.find(2, frame));

    DisplayControlReader reader;
    using Command = DisplayControlReader::Command;
    std::vector<std::tuple<Command, uint32_t, uint32_t>> commands;
    auto feed = [&](std::string_view bytes) {
        reader.feed(bytes, [&](Command command, uint32_t generation, uint32_t firstFrame) {
            commands.emplace_back(command, generation, firstFrame);
        });
    };
    const std::string pause = StreamSession::DisplayPause;
    feed(pause.substr(0, 5));
    require(commands.empty());
    feed(pause.substr(5));
    const std::string present = StreamSession::DisplayPresent;
    feed(present + "4294967295,");
    feed("0\n");
    feed(present + "0,5\n" + present + "4294967296,0\n" + present + "1,4294967296\n");
    feed(present + "1,0\r\n" + present + "1,-1\n" + present + "01,0\n" + present + "2,0,5\n");
    feed(std::string(200, 'x') + pause);
    feed(StreamSession::DisplayRelease);
    require(commands.size() == 3);
    require(commands[0] == std::make_tuple(Command::Pause, 0u, 0u));
    require(commands[1] == std::make_tuple(Command::Present, 0xffffffffu, 0u));
    require(commands[2] == std::make_tuple(Command::Release, 0u, 0u));
    std::puts("PASS display barrier lifecycle, presentation IDs, uint32 wrap, and private pipe framing");
}
