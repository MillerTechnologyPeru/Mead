#!/bin/sh
# Checks the JNI function tables against the NDK, in two ways: that Mead's
# table has every entry in the NDK's order, and that the conformance fixture
# calls each of them. Run it in the Docker image.
# Usage: MEAD_NDK=/opt/mead-ndk Scripts/check-jni-conformance.sh
set -eu
cd "$(dirname "$0")/.."
ndk=${MEAD_NDK:-/opt/mead-ndk}
toolchain=$ndk/toolchains/llvm/prebuilt/linux-x86_64
android="clang-19 --target=aarch64-linux-android35 --sysroot=$toolchain/sysroot -resource-dir=$toolchain/lib/clang/19"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The members of a struct in preprocessed source, in order.
members() {
    awk -v name="$1" '$0 ~ "^struct " name "( |$)" { on = 1 } on { print } on && /^};/ { exit }' \
        | tr -d '\n' | grep -oE '\(\*[A-Za-z]+\)|reserved[0-9]' | tr -d '(*)'
}

printf '#include <jni.h>\n' > "$work/ndk.c"
$android -E "$work/ndk.c" > "$work/ndk.i"
clang-19 -E -ISources/CMeadJNI/include -include Sources/CMeadJNI/include/jni.h -x c /dev/null > "$work/mead.i"

for table in JNINativeInterface JNIInvokeInterface; do
    members $table < "$work/ndk.i" > "$work/ndk-$table"
    members $table < "$work/mead.i" > "$work/mead-$table"
    if ! diff "$work/ndk-$table" "$work/mead-$table"; then
        echo "$table differs from the NDK's" >&2
        exit 1
    fi
    echo "$table: $(wc -l < "$work/ndk-$table") entries, in the NDK's order"
done

# Every entry must appear in the fixture once its macros are expanded.
$android -E Tests/Fixtures/fixture_jni.c > "$work/fixture.i"
missing=0
for name in $(cat "$work/ndk-JNINativeInterface" "$work/ndk-JNIInvokeInterface" | grep -v '^reserved'); do
    if ! grep -qE -- "->$name\b" "$work/fixture.i"; then
        echo "the conformance fixture never touches $name" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || exit 1
echo "the conformance fixture touches every entry"
