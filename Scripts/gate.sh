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

# Rendering, for real, in Mesa's software drivers on a virtual X server.
for app in gles vulkan; do
    SDL_VIDEODRIVER=x11 LIBGL_ALWAYS_SOFTWARE=1 MEAD_DATA_DIR=$fixtures/app \
        timeout 120 xvfb-run -a -s "-screen 0 1280x800x24" "$bin/mead" $fixtures/libfixture_$app.so
    echo "the $app app rendered and read back the right pixels"
done
