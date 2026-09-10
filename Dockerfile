# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# aarch64-host OpenWrt SDK image
#
# downloads.openwrt.org publishes SDK tarballs for Linux x86_64 hosts only,
# and every official openwrt/sdk image (whatever its <target> tag) is an
# amd64 image that cross-compiles FOR that target. This Dockerfile builds the
# SDK FROM SOURCE on an aarch64 host — `make sdk`, the same machinery the
# OpenWrt buildbot uses — so the result is a container that RUNS natively on
# Apple Silicon and arm64 CI runners instead of through Rosetta/QEMU.
#
# The final image mirrors the official openwrt/sdk layout (the SDK extracted
# into /builder, the gh-action-sdk /entrypoint.sh, the buildbot user with
# uid 1000), so it is a DROP-IN replacement: the same
#
#   docker run --rm -e PACKAGES=... -e FEEDNAME=... \
#     -v repo:/feed -v out:/artifacts <image>
#
# invocation that openwrt/gh-action-sdk uses against openwrt/sdk works
# against this image unchanged.
#
# Build it with build.sh, or manually:
#
#   docker build --platform linux/arm64 \
#     --build-arg OPENWRT_REF=v25.12.5 \
#     -t sdk-arm64-25.12.5 .
# ---------------------------------------------------------------------------

# Ubuntu 24.04 (glibc 2.39, gcc-13). The base must be a glibc < 2.36-free
# host for OpenWrt's bundled tools: on Debian 12 (glibc 2.36, gcc-12)
# tools/sed 4.9 fails to compile ('FLEXIBLE_ARRAY_MEMBER undeclared', verified
# by reproduction) — the fix (sed 4.10) is not in the v25.12.5 tree. Ubuntu
# 24.04 is also exactly what the arm64 GitHub runners run, so local and CI
# builds see the same host. LTS until 2029. Pinned by digest for
# reproducibility.
ARG BASE_IMAGE=ubuntu:24.04@sha256:ec0b1c9058e44c837a21c3f9d8a3d5e9aaa94ed28edceb18e154af5efecf0950

# The OpenWrt source to build the SDK from: a release tag (v25.12.5, v22.03.7)
# or a branch (openwrt-25.12, main). The SDK tarball is named from this
# checkout (VERSION_NUMBER) and its feeds.conf.default from the BASE_FEED.
ARG OPENWRT_REF=v25.12.5

# The SDK's target is only the CROSS-COMPILE target the SDK packages for; for
# noarch packages any target works and only affects the toolchain build time.
# The default (x86/64) is the canonical target of the OpenWrt release builds.
ARG TARGET=x86
ARG SUBTARGET=64

# 1 = run `make target/linux/prepare` so the SDK ships the kernel sources and
# can build kmods out of the box (faithful to the official SDKs); 0 = skip it
# — smaller, faster, still fine for noarch and userspace packages.
ARG BUILD_KMODS=1

# The gh-action-sdk ref the entrypoint is taken from. Keep in sync with the
# `openwrt/gh-action-sdk` pins used in workflows that consume this image.
ARG ACTION_REF=v7

# ---------------------------------------------------------------------------
# Stage 1: build the SDK tarball from source
# ---------------------------------------------------------------------------
# The --platform=linux/arm64 constants are deliberate (the linter calls them
# "const disallowed"): an image that is not arm64 is useless for its purpose,
# so a build without --platform must FAIL loudly instead of silently producing
# an amd64 image. The build command passes the same platform.
FROM --platform=linux/arm64 ${BASE_IMAGE} AS sdk-builder

ARG OPENWRT_REF
ARG TARGET
ARG SUBTARGET
ARG BUILD_KMODS
ARG ACTION_REF

# The apt package set (OpenWrt build guide's Debian list plus what the SDK
# needs at runtime: it compiles packages against the included toolchain).
# An ENV, not an ARG: multi-word values in ARG defaults are parsed
# unreliably, and the set is not meant to be overridden.
ENV BUILD_DEPS="build-essential ccache curl file flex bison gawk gettext git ca-certificates libncurses-dev libssl-dev python3 python3-setuptools rsync subversion swig unzip wget xz-utils zstd time locales zlib1g-dev"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# The builder runs as root (Docker default), and GNU tar 1.35's configure
# refuses to run as root ("you should not run configure as root", verified by
# reproduction). The official buildbot never hits this because it builds as
# the buildbot user; for a root container build the bypass is documented by
# the OpenWrt build guide.
ENV FORCE_UNSAFE_CONFIGURE=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends ${BUILD_DEPS} \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /builder

