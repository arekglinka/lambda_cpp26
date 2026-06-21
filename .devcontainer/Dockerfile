# .devcontainer/Dockerfile (assembled dev container)
# =============================================================================
# Final dev container — merges caches from arrow + quantlib images into
# small-deps via `conan cache save/restore` (properly updates .conan.db),
# then adds dev-only tools.
#
# Used by BOTH:
#   1. VSCode "Reopen in Container" with .devcontainer/devcontainer.json
#   2. CI: .github/workflows/devcontainer.yml's assemble-devcontainer job
#
# Build time: ~5 min (cache save/restore + dev tool installs).
#
# Build args (all optional — default to :latest):
#   ARROW_TAG      — tag of lambda_cpp26-arrow
#   QUANTLIB_TAG   — tag of lambda_cpp26-quantlib
#   SMALL_DEPS_TAG — tag of lambda_cpp26-small-deps (the FROM for final stage)
#   REGISTRY_OWNER — ghcr.io owner (default: arekglinka)
#
# Why conan cache save/restore (not cp -rn):
# The previous cp -rn merge copied files but didn't update Conan's .conan.db
# SQLite database. The database is the source of truth for package lookups.
# Without it registering arrow/quantlib binaries, `conan install` reported
# "No packages found for this revision" and triggered full rebuilds.
#
# conan cache save creates a portable tgz that INCLUDES database metadata.
# conan cache restore properly registers packages in the target database.
# The pattern `arrow/18.0.0:*` (with colon) includes BOTH recipe and binary.
# =============================================================================

# syntax=docker/dockerfile:1.6  — enables BuildKit --mount=type=bind in RUN.

ARG REGISTRY_OWNER=arekglinka
ARG SMALL_DEPS_TAG=latest
ARG ARROW_TAG=latest
ARG QUANTLIB_TAG=latest

FROM ghcr.io/${REGISTRY_OWNER}/lambda_cpp26-arrow:${ARROW_TAG} AS arrow-cache
FROM ghcr.io/${REGISTRY_OWNER}/lambda_cpp26-quantlib:${QUANTLIB_TAG} AS quantlib-cache
FROM ghcr.io/${REGISTRY_OWNER}/lambda_cpp26-small-deps:${SMALL_DEPS_TAG}

# Save arrow's and quantlib's deltas (recipe + binary) from their respective
# caches, then restore into ours. Uses CONAN_HOME + symlinks to point Conan
# at the bind-mounted (read-only) source caches.
#
# --mount=type=bind: read-only mounts, no intermediate COPY layers.
# Pattern "arrow/18.0.0:*" includes ALL binary variants (the :* wildcard).
RUN --mount=type=bind,from=arrow-cache,source=/root/.conan2,target=/tmp/arrow-conan \
    --mount=type=bind,from=quantlib-cache,source=/root/.conan2,target=/tmp/ql-conan \
    mkdir -p /tmp/arrow-home /tmp/ql-home && \
    ln -sf /tmp/arrow-conan /tmp/arrow-home/.conan2 && \
    ln -sf /tmp/ql-conan /tmp/ql-home/.conan2 && \
    CONAN_HOME=/tmp/arrow-home conan cache save "arrow/18.0.0:*" --file /tmp/arrow-delta.tgz && \
    CONAN_HOME=/tmp/ql-home conan cache save "quantlib/1.38:*" --file /tmp/ql-delta.tgz && \
    conan cache restore /tmp/arrow-delta.tgz && \
    conan cache restore /tmp/ql-delta.tgz && \
    rm -f /tmp/arrow-delta.tgz /tmp/ql-delta.tgz && \
    rm -f /tmp/arrow-home/.conan2 /tmp/ql-home/.conan2

# Dev-only packages (NOT in upstream images because prod doesn't need them).
RUN dnf install -y \
        clang-tools-extra gdb valgrind \
    && dnf clean all

RUN pip3.12 install --no-cache-dir \
        "pyarrow>=15.0" "pytest>=8.0" "clangd>=19"

# Sanity: both libraries must have binaries registered in the database.
# Fails fast if the save/restore didn't work.
RUN conan list 'arrow/18.0.0:*'    --cache | grep -q "packages" && \
    conan list 'quantlib/1.38:*'   --cache | grep -q "packages"

WORKDIR /workspace

CMD ["sleep", "infinity"]
