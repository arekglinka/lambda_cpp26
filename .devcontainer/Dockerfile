# .devcontainer/Dockerfile (multi-stage assembled)
# =============================================================================
# Final dev container — assembled from three cached intermediate images on
# ghcr.io. This file is used by BOTH:
#
#   1. VSCode "Reopen in Container" with .devcontainer/devcontainer.json
#      (build config — VSCode invokes `docker/podman build -f Dockerfile ..`)
#
#   2. CI: .github/workflows/devcontainer.yml's assemble-devcontainer job
#
# Build time: ~5 min (cache merges + dev tools). All the heavy lifting
# (GCC compile, Arrow compile, QuantLib compile) is done in the cached
# intermediate images.
#
# Build args (all optional — default to :latest):
#   GCC_TAG       — tag of lambda_cpp26-gcc-base to use
#   ARROW_TAG     — tag of lambda_cpp26-arrow-deps to use
#   QUANTLIB_TAG  — tag of lambda_cpp26-quantlib-deps to use
#   REGISTRY_OWNER — ghcr.io owner (default: arekglinka)
#
# To override for local testing:
#   podman build -f .devcontainer/Dockerfile \
#     --build-arg GCC_TAG=test --build-arg ARROW_TAG=test \
#     --build-arg QUANTLIB_TAG=test -t lambda_cpp26-dev:test ..
# =============================================================================

# syntax=docker/dockerfile:1.6  — enables BuildKit --mount=type=bind in RUN.
# Without this, two COPY --from layers would add ~8 GB of intermediate bloat
# to the final image (one full copy of arrow's cache, one of quantlib's).
# --mount=type=bind mounts the source stages read-only DURING the RUN instead,
# so only the merged result ends up in the final layer.

ARG REGISTRY_OWNER=arekglinka
ARG GCC_TAG=latest
ARG ARROW_TAG=latest
ARG QUANTLIB_TAG=latest

FROM ghcr.io/${REGISTRY_OWNER}/lambda_cpp26-arrow-deps:${ARROW_TAG} AS arrow-cache
FROM ghcr.io/${REGISTRY_OWNER}/lambda_cpp26-quantlib-deps:${QUANTLIB_TAG} AS quantlib-cache
FROM ghcr.io/${REGISTRY_OWNER}/lambda_cpp26-gcc-base:${GCC_TAG}

# Merge Conan caches from both dep stages into /root/.conan2 in a SINGLE layer.
# --mount=type=bind: source stages mounted read-only at /tmp/* during the RUN.
# Conan cache paths are deterministic from package_id, so identical packages
# (e.g. boost built by both stages) live at the same path; cp -rn (no-clobber)
# keeps the first copy and skips duplicates — safe.
RUN --mount=type=bind,from=arrow-cache,source=/root/.conan2,target=/tmp/arrow-conan \
    --mount=type=bind,from=quantlib-cache,source=/root/.conan2,target=/tmp/ql-conan \
    cp -rn /tmp/arrow-conan/. /root/.conan2/ && \
    cp -rn /tmp/ql-conan/.    /root/.conan2/

# Dev-only packages (NOT in gcc-base because prod doesn't need them).
# clang-tools-extra pulls clang-format/clang-tidy (system clangd 15.x is
# superseded by the pip-installed clangd 22 below).
RUN dnf install -y \
        clang-tools-extra gdb valgrind \
    && dnf clean all

RUN pip3.12 install --no-cache-dir \
        "pyarrow>=15.0" "pytest>=8.0" "clangd>=19"

# Sanity: both libraries must be in the merged cache. Fails fast if a stage
# produced an empty cache (typical cause: ghcr.io pull fell back to a stale tag).
RUN conan list 'arrow/*'    --cache && \
    conan list 'quantlib/*' --cache

WORKDIR /workspace

# VSCode overrides CMD at runtime; this is just a default for `podman run`.
CMD ["sleep", "infinity"]
