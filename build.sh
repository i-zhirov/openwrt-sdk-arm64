#!/bin/sh
set -eu

# Builds the aarch64-host OpenWrt SDK image from the Dockerfile in this
# repository.
#
# The image is produced by building the SDK FROM SOURCE on an arm64 host
# (`make sdk`), because no prebuilt aarch64-host SDK exists anywhere: neither
# downloads.openwrt.org (Linux-x86_64 only) nor the official openwrt/sdk
# containers (every tag is an amd64 image cross-compiling FOR its target).
#
# Requirements:
#   - a Docker daemon that can run/build linux/arm64: an arm64 daemon
#     (Colima with --arch aarch64, Docker Desktop on Apple Silicon, an
#     ubuntu-24.04-arm GitHub runner) or an amd64 daemon with binfmt/QEMU
#     registered (slow — the toolchain build under emulation takes hours).
#   - network access from the build container (apt, git, package downloads).
#
# Usage:
#   ./build.sh [--version 25.12.5] [--target x86/64] [--subtarget 64]
#       [--tag NAME] [--push IMAGE] [--no-kmods] [--allow-qemu]
#       [--smoke] [--package PKG]
#
#   --version    OpenWrt release to build the SDK from (default 25.12.5;
#                22.03.7 is the opkg-generation counterpart).
#   --target     SDK target, slash form "x86/64" or "armsr/armv8"
#                (default x86/64 — the canonical target of the release builds).
#   --subtarget  only used together with a slash-less --target.
#   --tag        image tag (default openwrt-sdk-arm64-<version>).
#   --push       push to IMAGE:<version> (e.g. ghcr.io/me/openwrt-sdk-arm64)
#                instead of just building locally; requires a buildx and a
#                login.
#   --no-kmods   skip the kernel preparation: smaller, faster image that
#                cannot build kernel modules (fine for noarch packages).
#   --allow-qemu build on a non-arm64 daemon anyway (requires binfmt+QEMU;
#                the toolchain build then runs under emulation, hours).
#   --smoke      after the build, run a real package build inside the image:
#                mounts the CURRENT DIRECTORY (an OpenWrt feed repository)
#                as the feed and builds the package given with --package.
#   --package    package for the smoke test (required with --smoke).
#
# Examples:
#   ./build.sh --version 25.12.5 --smoke --package urngd
#   ./build.sh --version 22.03.7 --smoke --package urngd
#   ./build.sh --version 25.12.5 --push ghcr.io/i-zhirov/openwrt-sdk-arm64

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

VERSION=25.12.5
TARGET=""
SUBTARGET=64
TAG=""
PUSH_IMAGE=""
BUILD_KMODS=1
ALLOW_QEMU=0
SMOKE=0
PKG=""

usage() {
    sed -n '4,46p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version)   VERSION=$2; shift 2 ;;
        --target)    TARGET=$2; shift 2 ;;
        --subtarget) SUBTARGET=$2; shift 2 ;;
        --tag)       TAG=$2; shift 2 ;;
        --push)      PUSH_IMAGE=$2; shift 2 ;;
        --no-kmods)  BUILD_KMODS=0; shift ;;
        --allow-qemu) ALLOW_QEMU=1; shift ;;
        --smoke)     SMOKE=1; shift ;;
        --package)   PKG=$2; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# Split a slash-form target ("x86/64" -> TARGET=x86 SUBTARGET=64).
if [ -z "$TARGET" ]; then
    TARGET=x86
