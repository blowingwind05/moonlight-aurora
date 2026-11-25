# Aurora Moonlight

This integration uses Moonlight Qt v6.0.0 at e7a2d9f44d7b43fe7f6d2e0f08bf55b7cca48818 on both Windows and macOS.

Initialize recursive submodules, then apply the relay patch from this checkout:

    git submodule update --init --recursive
    git -C moonlight-common-c/moonlight-common-c apply -p3 ../../aurora-patches/moonlight-common-c-relay.patch

Both platforms build with qmake and DEFINES+=AURORA_STREAM_RUNTIME. The Aurora entry point parses session parameters once. Windows hands the stream to the embedded child window, while macOS hands it to the native session window. The GameStream transport, certificate pinning and bitrate responses use the shared runtime code.

Sources staged here, including the connection view and bitrate parser, are maintained in [Aurora](https://github.com/blowingwind05/Aurora).
