#!/bin/bash
# Builds Android 10's Java for Mead on ART in an Android 10 tree (run inside
# Scripts/aosp/Dockerfile's image, from the tree's top): the boot class path
# and the framework, as dex jars, gathered into out/mead-java. Dex doesn't
# depend on the CPU, so these are the jars Android 10 ships.
set -eu
# Android 10's boot class path, as build/make/core/envsetup.mk and
# target/product/base_system.mk list it (ICU4J is inside core-libart until
# Android 11).
modules="core-oj core-libart okhttp bouncycastle apache-xml conscrypt framework ext telephony-common voip-common ims-common updatable-media android.test.base"
# Device projects aren't checked out, and some generic ones refer to
# them; nothing built here needs them.
export ALLOW_MISSING_DEPENDENCIES=true
# AOSP's setup reads variables it never sets.
set +u
source build/envsetup.sh
lunch aosp_arm64-eng
m -j"${JOBS:-4}" $modules
set -u

out=out/mead-java
mkdir -p "$out"
for module in $modules; do
    jar=$(find out/target/product/generic_arm64 -name "$module.jar" -path "*/framework/*" | head -1)
    if [ -z "$jar" ]; then
        jar=$(find out/target/common/obj/JAVA_LIBRARIES/${module}_intermediates -name "javalib.jar" | head -1)
    fi
    [ -n "$jar" ] || { echo "no jar for $module" >&2; exit 1; }
    cp "$jar" "$out/$module.jar"
done
ls -l "$out"
