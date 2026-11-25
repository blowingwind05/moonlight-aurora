# Aurora Moonlight for windows

Upstream base: e7a2d9f44d7b43fe7f6d2e0f08bf55b7cca48818

Build with qmake using DEFINES+=AURORA_STREAM_RUNTIME.

After initializing submodules, apply the dependency patch:

    git -C moonlight-common-c/moonlight-common-c apply -p3 ../../aurora-patches/moonlight-common-c-relay.patch

Sources copied into this checkout are maintained in [Aurora](https://github.com/blowingwind05/Aurora). Update them there before replaying the integration.
