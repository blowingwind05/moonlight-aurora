#pragma once

#include <cstdio>
#include <cstdlib>
#include <cstring>

inline int auroraGameStreamRelayBase()
{
    const char* value = std::getenv("AURORA_GAMESTREAM_RELAY_BASE");
    if (value == nullptr) {
        return 0;
    }
    int port = 0;
    for (; *value != '\0'; ++value) {
        if (*value < '0' || *value > '9' || port > 6553) {
            return -1;
        }
        port = port * 10 + (*value - '0');
    }
    return port > 5 && port <= 65535 - 21 ? port : -1;
}

inline int prepareAuroraStreamInvocation(int& argc, char** argv)
{
#ifdef _WIN32
    if (argc == 2 && std::strcmp(argv[1], "--aurora-embedded-info") == 0) {
        std::puts("aurora-embedded/1");
        return 0;
    }
#endif
    if (argc == 2 && std::strcmp(argv[1], "--aurora-runtime-info") == 0) {
        std::puts("aurora-stream/1");
        return 0;
    }
    if (argc == 2 && std::strcmp(argv[1], "--aurora-gamestream-relay-info") == 0) {
        std::puts("aurora-gamestream-relay/1");
        return 0;
    }
    if (argc < 3 || std::strcmp(argv[1], "--aurora-runtime") != 0 ||
        (std::strcmp(argv[2], "pair") != 0 && std::strcmp(argv[2], "list") != 0 &&
         std::strcmp(argv[2], "stream") != 0 && std::strcmp(argv[2], "wallpaper") != 0 &&
         std::strcmp(argv[2], "power") != 0 &&
         std::strcmp(argv[2], "privacy") != 0 &&
         std::strcmp(argv[2], "bitrate") != 0)) {
        std::fputs("Aurora Stream is launched by Aurora.\n", stderr);
        return 2;
    }
    const int relayBase = auroraGameStreamRelayBase();
    const char* relayHost = std::getenv("AURORA_GAMESTREAM_HOST_UUID");
    if (relayBase < 0 || (relayBase > 0 && (relayHost == nullptr || *relayHost == '\0'))) {
        std::fputs("Aurora GameStream relay requires a valid base port and host UUID.\n", stderr);
        return 2;
    }

    // Let Moonlight parse its original command line after checking the private entry point.
    for (int index = 1; index < argc; ++index) {
        argv[index] = argv[index + 1];
    }
    --argc;
    return -1;
}
