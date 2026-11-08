#!/bin/sh
# Cross-builds the loader's Android test fixtures: ELF aarch64 .so files,
# built with Debian's clang and lld against the NDK's sysroot (the NDK's own
# tools are x86_64 binaries and cannot run on arm64). Mead's tests load
# them, unmodified, in Docker.
# Usage: MEAD_NDK=/opt/mead-ndk Scripts/build-android-fixtures.sh
set -eu
cd "$(dirname "$0")/.."
ndk=${MEAD_NDK:-/opt/mead-ndk}
toolchain=$ndk/toolchains/llvm/prebuilt/linux-x86_64
# Debian's clang, on the NDK's runtime and libraries: the NDK's own tools
# are x86_64 binaries and cannot run on arm64.
common="clang-19 --target=aarch64-linux-android35 --sysroot=$toolchain/sysroot -resource-dir=$toolchain/lib/clang/19 --rtlib=compiler-rt -fuse-ld=lld -fPIC"
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

# The linker falls back without saying so; these fixtures are only worth
# their names if the tables are really there.
readelf -d $out/libfixture_packed.so | grep -qE 'ANDROID_RELA|0x0*60000011 ' \
    || { echo "libfixture_packed.so has no packed relocations" >&2; exit 1; }
readelf -d $out/libfixture_relr.so | grep -qE '\(RELR\)|ANDROID_RELR|0x0*24 ' \
    || { echo "libfixture_relr.so has no RELR relocations" >&2; exit 1; }

# Aligned for 16 KB pages, as Android 15 devices want, on a 4 KB-page host.
$common -shared -Wl,-soname,libfixture_16k.so -Wl,-z,max-page-size=16384 \
    -o $out/libfixture_16k.so Tests/Fixtures/fixture_basic.c $out/libfixture_extra.so

# A root and the library it needs, for initialization order.
$common -shared -Wl,-soname,libfixture_order_leaf.so -o $out/libfixture_order_leaf.so \
    Tests/Fixtures/fixture_order_leaf.c
$common -shared -Wl,-soname,libfixture_order_root.so -o $out/libfixture_order_root.so \
    Tests/Fixtures/fixture_order_root.c $out/libfixture_order_leaf.so

# libc++_shared.so, the one Android library games ship as a real file, for
# the C++ fixtures that throw across its frames.
cp $toolchain/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so $out/

# The selftests mead --selftest runs: bionic's ABI from C, built with
# fortify as NDK apps are, and C++ exceptions across two libraries.
$common -O2 -D_FORTIFY_SOURCE=2 -shared -Wl,-soname,libfixture_bionic.so \
    -o $out/libfixture_bionic.so Tests/Fixtures/fixture_bionic.c -llog -ldl
# The JNI conformance suite, compiled against the NDK's jni.h. Its JNI
# entry points are left for libart.so's provider to answer.
$common -O1 -shared -Wl,-soname,libfixture_jni.so -o $out/libfixture_jni.so \
    Tests/Fixtures/fixture_jni.c

# As NDK builds do: libunwind goes into each library, statically.
cxx="$(echo "$common" | sed 's/^clang-19/clang++-19/') --unwindlib=libunwind"
$cxx -nostdlib++ -shared -Wl,-soname,libfixture_cxx_thrower.so \
    -o $out/libfixture_cxx_thrower.so Tests/Fixtures/fixture_cxx_thrower.cpp \
    $out/libc++_shared.so
$cxx -nostdlib++ -shared -Wl,-soname,libfixture_cxx.so \
    -o $out/libfixture_cxx.so Tests/Fixtures/fixture_cxx.cpp $out/libfixture_cxx_thrower.so \
    $out/libc++_shared.so -lz
ls -l $out