elif [ "${TARGET#*/}" != "$TARGET" ]; then
    SUBTARGET=${TARGET#*/}
    TARGET=${TARGET%/*}
fi

: "${TAG:=openwrt-sdk-arm64-$VERSION}"
OPENWRT_REF="v$VERSION"
BUILD_KMODS_ARG=$BUILD_KMODS

# --- Preflight -------------------------------------------------------------
docker info >/dev/null 2>&1 || {
    echo "error: docker daemon is not reachable" >&2
    exit 1
}

# {{.Architecture}} is the daemon's own arch (x86_64 / aarch64); the nested
# {{.Server.Arch}} form renders EMPTY, which would defeat this whole check.
server_arch=$(docker info --format '{{.Architecture}}' 2>/dev/null || true)
case "$server_arch" in
    aarch64|arm64)
        ;;
    *)
        if [ "$ALLOW_QEMU" != 1 ]; then
            cat >&2 <<EOF
error: the docker daemon is $server_arch, but this image is aarch64-only.
Build it on an arm64 daemon — 'colima start --arch aarch64' (restarts the
daemon), Docker Desktop on Apple Silicon, or an ubuntu-24.04-arm runner.
If binfmt+QEMU is registered on this daemon, rerun with --allow-qemu — the
toolchain build then runs under emulation and takes hours.
EOF
            exit 1
        fi
        echo "warning: daemon is $server_arch, building under QEMU emulation — this will be slow" >&2
        ;;
esac

echo "== OpenWrt $VERSION, target $TARGET/$SUBTARGET -> $TAG"

# --- Build -----------------------------------------------------------------
if [ -n "$PUSH_IMAGE" ]; then
    # Two tags: <image>:<version> (the "latest dispatch for this version"
    # alias) and <image>:<version>-<target>-<subtarget> (the specific build,
    # e.g. 22.03.7-armvirt-64). Without the second tag a later dispatch for
    # a different target would silently overwrite the version tag.
    docker buildx build --platform linux/arm64 \
        --build-arg OPENWRT_REF="$OPENWRT_REF" \
        --build-arg TARGET="$TARGET" \
        --build-arg SUBTARGET="$SUBTARGET" \
        --build-arg BUILD_KMODS=$BUILD_KMODS_ARG \
        --push -t "$PUSH_IMAGE:$VERSION" \
        -t "$PUSH_IMAGE:$VERSION-$TARGET-$SUBTARGET" "$SCRIPT_DIR"
    echo "pushed $PUSH_IMAGE:$VERSION (alias) and $PUSH_IMAGE:$VERSION-$TARGET-$SUBTARGET"
else
    docker build --platform linux/arm64 \
        --build-arg OPENWRT_REF="$OPENWRT_REF" \
        --build-arg TARGET="$TARGET" \
        --build-arg SUBTARGET="$SUBTARGET" \
        --build-arg BUILD_KMODS=$BUILD_KMODS_ARG \
        -t "$TAG" "$SCRIPT_DIR"
    echo "built $TAG"
fi

# --- Smoke test ------------------------------------------------------------
if [ "$SMOKE" = 1 ]; then
    [ -n "$PKG" ] || {
        echo "error: --smoke requires --package PKG" >&2
        exit 1
    }
    [ -d packages ] || {
        echo "error: --smoke mounts the current directory as the feed — run from an OpenWrt feed repository root" >&2
        exit 1
    }
    [ -d "packages/$PKG" ] || {
        echo "error: packages/$PKG not found in the current repository" >&2
        exit 1
    }
    [ -n "$PUSH_IMAGE" ] && docker pull "$PUSH_IMAGE:$VERSION" >/dev/null

    IMG=${PUSH_IMAGE:+$PUSH_IMAGE:$VERSION}
    IMG=${IMG:-$TAG}

    rm -rf out
    mkdir -p out
    chmod 777 out

    echo "== smoke test: building $PKG with $IMG"
    # Same interface gh-action-sdk uses: the feed is the whole repository
    # (absolute path — a relative one would be treated as a docker VOLUME
    # NAME and arrive empty), the artifacts land in out/.
    docker run --rm \
        -e PACKAGES="$PKG" \
        -e FEEDNAME=myfeed \
        -v "$(pwd):/feed" \
        -v "$(pwd)/out:/artifacts" \
        "$IMG"

    if find out/bin -name "$PKG*" | grep -q .; then
        echo "== smoke test ok:"
        find out/bin -name "$PKG*" -print
    else
        echo "error: smoke test produced no $PKG artifacts in out/bin" >&2
        exit 1
    fi
fi
