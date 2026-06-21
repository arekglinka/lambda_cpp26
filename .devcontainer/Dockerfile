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
# Architecture: three-stage multi-stage build
#   Stage 1 (arrow-save):   FROM arrow-cache, runs conan cache save → ~35 MB tgz
#   Stage 2 (quantlib-save): FROM quantlib-cache, runs conan cache save → ~40 MB tgz
#   Stage 3 (final):         FROM small-deps, COPY the small tgz files, restore, dev tools
#
# Why conan cache save/restore (not cp -rn):
#   cp -rn copies files but doesn't update Conan's .conan.db SQLite database.
#   Without database registration, conan install reports "No packages found"
#   and triggers full rebuilds. save/restore properly handles the database.
#   The pattern "arrow/18.0.0:*" (with colon) includes BOTH recipe and binary.
# =============================================================================

ARG REGISTRY_OWNER=arekglinka
ARG SMALL_DEPS_TAG=latest
ARG ARROW_TAG=latest
ARG QUANTLIB_TAG=latest

# Stage 1: save arrow's recipe + binary into a portable tgz
FROM ghcr.io/${REGISTRY_OWNER}/lambda_cpp26-arrow:${ARROW_TAG} AS arrow-save
RUN conan cache save "arrow/18.0.0:*" --file /tmp/arrow-delta.tgz

# Stage 2: save quantlib's recipe + binary into a portable tgz
FROM ghcr.io/${REGISTRY_OWNER}/lambda_cpp26-quantlib:${QUANTLIB_TAG} AS quantlib-save
RUN conan cache save "quantlib/1.38:*" --file /tmp/ql-delta.tgz

# Stage 3: final dev container
FROM ghcr.io/${REGISTRY_OWNER}/lambda_cpp26-small-deps:${SMALL_DEPS_TAG}

# Copy the small delta tgz files from the save stages (~35 + ~40 MB)
COPY --from=arrow-save    /tmp/arrow-delta.tgz /tmp/
COPY --from=quantlib-save /tmp/ql-delta.tgz   /tmp/

# Restore both into our cache (properly registers in .conan.db)
RUN conan cache restore /tmp/arrow-delta.tgz && \
    conan cache restore /tmp/ql-delta.tgz && \
    rm -f /tmp/arrow-delta.tgz /tmp/ql-delta.tgz

# Dev-only packages (NOT in upstream images because prod doesn't need them).
RUN dnf install -y \
        clang-tools-extra gdb valgrind \
    && dnf clean all

RUN pip3.12 install --no-cache-dir \
        "pyarrow>=15.0" "pytest>=8.0" "clangd>=19"

# Sanity: both libraries must have binaries registered in the database.
RUN conan list 'arrow/18.0.0:*'    --cache | grep -q "packages" && \
    conan list 'quantlib/1.38:*'   --cache | grep -q "packages"

WORKDIR /workspace

CMD ["sleep", "infinity"]
