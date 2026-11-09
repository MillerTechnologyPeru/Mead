#!/bin/sh
# Everything a change has to pass, inside the Docker image: the fixtures, the
# tests, the selftests, the ABI checks, and apps run from window to exit.
# Usage: Scripts/gate.sh [swift test arguments...]
set -eu
cd "$(dirname "$0")/.."
Scripts/build-android-fixtures.sh
swift build --scratch-path .build/linux
swift test --no-parallel --scratch-path .build/linux "$@"
bin=$(swift build --scratch-path .build/linux --show-bin-path)
fixtures=.build/mead-fixtures

for selftest in bionic cxx; do
    "$bin/mead" --selftest $fixtures/libfixture_$selftest.so
done

Scripts/check-jni-conformance.sh
MEAD_JNI_STUBS=$fixtures/stubs.swift "$bin/mead" --selftest $fixtures/libfixture_jni.so
diff $fixtures/stubs.swift Tests/MeadJNITests/GeneratedStubs.swift
echo "the trace wrote the stubs the tests compile"
if MEAD_STRICT=1 SWIFT_BACKTRACE=enable=no "$bin/mead" --selftest $fixtures/libfixture_jni.so 2>&1 | grep -q ": passed"; then
    echo "MEAD_STRICT did not stop at an unimplemented class" >&2
    exit 1
fi
echo "MEAD_STRICT stops at the first unimplemented class"
MEAD_TRACE=jni "$bin/mead" --selftest $fixtures/libfixture_jni.so 2>&1 | grep -q "mead(jni): FindClass java/lang/String"
echo "MEAD_TRACE=jni records the calls"

Scripts/check-android-abi.sh
SDL_VIDEODRIVER=dummy MEAD_DATA_DIR=$fixtures/app timeout 60 "$bin/mead" $fixtures/libfixture_glue.so
echo "a native_app_glue app ran from window to exit"

# Audio, written to a file by SDL's disk driver for the app to check, and
# read back from one for recording.
head -c 384000 /dev/zero | tr '\0' 'A' > $fixtures/audio-in.raw
SDL_AUDIO_DRIVER=disk SDL_AUDIO_DISK_OUTPUT_FILE=$fixtures/audio-out.raw \
    SDL_AUDIO_DISK_INPUT_FILE=$fixtures/audio-in.raw timeout 60 \
    "$bin/mead" --selftest $fixtures/libfixture_audio.so
echo "OpenSL ES and AAudio played and recorded the right samples"

# Rendering, for real, in Mesa's software drivers on a virtual X server.
run_app() {
    SDL_VIDEODRIVER=x11 LIBGL_ALWAYS_SOFTWARE=1 MEAD_DATA_DIR=$fixtures/app \
        timeout 120 xvfb-run -a -s "-screen 0 1280x800x24" "$bin/mead" "$@"
}

for app in gles vulkan; do
    run_app $fixtures/libfixture_$app.so
    echo "the $app app rendered and read back the right pixels"
    MEAD_GRAPHICS_API=$app run_app $fixtures/libfixture_$app.so
    echo "the $app app rendered with MEAD_GRAPHICS_API=$app"
    run_app --graphics-api $app $fixtures/libfixture_$app.so
    echo "--graphics-api $app does the same"
done

# Choosing one API has the other look absent, as games probe for it.
if ! MEAD_GRAPHICS_API=gles run_app $fixtures/libfixture_vulkan.so 2>&1 | grep -q "vkCreateInstance.*: -9"; then
    echo "choosing GLES did not hide Vulkan" >&2
    exit 1
fi
echo "choosing GLES hides Vulkan"
if ! MEAD_GRAPHICS_API=vulkan run_app $fixtures/libfixture_gles.so 2>&1 | grep -q "display != EGL_NO_DISPLAY"; then
    echo "choosing Vulkan did not hide GLES" >&2
    exit 1
fi
echo "choosing Vulkan hides GLES"
if "$bin/mead" --graphics-api metal $fixtures/libfixture_gles.so 2>/dev/null; then
    echo "an unknown graphics API was accepted" >&2
    exit 1
fi
echo "an unknown graphics API is refused"
