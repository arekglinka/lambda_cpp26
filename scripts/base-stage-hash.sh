#!/usr/bin/env bash
# scripts/base-stage-hash.sh — per-stage content hash for Containerfile.base.
#
# Usage: scripts/base-stage-hash.sh <toolchain|python-stack|conan-deps|agents>
#
# Stage hash = sha256(parent hash + stage block + stage COPY inputs)[0:16],
# where the parent hash of the first stage is the empty string. The stage
# block is the slice of Containerfile.base from the stage's `FROM` line up to
# (excluding) the next `FROM` line; comments between stages belong to the
# following FROM line. For conan-deps the repo files it COPYs (conanfile.py,
# profiles/, recipes/) are mixed in as extra inputs, sorted for determinism.
#
# This script is the single source of truth for base-stage hashing; it is
# called from the Makefile, scripts/build-devcontainer.sh and
# .github/workflows/base-image.yml.
set -euo pipefail
cd "$(dirname "$0")/.."

requested="${1:-}"
containerfile="Containerfile.base"

# Stage names in file order. (\K = emit match after prefix; equivalent to the
# lookbehind form, which PCRE rejects as variable-length.)
mapfile -t stages < <(grep -oP '^FROM \S+ AS \K\S+' "$containerfile")

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Split the Containerfile into per-stage blocks at ^FROM lines
# (block i+1 corresponds to stages[i]; pre-FROM header goes to stage0.part).
awk -v d="$tmp" '/^FROM /{n++} {print > (d "/stage" n ".part")}' "$containerfile"

prev=""
for i in "${!stages[@]}"; do
    stage="${stages[$i]}"
    block="$tmp/stage$((i + 1)).part"
    if [[ "$stage" == "conan-deps" ]]; then
        h="$(
            {
                printf '%s' "$prev"
                cat "$block"
                find conanfile.py profiles recipes -type f 2>/dev/null | sort | xargs -r cat
            } | sha256sum | cut -c1-16
        )"
    else
        h="$( { printf '%s' "$prev"; cat "$block"; } | sha256sum | cut -c1-16 )"
    fi
    prev="$h"
    if [[ "$stage" == "$requested" ]]; then
        echo "$h"
        exit 0
    fi
done

{
    echo "base-stage-hash.sh: unknown stage '${requested}'."
    echo "Available stages: ${stages[*]}"
} >&2
exit 1
