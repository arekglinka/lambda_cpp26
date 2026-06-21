# .devcontainer/Dockerfile (multi-stage assembled dev container)
# =============================================================================
# Final dev container — merges caches from arrow + quantlib + small-deps images
# and adds dev-only tools.
#
# Used by BOTH:
#   1. VSCode "Reopen in Container" with .devcontainer/devcontainer.json
#   2. CI: .github/workflows/devcontainer.yml's assemble-devcontainer job
#
# Build time: ~5 min (cache merge + dev tool installs).
#
# Build args (all optional — default to :latest):
#   ARROW_TAG      — tag of lambda_cpp26-arrow
#   QUANTLIB_TAG   — tag of lambda_cpp26-quantlib
#   SMALL_DEPS_TAG — tag of lambda_cpp26-small-deps (the FROM for final stage)
#   REGISTRY_OWNER — ghcr.io owner (default: arekglinka)
#
# Why this merge is safe (different from the previous failed parallel design):
# arrow and quantlib images both FROM the SAME small-deps parent. Their conan
# caches therefore share IDENTICAL transitives. Only their deltas differ
# (arrow adds arrow/18.0.0; quantlib adds quantlib/1.38). cp -rn (no-clobber)
# skips the identical transitive files and only copies the deltas — no
# conflicts possible.
# =============================================================================

# syntax=docker/dockerfile:1.6  — enables BuildKit --mount=type=bind in RUN.
# Without this, COPY --from would create ~8 GB of intermediate layers (one full
# copy of arrow's cache, one of quantlib's). --mount=type=bind mounts the source
# stages read-only DURING the RUN, so only the merged result ends up in the
# final layer.

ARG REGISTRY_OWNER=arekglinka
ARG SMALL_DEPS_TAG=latest
ARG ARROW_TAG=latest
ARG QUANTLIB_TAG=latest

FROM ghcr.io/${REGISTRY_OWNER}/lambda_cpp26-arrow:${ARROW_TAG} AS arrow-cache
FROM ghcr.io/${REGISTRY_OWNER}/lambda_cpp26-quantlib:${QUANTLIB_TAG} AS quantlib-cache
FROM ghcr.io/${REGISTRY_OWNER}/lambda_cpp26-small-deps:${SMALL_DEPS_TAG}

# Merge deltas from arrow-cache and quantlib-cache into our cache.
# Both caches started from THIS image (small-deps), so:
#   - small-deps files: identical, skipped by cp -rn (no-clobber)
#   - arrow's delta (arrow package): copied in first cp
#   - quantlib's delta (quantlib package): copied in second cp
# Net new data: ~4 GB (arrow binary ~3 GB + quantlib binary ~1 GB).
RUN --mount=type=bind,from=arrow-cache,source=/root/.conan2,target=/tmp/arrow-conan \
    --mount=type=bind,from=quantlib-cache,source=/root/.conan2,target=/tmp/ql-conan \
    cp -rn /tmp/arrow-conan/. /root/.conan2/ && \
    cp -rn /tmp/ql-conan/.    /root/.conan2/

# Dev-only packages (NOT in upstream images because prod doesn't need them).
RUN dnf install -y \
        clang-tools-extra gdb valgrind \
    && dnf clean all

RUN pip3.12 install --no-cache-dir \
        "pyarrow>=15.0" "pytest>=8.0" "clangd>=19"

# Sanity: both libraries must be in the merged cache. Fails fast if a stage
# produced an empty cache (e.g., ghcr.io pull fell back to a stale tag).
RUN conan list 'arrow/*'    --cache && \
    conan list 'quantlib/*' --cache

WORKDIR /workspace

CMD ["sleep", "infinity"]