# The entrypoint, cloned separately so it can be copied into the final stage.
RUN git clone --depth 1 --branch "${ACTION_REF}" \
        https://github.com/openwrt/gh-action-sdk action

# Shallow clone at the release tag. The SDK's feeds.conf.default (BASE_FEED)
# and the i18n package versioning (luci.mk findrev) derive from this checkout,
# so the tag must end up in the refs.
RUN git clone --depth 1 --branch "${OPENWRT_REF}" \
        https://github.com/openwrt/openwrt.git sdk-src

WORKDIR /builder/sdk-src

# Preselect the target and subtarget non-interactively: CONFIG_TARGET_<target>
# selects the target, CONFIG_TARGET_<target>_<subtarget> the subtarget.
RUN printf 'CONFIG_TARGET_%s=y\nCONFIG_TARGET_%s_%s=y\n' \
        "${TARGET}" "${TARGET}" "${SUBTARGET}" > .config \
    && make defconfig

# A bogus target would otherwise surface only as a missing tarball much later.
RUN grep -qx "CONFIG_TARGET_${TARGET}_${SUBTARGET}=y" .config \
    || { echo "target ${TARGET}/${SUBTARGET} does not exist in OpenWrt ${OPENWRT_REF}" >&2; exit 1; }

# The two ingredients of an SDK: host tools and the cross toolchain for the
# target, both built for THIS host (aarch64). This is the long step — roughly
# an hour on a 4-core arm64.
RUN make tools/install toolchain/install -j"$(nproc)"

# Kernel sources: only needed for kmod builds inside the SDK.
RUN if [ "${BUILD_KMODS}" = "1" ]; then make target/linux/prepare -j"$(nproc)"; fi

# Produce the SDK tarball:
#   bin/openwrt-sdk-<version>-<target>_gcc-<ver>_musl.Linux-aarch64.tar.zst  (25.12+)
#   bin/openwrt-sdk-<version>-<target>_gcc-<ver>_musl.Linux-aarch64.tar.xz   (22.03)
RUN make sdk

# ---------------------------------------------------------------------------
# Stage 2: the final image — the official layout, with the SDK baked in
# ---------------------------------------------------------------------------
FROM --platform=linux/arm64 ${BASE_IMAGE}

ARG OPENWRT_REF
ARG TARGET
ARG SUBTARGET
ENV BUILD_DEPS="build-essential ccache curl file flex bison gawk gettext git ca-certificates libncurses-dev libssl-dev python3 python3-setuptools rsync subversion swig unzip wget xz-utils zstd time locales zlib1g-dev"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# Kept in the final stage too, so even a `docker run -u root` of the image
# can build packages that run configure (tar-style root checks).
ENV FORCE_UNSAFE_CONFIGURE=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends ${BUILD_DEPS} \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# uid 1000 is the contract with gh-action-sdk: the action chowns the mounted
# /feed and /artifacts to 1000:1000 before starting the container.
RUN useradd --create-home --uid 1000 --shell /bin/bash buildbot

COPY --from=sdk-builder /builder/sdk-src/bin/openwrt-sdk-*.tar.* /tmp/sdk/
COPY --from=sdk-builder /builder/action/entrypoint.sh /entrypoint.sh

# The SDK IS the /builder working directory, exactly like the official images
# (their setup.sh extracts with --strip=1 into /builder). No setup.sh ships
# here — the SDK is baked in, so the gh-action-sdk entrypoint skips its
# download-on-first-run step.
RUN chmod 0755 /entrypoint.sh \
    && mkdir -p /builder \
    && tar -xf /tmp/sdk/openwrt-sdk-*.tar.* --strip=1 -C /builder \
    && rm -rf /tmp/sdk \
    && chown -R buildbot:buildbot /builder

USER buildbot
WORKDIR /builder

LABEL org.opencontainers.image.title="OpenWrt SDK (aarch64 host)"
LABEL org.opencontainers.image.description="OpenWrt SDK built natively for aarch64 hosts (target ${TARGET}/${SUBTARGET})"
LABEL org.opencontainers.image.version="${OPENWRT_REF}"
LABEL org.opencontainers.image.source="https://github.com/i-zhirov/openwrt-sdk-arm64"

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]
