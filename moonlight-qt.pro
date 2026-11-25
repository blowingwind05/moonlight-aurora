TEMPLATE = subdirs
SUBDIRS = \
    moonlight-common-c \
    app \
    h264bitstream

# Build the dependencies in parallel before the final app
app.depends = moonlight-common-c h264bitstream
win32:!winrt {
    SUBDIRS += AntiHooking
    app.depends += AntiHooking
}
!winrt:win32|macx {
    SUBDIRS += soundio
    app.depends += soundio
}

# Support debug and release builds from command line for CI
CONFIG += debug_and_release

# Run our compile tests
load(configure)
qtCompileTest(SL)
qtCompileTest(EGL)

contains(DEFINES, AURORA_STREAM_RUNTIME) {
    SUBDIRS += aurora_stream_engine
    aurora_stream_engine.file = app/AuroraStreamEngine.pro
    aurora_stream_engine.makefile = Makefile.AuroraStreamEngine
    aurora_stream_engine.depends = $$app.depends
    app.depends += aurora_stream_engine
}
