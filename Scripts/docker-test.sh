#!/bin/sh
# Builds and tests Mead in an arm64 Linux container.
# Usage: Scripts/docker-test.sh [swift test arguments...]
# Linux build products go to .build/linux so they never mix with a macOS
# build; Android fixtures stay in .build/mead-fixtures, shared with the Mac.
set -eu
cd "$(dirname "$0")/.."
image=mead-dev
docker build --platform linux/arm64 -t "$image" .
exec docker run --rm --platform linux/arm64 \
    -v "$PWD:/mead" \
    "$image" \
    sh -c 'cd /mead && Scripts/gate.sh "$@"' sh "$@"
