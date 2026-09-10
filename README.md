# OpenWrt SDK — native aarch64-host containers

Multi-stage Dockerfile, build script and GitHub Actions workflow that produce
the **OpenWrt SDK built from source for an aarch64 host** and package it as a
container that runs natively on Apple Silicon and arm64 CI runners — no
Rosetta, no QEMU.

The images are **drop-in replacements** for the official `openwrt/sdk`
containers: same `/builder` layout, same `openwrt/gh-action-sdk`
entrypoint, same uid-1000 buildbot user. The exact `docker run` invocation
that the OpenWrt SDK action uses against `openwrt/sdk` works against these
images unchanged.

Published images (built on arm64 GitHub runners):

| Image | OpenWrt | Package manager |
|---|---|---|
| `ghcr.io/i-zhirov/sdk-arm64:25.12.5` | 25.12.5 | apk |
| `ghcr.io/i-zhirov/sdk-arm64:22.03.7` | 22.03.7 | opkg |

Every dispatch also pushes a target-specific tag,
`<version>-<target>-<subtarget>` (e.g. `22.03.7-armvirt-64`,
`25.12.5-x86-64`), so builds for different targets never overwrite each
other; the bare version tag is an alias of the most recent dispatch for
that version. Any other version and target can be built on demand (see
below).

## Why this exists

Upstream OpenWrt publishes SDKs for **Linux x86_64 hosts only**:

- the SDK tarballs on downloads.openwrt.org are all
  `openwrt-sdk-…-Linux-x86_64.tar.zst` / `.tar.xz` — the host architecture is
  baked into the file name;
- every official `openwrt/sdk:<target>` image tag names the *cross-compile
  target* the SDK packages for; the image itself is always `amd64`
  (e.g. `openwrt/sdk:aarch64_cortex-a53-25.12.5` has platform `amd64/linux`).

On an arm64 Mac or runner those images only run under emulation
(Rosetta/QEMU), which makes every package-build iteration slow. The
alternative implemented here: build the SDK yourself on an arm64 host with the
same machinery the OpenWrt buildbot uses — `make sdk` — and containerize the
result.

## How it works

The Dockerfile is multi-stage:

1. **`sdk-builder`** (runs as root inside the build): installs the build
   dependencies on `ubuntu:24.04` (arm64, pinned by digest), clones
   `openwrt/openwrt` at the requested tag, preselects the target/subtarget and
   `CONFIG_SDK=y` via `defconfig`, then runs:
   - `make tools/install toolchain/install` — host tools and the cross
     toolchain, both built for aarch64;
   - `make target/linux/prepare` — kernel sources, so the SDK can build kmods
     (skip with `BUILD_KMODS=0`);
   - `make target/sdk/compile` — the SDK tarball
     (`bin/targets/<board>/<subtarget>/openwrt-sdk-…-Linux-aarch64.tar.zst`).
2. **Final stage**: the SDK is extracted into `/builder` (the official
   layout), the `gh-action-sdk` entrypoint is installed, and the buildbot user
   (uid 1000 — the gh-action-sdk contract) is created. No `setup.sh`: the SDK
   is baked in, so the entrypoint skips its download-on-first-run step.

### Gotchas baked into the recipe (each verified by reproduction)

- **Base image**: Debian 12 breaks OpenWrt's bundled `tools/sed` 4.9
  (`FLEXIBLE_ARRAY_MEMBER undeclared` on glibc 2.36/gcc-12; the sed 4.10 fix
  is not backported to the release tags). `ubuntu:24.04` builds it fine and
  matches the arm64 GitHub runners' host, so local and CI builds see the same
  environment.
- **`FORCE_UNSAFE_CONFIGURE=1`**: GNU tar's configure refuses to run as root,
  and the builder stage runs as root (the official buildbot builds as uid
  1000 and never hits this). The flag is the documented bypass and is kept in
  the final stage too, so even `docker run -u root` can build packages.
- **`CONFIG_TARGET_<target>` / `CONFIG_TARGET_<target>_<subtarget>` seeding**:
  `defconfig` needs the target preselected non-interactively.
- **`make target/sdk/compile`, not `make sdk`**: the bare `sdk` alias no
  longer exists in the OpenWrt tree ("No rule to make target 'sdk'").
- **`bin/targets/<board>/<subtarget>/`**: the SDK tarball lands in the
  per-target output directory (`BIN_DIR`), not `bin/`.
- **uid 1000**: Ubuntu's base image already owns it (the `ubuntu` user), so
  it is removed before the buildbot user is created.

## Usage

### Pull and run (the drop-in interface)

```sh
docker pull ghcr.io/i-zhirov/sdk-arm64:25.12.5

docker run --rm \
  -e PACKAGES=luci-app-trusttunnel \
  -e FEEDNAME=ttowrt \
  -v "$PWD:/feed" \
  -v "$PWD/out:/artifacts" \
  ghcr.io/i-zhirov/sdk-arm64:25.12.5
```

The built packages land in `out/bin`. Requires an arm64 Docker daemon
(Colima with `--arch aarch64`, Docker Desktop on Apple Silicon) — on an
amd64 daemon the image cannot run natively.

### Build an image locally

```sh
./build.sh --version 25.12.5 --smoke --package luci-app-trusttunnel
./build.sh --version 22.03.7
./build.sh --version 25.12.5 --target armsr/armv8
./build.sh --version 25.12.5 --push ghcr.io/i-zhirov/sdk-arm64
```

Options: `--version` (default 25.12.5), `--target x86/64` (default; any
OpenWrt target, slash form), `--subtarget`, `--tag`, `--push IMAGE`,
`--no-kmods`, `--allow-qemu` (slow, requires binfmt), `--smoke` + `--package`
(builds a real package from the current directory as the feed, exactly like
the SDK action does). `./build.sh --help` for details.

### Build on GitHub Actions (no local arm64 daemon needed)

```sh
gh workflow run sdk-arm64.yml -f version=25.12.5
gh workflow run sdk-arm64.yml -f version=22.03.7 -f target=armvirt/64
gh workflow run sdk-arm64.yml -f version=25.12.5 -f target=armsr/armv8
```

The workflow runs on a native arm64 runner (`ubuntu-24.04-arm`) and pushes
the image to `ghcr.io/<owner>/sdk-arm64:<version>`.

## Targets

The SDK's target is only the architecture it cross-compiles *for*; for
noarch packages any target works and only affects the toolchain build time.
The default `x86/64` matches the canonical OpenWrt release builds. Note the
target naming changed between generations: the generic aarch64 target is
`armvirt/64` on 22.03 (its arch label is `aarch64_generic` — the same SDK
the official `aarch64_generic-22.03.7` image tag refers to) and `armsr/armv8`
on 25.12. A target that does not exist in the chosen OpenWrt version fails
fast with a clear error from the defconfig assertion.

## Files

- `Dockerfile` — the multi-stage build (see "How it works").
- `build.sh` — local build script: preflight (arm64 daemon check), build or
  `--push`, optional `--smoke` package build.
- `.github/workflows/sdk-arm64.yml` — dispatch workflow for arm64 runners.

## Requirements

- A Docker daemon that can build/run `linux/arm64`: an arm64 daemon
  (recommended), or an amd64 daemon with binfmt/QEMU registered
  (`--allow-qemu`; the toolchain build then takes hours under emulation).
- Network access from the build container (apt, git, package downloads).
