#!/bin/sh
# Builds and tests Mead in an arm64 Linux container.
# Usage: Scripts/docker-test.sh [swift test arguments...]
# Linux build products go to .build/linux so they never mix with a macOS
# build; Android fixtures stay in .build/mead-fixtures, shared with the Mac.
set -eu
cd "$(dirname "$0")/.."
image=mead-dev
docker build --platform linux/arm64 -t "$image" .
exec docker run --rm --platform linux/arm64 \
    -v "$PWD:/mead" \
    "$image" \
    sh -c 'cd /mead && Scripts/build-android-fixtures.sh && swift build --scratch-path .build/linux && swift test --no-parallel --scratch-path .build/linux "$@" && bin=$(swift build --scratch-path .build/linux --show-bin-path) && for selftest in bionic cxx; do "$bin/mead" --selftest .build/mead-fixtures/libfixture_$selftest.so || exit 1; done && Scripts/check-jni-conformance.sh && MEAD_JNI_STUBS=.build/mead-fixtures/stubs.swift "$bin/mead" --selftest .build/mead-fixtures/libfixture_jni.so && diff .build/mead-fixtures/stubs.swift Tests/MeadJNITests/GeneratedStubs.swift && echo "the trace wrote the stubs the tests compile" && ! { MEAD_STRICT=1 SWIFT_BACKTRACE=enable=no "$bin/mead" --selftest .build/mead-fixtures/libfixture_jni.so 2>&1 | grep -q ": passed"; } && echo "MEAD_STRICT stops at the first unimplemented class" && MEAD_TRACE=jni "$bin/mead" --selftest .build/mead-fixtures/libfixture_jni.so 2>&1 | grep -q "mead(jni): FindClass java/lang/String" && echo "MEAD_TRACE=jni records the calls" && Scripts/check-android-abi.sh && SDL_VIDEODRIVER=dummy MEAD_DATA_DIR=.build/mead-fixtures/app timeout 60 "$bin/mead" .build/mead-fixtures/libfixture_glue.so && echo "a native_app_glue app ran from window to exit"' sh "$@"
