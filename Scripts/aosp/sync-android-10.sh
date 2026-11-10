#!/bin/sh
# Checks out Android 10 (android-security-10.0.0_r75, the release Mead's ART
# is on) into the current directory: the default projects only, without
# devices' or other hosts', and without history, to keep it small.
set -eu
tag=android-security-10.0.0_r75
repo init -u https://android.googlesource.com/platform/manifest -b "$tag" \
    --depth=1 -g default,-device,-darwin,-mips
repo sync -c -j"${JOBS:-4}" --no-tags --no-clone-bundle --optimized-fetch
