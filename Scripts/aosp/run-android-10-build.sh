#!/bin/sh
# Runs build-android-10-java.sh in Scripts/aosp/Dockerfile's image (tagged
# mead-aosp10) over the Android 10 tree in $1, as the calling user, detached.
# Follow it with: docker logs -f mead-aosp10-build
set -eu
tree=$(cd "$1" && pwd)
cp "$(dirname "$0")/build-android-10-java.sh" "$tree/"
docker rm -f mead-aosp10-build >/dev/null 2>&1 || true
# The host's users, so that the build can look up who it runs as.
docker run -d --name mead-aosp10-build --user "$(id -u):$(id -g)" \
    -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro \
    -e HOME=/aosp/out/mead-home -e JOBS="${JOBS:-4}" -v "$tree:/aosp" \
    mead-aosp10 bash -c "mkdir -p /aosp/out/mead-home && ./build-android-10-java.sh"
