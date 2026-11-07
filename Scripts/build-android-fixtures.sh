#!/bin/sh
# Cross-builds the loader's Android test fixtures: ELF aarch64 .so files,
# built with Debian's clang and lld against the NDK's sysroot (the NDK's own
# tools are x86_64 binaries and cannot run on arm64). Mead's tests load
# them, unmodified, in Docker.
# Usage: MEAD_NDK=/opt/mead-ndk Scripts/build-android-fixtures.sh
set -eu
cd "$(dirname "$0")/.."
ndk=${MEAD_NDK:-/opt/mead-ndk}
sysroot=$ndk/toolchains/llvm/prebuilt/linux-x86_64/sysroot
common="clang-19 --target=aarch64-linux-android35 --sysroot=$sysroot -fuse-ld=lld -fPIC"
out=.build/mead-fixtures
mkdir -p "$out"

# The basic fixture and the library it imports, as NDK builds make them.
$common -shared -Wl,-soname,libfixture_extra.so -o $out/libfixture_extra.so \
    Tests/Fixtures/fixture_extra.c
$common -shared -Wl,-soname,libfixture_basic.so -o $out/libfixture_basic.so \
    Tests/Fixtures/fixture_basic.c $out/libfixture_extra.so

# TLS, both models: descriptors (the default) and initial-exec.
$common -shared -Wl,-soname,libfixture_tls.so -o $out/libfixture_tls.so \
    -ftls-model=global-dynamic Tests/Fixtures/fixture_tls.c
$common -shared -Wl,-soname,libfixture_tls_ie.so -o $out/libfixture_tls_ie.so \
    -ftls-model=initial-exec Tests/Fixtures/fixture_tls.c

# The same fixture again with Android's packed relocations, and with RELR.
$common -shared -Wl,-soname,libfixture_packed.so -Wl,--pack-dyn-relocs=android \
    -o $out/libfixture_packed.so Tests/Fixtures/fixture_basic.c $out/libfixture_extra.so
$common -shared -Wl,-soname,libfixture_relr.so -Wl,-z,pack-relative-relocs \
    -o $out/libfixture_relr.so Tests/Fixtures/fixture_basic.c $out/libfixture_extra.so

# libc++_shared.so, the one Android library games ship as a real file, for
# the C++ fixture that throws across its frames.
cp $ndk/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so $out/ 2>/dev/null \
    || true
ls -l $out
