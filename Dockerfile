# arm64 Linux environment for building and testing Mead.
# The NDK's own tools are x86_64 binaries and cannot run on arm64, so
# fixtures are cross-built with Debian's clang and lld against the NDK's
# sysroot, which is host-independent; sdkmanager checks the NDK's checksums
# itself, so no checksum is pinned here. binutils' readelf and nm back
# mead --report.
FROM swift:6.4-trixie

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        clang-19 lld-19 \
        openjdk-21-jre-headless unzip binutils curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ENV ANDROID_HOME=/opt/android-sdk
# The newest NDK r28. sdkmanager --list is slow but keeps this honest about
# which r28 build is current instead of pinning a build number by hand.
RUN curl -fsSLo /tmp/tools.zip \
        https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
 && mkdir -p $ANDROID_HOME/cmdline-tools \
 && unzip -q /tmp/tools.zip -d $ANDROID_HOME/cmdline-tools \
 && mv $ANDROID_HOME/cmdline-tools/cmdline-tools $ANDROID_HOME/cmdline-tools/latest \
 && yes | $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --sdk_root=$ANDROID_HOME --licenses > /dev/null \
 && NDK=$($ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --list \
        | tr ' ' '\n' | grep '^ndk;28\.' | sort -uV | tail -1) \
 && test -n "$NDK" \
 && $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --sdk_root=$ANDROID_HOME "$NDK" > /dev/null \
 && ln -s $ANDROID_HOME/ndk/* /opt/mead-ndk \
 && rm -rf /root/.android /tmp/tools.zip $ANDROID_HOME/.temp

ENV MEAD_NDK=/opt/mead-ndk

# SDL3 for windows and input: the library, and the headers its layouts are
# checked against.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsdl3-0 libsdl3-dev \
 && rm -rf /var/lib/apt/lists/*
