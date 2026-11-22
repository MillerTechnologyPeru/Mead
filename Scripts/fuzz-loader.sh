#!/bin/sh
# Fuzzes the loader's ELF parsing (Tests/Fuzz/loader_fuzz.c) with libFuzzer,
# AddressSanitizer and UndefinedBehaviorSanitizer.
# Usage: Scripts/fuzz-loader.sh [libFuzzer arguments...]
#   Scripts/fuzz-loader.sh -max_total_time=600
# CC is a clang with libFuzzer (Swift's toolchain has one). The corpus is
# kept in .build/fuzz/corpus, seeded from MEAD_FUZZ_SEEDS (a folder of arm64
# Android libraries) when that is set; crashes are written to .build/fuzz.
set -eu
cd "$(dirname "$0")/.."
: "${CC:=clang}"
out=.build/fuzz
mkdir -p "$out/corpus"
core=Sources/MeadLoaderCore
# Every loader source but mead_log.c, which the harness stands in for.
sources=$(ls $core/*.c | grep -v '/mead_log\.c$')
$CC -g -O1 -fno-omit-frame-pointer -fsanitize=fuzzer,address,undefined \
    -fno-sanitize-recover=undefined \
    -I$core/include -ISources/MeadInterface/include \
    Tests/Fuzz/loader_fuzz.c $sources Sources/MeadInterface/mead_interface.c \
    -o "$out/loader_fuzz"
if [ -n "${MEAD_FUZZ_SEEDS:-}" ]; then
    cp -n "$MEAD_FUZZ_SEEDS"/* "$out/corpus/" 2>/dev/null || true
fi
# Mapped images are released as each input ends, but address space still
# fragments: leak detection is off, as the loader's registries (the missing
# list, the stubs) live for the process by design.
exec env ASAN_OPTIONS=detect_leaks=0:allocator_may_return_null=1 \
    "$out/loader_fuzz" -artifact_prefix="$out/" -max_len=65536 -timeout=10 -rss_limit_mb=4096 \
    "$@" "$out/corpus"
