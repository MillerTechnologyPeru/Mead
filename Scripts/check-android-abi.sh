#!/bin/sh
# Checks Mead's copies of other people's layouts: SDL3's event structures
# against SDL's own headers, and ANativeActivity's callbacks against the
# NDK's. Run it in the Docker image.
# Usage: MEAD_NDK=/opt/mead-ndk Scripts/check-android-abi.sh
set -eu
cd "$(dirname "$0")/.."
ndk=${MEAD_NDK:-/opt/mead-ndk}
toolchain=$ndk/toolchains/llvm/prebuilt/linux-x86_64
android="clang-19 --target=aarch64-linux-android35 --sysroot=$toolchain/sysroot -resource-dir=$toolchain/lib/clang/19"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

clang-19 -fsyntax-only -ISources/CMeadWindow/include Tests/Fixtures/sdl_abi_check.c
echo "mead_sdl.h agrees with SDL3's headers"

callbacks() {
    awk '/^typedef struct ANativeActivityCallbacks \{/ { on = 1 } on { print } on && /^\} ANativeActivityCallbacks;/ { exit }' \
        | tr -d '\n' | sed -E 's/\/\*[^*]*\*+([^/*][^*]*\*+)*\///g' | grep -oE '\(\*[ _A-Za-z]*[A-Za-z]+\)' | tr -d '(* )' | sed 's/_Nullable//; s/_Nonnull//'
}

printf '#include <android/native_activity.h>\n' > "$work/ndk.c"
$android -E "$work/ndk.c" | callbacks > "$work/ndk"
clang-19 -E -ISources/CMeadJNI/include -include Sources/CMeadAndroid/include/mead_android.h -x c /dev/null | callbacks > "$work/mead"
diff "$work/ndk" "$work/mead"
echo "ANativeActivityCallbacks: $(wc -l < "$work/ndk") entries, in the NDK's order"
