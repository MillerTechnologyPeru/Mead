#!/bin/bash
# Builds mead-framework.jar, Mead's Java for ART (Java/mead-framework): the
# in-process system services, compiled against Android 10's framework and
# dexed for API 29. Mead puts it on ART's boot class path.
#
# Usage: build-mead-framework.sh <framework classes.jar> <dx.jar> <output.jar>
# The framework's classes are its compile-time classes.jar from an Android 10
# build (out/target/common/obj/JAVA_LIBRARIES/framework_intermediates).
set -eu
framework=$1
dx=$2
output=$3
source=$(cd "$(dirname "$0")/../Java/mead-framework" && pwd)
classes=$(mktemp -d)
trap 'rm -rf "$classes"' EXIT
# The service bases, generated from the framework's interfaces.
python3 "$(dirname "$0")/generate-service-bases.py" "$framework" "$classes/generated"
find "$source" "$classes/generated" -name '*.java' > "$classes/sources"
javac -encoding UTF-8 -nowarn --release 8 -cp "$framework" -d "$classes" @"$classes/sources"
rm -r "$classes/sources" "$classes/generated"
java -jar "$dx" --dex --min-sdk-version=29 --output="$output" "$classes"
