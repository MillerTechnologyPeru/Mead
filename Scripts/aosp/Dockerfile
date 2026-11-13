# Android 10's build environment: AOSP's build system of that release wants
# Ubuntu 18.04's tools (python 2 among them). Used on an x86_64 host to build
# the release's Java (dex) for Mead on ART; see Documentation/ART-Plan.md.
FROM ubuntu:18.04

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        git-core gnupg flex bison build-essential zip unzip curl zlib1g-dev \
        gcc-multilib g++-multilib libc6-dev-i386 libncurses5 lib32ncurses5-dev \
        x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils \
        xsltproc fontconfig python python3 rsync ca-certificates locales \
    && rm -rf /var/lib/apt/lists/* \
    && locale-gen en_US.UTF-8

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 USER=aosp
WORKDIR /aosp
