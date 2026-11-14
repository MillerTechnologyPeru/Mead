#!/bin/bash
# Builds mead-framework.jar, Mead's Java for ART (Java/mead-framework): the
# in-process system services, compiled against Android 10's framework and
# dexed for API 29. Mead puts it on ART's boot class path. Beside it,
# mead-backports.jar (Java/mead-backports): framework classes with the
# public methods later Androids added, and what they read of the host,
# which Mead puts on the boot class path ahead of framework.jar.
#
# Usage: build-mead-framework.sh <framework classes.jar> <dx.jar> <output.jar>
# The framework's classes are its compile-time classes.jar from an Android 10
# build (out/target/common/obj/JAVA_LIBRARIES/framework_intermediates). The
# core library's, from core-libart_intermediates, beside it as
# core-libart-classes.jar, are on the classpath too when they're there:
# backported framework classes use dalvik.system and org.xmlpull.
set -eu
framework=$1
dx=$2
output=$3
core="$(dirname "$framework")/core-libart-classes.jar"
classpath="$framework"
[ -f "$core" ] && classpath="$framework:$core"
source=$(cd "$(dirname "$0")/../Java/mead-framework" && pwd)
# Stand-ins for classes the framework's interfaces name from outside its
# classes.jar; compiled against only, never into the jar.
stubs=$(cd "$(dirname "$0")/../Java/mead-framework-stubs" && pwd)
# Android 10's ART can't bootstrap invoke-custom, which dx makes of a
# lambda or method reference; such code needs an anonymous class instead.
# Fails the build on a dex with call sites.
no_call_sites() {
    python3 - "$1" <<'CHECK'
import struct, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as jar:
    for name in jar.namelist():
        if not name.endswith(".dex"):
            continue
        dex = jar.read(name)
        map_off = struct.unpack_from("<I", dex, 52)[0]
        for i in range(struct.unpack_from("<I", dex, map_off)[0]):
            kind, _, size, _ = struct.unpack_from("<HHII", dex, map_off + 4 + 12 * i)
            if kind == 0x0007 and size:
                sys.exit("%s: %s has %d call sites (a lambda or method reference)" % (sys.argv[1], name, size))
CHECK
}
backports_source=$(cd "$(dirname "$0")/../Java/mead-backports" && pwd)
backports_output="$(dirname "$output")/mead-backports.jar"
classes=$(mktemp -d)
backports=$(mktemp -d)
trap 'rm -rf "$classes" "$backports"' EXIT
# The backports first: Mead's framework calls into them.
find "$backports_source" -name '*.java' > "$backports/sources"
javac -encoding UTF-8 -nowarn --release 8 -cp "$classpath" -d "$backports" @"$backports/sources"
rm "$backports/sources"
java -jar "$dx" --dex --min-sdk-version=29 --output="$backports_output" "$backports"
no_call_sites "$backports_output"
# The service bases, generated from the framework's interfaces.
python3 "$(dirname "$0")/generate-service-bases.py" "$framework" "$classes/generated"
find "$source" "$classes/generated" -name '*.java' > "$classes/sources"
javac -encoding UTF-8 -nowarn --release 8 -cp "$backports:$classpath" -sourcepath "$stubs" -implicit:none -d "$classes" @"$classes/sources"
rm -r "$classes/sources" "$classes/generated"
java -jar "$dx" --dex --min-sdk-version=29 --output="$output" "$classes"
no_call_sites "$output"
