#!/bin/sh
set -eu

# Generates the release matrix for one OpenWrt version, mirroring the
# official openwrt/sdk matrix: every (target, subtarget) pair that has an
# SDK (computed with the same scripts/dump-target-info.pl the official
# openwrt/docker workflow uses), plus the arch-alias marking: the FIRST
# target of each arch is the row whose build also gets the <arch>-<version>
# tag (exactly like openwrt/docker's containers.yml).
#
# Idempotency: with --image, rows whose <target>-<subtarget>-<version> tag
# already exists in the registry are SKIPPED — an already-built version is
# not built over again (the release workflow relies on this; pass --force to
# rebuild everything, e.g. after a recipe change).
#
# Usage: generate-matrix.sh <version> [target-filter] [--image IMAGE] [--force]
#   version        OpenWrt release, e.g. 25.12.5 (v-prefix is added)
#   target-filter  optional comma-separated exact "target/subtarget" list
#                  (e.g. "x86/64,armsr/armv8") — used by the single-build
#                  workflow; within the filter the first row of each arch
#                  still gets the arch alias.
#   --image        registry image to check for existing tags
#                  (e.g. ghcr.io/i-zhirov/openwrt-sdk-arm64); enables the
#                  skip of already-built rows. The registry is queried
#                  anonymously, so the package must be public; if the query
#                  fails, the script warns and emits ALL rows (a registry
#                  hiccup must not silently skip work).
#   --force        do not skip any row, even if --image is given.
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

VERSION=""
FILTER=""
IMAGE=""
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE=$2; shift 2 ;;
        --force) FORCE=1; shift ;;
        *)
            if [ -z "$VERSION" ]; then
                VERSION=$1
            elif [ -z "$FILTER" ]; then
                FILTER=$1
            else
                echo "unexpected argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

[ -n "$VERSION" ] || { echo "usage: generate-matrix.sh <version> [target-filter] [--image IMAGE] [--force]" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git clone --depth 1 --branch "v$VERSION" \
    https://github.com/openwrt/openwrt.git "$TMP/openwrt" 2>/dev/null

cd "$TMP/openwrt"
# 2>/dev/null silences the make chatter (missing tmp/ dir in a fresh clone,
# CPU_TYPE warnings) that the DUMP invocations produce — the official
# openwrt/docker workflow does the same; the target data is unaffected.
perl scripts/dump-target-info.pl targets 2>/dev/null > "$TMP/rows.txt"

python3 - "$VERSION" "$FILTER" "$TMP/rows.txt" "$IMAGE" "$FORCE" <<'EOF'
import json, sys, urllib.request, urllib.parse

version, filt, rows_path, image, force = sys.argv[1:6]
force = force == "1"

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

# Skip rows whose per-row tag already exists in the registry.
if image and not force:
    host, _, repo = image.partition("/")
    existing = set()
    try:
        tok = json.load(urllib.request.urlopen(
            f"https://{host}/token?scope=repository:{repo}:pull", timeout=30))["token"]
        last = ""
        while True:
            url = (f"https://{host}/v2/{repo}/tags/list?n=100"
                   + (f"&last={urllib.parse.quote(last)}" if last else ""))
            req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"})
            names = json.load(urllib.request.urlopen(req, timeout=30)).get("tags", [])
            if not names:
                break
            existing.update(names)
            last = names[-1]
            if len(names) < 100:
                break
        print(f"note: {len(existing)} existing tags in {image}", file=sys.stderr)
    except Exception as e:
        print(f"warning: cannot query {image} ({e}); building all rows", file=sys.stderr)

    kept = []
    for r in rows:
        tag = f"{r['target']}-{r['subtarget']}-{r['version']}"
        if tag in existing:
            print(f"skip: {tag} already built", file=sys.stderr)
        else:
            kept.append(r)
    rows = kept
    if not rows:
        print(f"note: every row of OpenWrt {version} is already built — nothing to do", file=sys.stderr)

# Compact (single-line) JSON: the workflows write it to GITHUB_OUTPUT, which
# rejects multiline values.
print(json.dumps({"include": rows}))
EOF
