#!/bin/sh
# Prints where bionic's libc ABI and glibc's differ on arm64: the probe built
# against each, run, and diffed (< bionic, > glibc). Run it in the Docker
# image, where a statically linked Android binary runs as any other.
# Usage: MEAD_NDK=/opt/mead-ndk Scripts/compare-bionic-abi.sh
set -eu
cd "$(dirname "$0")/.."
ndk=${MEAD_NDK:-/opt/mead-ndk}
toolchain=$ndk/toolchains/llvm/prebuilt/linux-x86_64
out=.build/mead-fixtures
mkdir -p "$out"
clang-19 --target=aarch64-linux-android35 --sysroot=$toolchain/sysroot \
    -resource-dir=$toolchain/lib/clang/19 --rtlib=compiler-rt -fuse-ld=lld -static \
    -o $out/abi_probe_bionic Tests/Fixtures/abi_probe.c
clang-19 -o $out/abi_probe_glibc Tests/Fixtures/abi_probe.c
$out/abi_probe_bionic > $out/abi_bionic.txt
$out/abi_probe_glibc > $out/abi_glibc.txt
wc -l $out/abi_bionic.txt $out/abi_glibc.txt
diff $out/abi_bionic.txt $out/abi_glibc.txt || true
