#!/bin/bash
# Generates Sources/CMeadWayland's protocol glue with wayland-scanner, from
# wayland-protocols' XML (in the build image, /usr/share/wayland-protocols):
# each protocol's client header (requests as inline functions, listeners)
# and its interface tables. Run it in the build image after changing the
# protocols ART's display bridge uses; the output is committed.
#
# Usage: Scripts/generate-wayland-protocols.sh
set -eu
cd "$(dirname "$0")/.."
protocols=/usr/share/wayland-protocols
target=Sources/CMeadWayland
mkdir -p "$target/include"
for xml in \
    stable/xdg-shell/xdg-shell.xml \
    stable/viewporter/viewporter.xml \
    unstable/xdg-decoration/xdg-decoration-unstable-v1.xml \
    unstable/idle-inhibit/idle-inhibit-unstable-v1.xml
do
    name=$(basename "$xml" .xml)
    wayland-scanner client-header "$protocols/$xml" "$target/include/$name-client-protocol.h"
    wayland-scanner private-code "$protocols/$xml" "$target/$name-protocol.c"
done
echo "wayland-protocols $(dpkg-query -W -f='${Version}' wayland-protocols), $(wayland-scanner --version 2>&1)" \
    > "$target/GENERATED_FROM"
