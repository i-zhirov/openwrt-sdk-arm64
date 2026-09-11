#!/bin/sh
set -eu

# Generates the release matrix for one OpenWrt version, mirroring the
# official openwrt/sdk matrix: every (target, subtarget) pair that has an
# SDK (computed with the same scripts/dump-target-info.pl the official
# openwrt/docker workflow uses), plus the arch-alias marking: the FIRST
# target of each arch is the row whose build also gets the <arch>-<version>
# tag (exactly like openwrt/docker's containers.yml).
#
# Usage: generate-matrix.sh <version> [target-filter]
#   version        OpenWrt release, e.g. 25.12.5 (v-prefix is added)
#   target-filter  optional comma-separated exact "target/subtarget" list
#                  (e.g. "x86/64,armsr/armv8") — used by the single-build
#                  workflow; within the filter the first row of each arch
#                  still gets the arch alias.
#
# Emits a GitHub Actions matrix JSON on stdout:
#   {"include":[
#     {"version":"25.12.5","target":"armsr","subtarget":"armv8",
#      "arch":"aarch64_generic","arch_alias":"aarch64_generic"},
#     {"version":"25.12.5","target":"x86","subtarget":"64",
#      "arch":"x86_64","arch_alias":"x86_64"},
#     {"version":"25.12.5","target":"mvebu","subtarget":"cortexa9",
#      "arch":"arm_cortex-a9_vfpv3-d16","arch_alias":""}, ...
#   ]}
# arch_alias is the arch label for the first row of each arch (the row whose
# build also gets the <arch>-<version> tag) and empty for all other rows.
#
# Requirements: git, perl, make (dump-target-info.pl runs make), python3.

VERSION=$1
FILTER=${2:-}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git clone --depth 1 --branch "v$VERSION" \
    https://github.com/openwrt/openwrt.git "$TMP/openwrt" 2>/dev/null

cd "$TMP/openwrt"
perl scripts/dump-target-info.pl targets > "$TMP/rows.txt"

python3 - "$VERSION" "$FILTER" "$TMP/rows.txt" <<'EOF'
import json, sys

version, filt, rows_path = sys.argv[1], sys.argv[2], sys.argv[3]

rows = []
seen_archs = set()
for line in open(rows_path):
    target_sub, arch = line.split()
    if filt and target_sub not in filt.split(","):
        continue
    target, subtarget = target_sub.split("/", 1)
    alias = arch if arch not in seen_archs else ""
    seen_archs.add(arch)
    rows.append({"version": version, "target": target, "subtarget": subtarget,
                 "arch": arch, "arch_alias": alias})

if not rows:
    print(f"error: no rows for OpenWrt {version}"
          + (f" matching filter '{filt}'" if filt else ""), file=sys.stderr)
    sys.exit(1)

print(json.dumps({"include": rows}, indent=2))
EOF
