#!/usr/bin/env bash
#
# bootstrap-workspace.sh — one-shot workspace setup after a fresh checkout.
#
# Run INSIDE the devcontainer after "Reopen in Container" to:
#   1. Verify the environment (in-container, at project root, toolchain present)
#   2. Populate build/Release/ via conan install + conan build
#      → produces compile_commands.json (clangd) + sum_columns.*.so (pytest)
#   3. Smoke-test by running the pytest suite
#   4. Print next steps (reload VSCode, restart clangd)
#
# Idempotent: safe to re-run. If build/Release/ already exists and is intact,
# conan install is a near-instant cache check and conan build is incremental.
#
# Usage:
#   ./scripts/bootstrap-workspace.sh
#   SKIP_TESTS=1 ./scripts/bootstrap-workspace.sh        # skip pytest smoke
#   FORCE_CLEAN=1 ./scripts/bootstrap-workspace.sh       # rm -rf build/ first
#
# NOT in scope (handled elsewhere):
#   - Building the devcontainer image itself (.devcontainer/Dockerfile)
#   - Pulling the pre-built snapshot image (see docs/devcontainer-snapshot.md)
#   - VSCode host-side settings (dev.containers.dockerPath etc.)
#
set -euo pipefail

SKIP_TESTS="${SKIP_TESTS:-0}"
FORCE_CLEAN="${FORCE_CLEAN:-0}"

log()  { printf '\033[1;34m[boot]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err]\033[0m  %s\n' "$*" >&2; exit 1; }

echo ""
echo "============================================"
echo "  lambda_cpp26 — workspace bootstrap"
echo "============================================"
echo ""

# --- Step 1: Environment checks ------------------------------------------------

[[ -f conanfile.py ]]                       || die "Run from repo root (no conanfile.py here). pwd=$(pwd)"
[[ -d .devcontainer ]]                      || die "No .devcontainer/ — wrong directory?"
[[ -f /var/lang/bin/clangd ]]               || die "Not inside devcontainer (no /var/lang/bin/clangd). Open in VSCode first."
[[ -x /opt/gcc16/bin/g++ ]]                 || die "GCC 16 missing at /opt/gcc16/bin/g++ — image is corrupt."
[[ -d /tmp/conan-profiles ]]                || die "No /tmp/conan-profiles/ — image is missing baked-in profiles."

command -v conan >/dev/null                 || die "conan not on PATH."
command -v cmake >/dev/null                 || die "cmake not on PATH."
command -v python3.12 >/dev/null            || die "python3.12 not on PATH."

ok "Environment: $(awk -F= '/^NAME/{print $2}' /etc/os-release 2>/dev/null || echo unknown), "\
   "GCC $(/opt/gcc16/bin/g++ -dumpversion), conan $(conan --version | awk '{print $3}'), "\
   "clangd $(/var/lang/bin/clangd --version | awk 'NR==1{print $3}')"

# --- Step 2: Optional clean ----------------------------------------------------

if [[ "$FORCE_CLEAN" == "1" ]]; then
    warn "FORCE_CLEAN=1 — removing build/ entirely"
    rm -rf build/
fi

# --- Step 3: conan install + build --------------------------------------------

PROFILE_HOST="/tmp/conan-profiles/al2023"
PROFILE_BUILD="/tmp/conan-profiles/al2023"

if [[ -f build/Release/compile_commands.json ]] && \
   compgen -G "build/Release/sum_columns.cpython-*.so" >/dev/null; then
    log "build/Release/ already populated — running incremental rebuild to be safe."
    make -C build/Release sum_columns -j"$(nproc)"
else
    log "Running 'conan install' (cache hits fast since deps are baked into image)..."
    conan install . --build=missing \
        -pr:h "$PROFILE_HOST" \
        -pr:b "$PROFILE_BUILD" \
        -s:h build_type=Release
    ok "conan install done"

    log "Running 'conan build' (compiles src/sum_columns.cpp → .so, emits compile_commands.json)..."
    conan build . \
        -pr:h "$PROFILE_HOST" \
        -pr:b "$PROFILE_BUILD"
    ok "conan build done"
fi

# --- Step 4: Verify outputs ---------------------------------------------------

CC_JSON="build/Release/compile_commands.json"
SO_GLOB="build/Release/sum_columns.cpython-*.so"

[[ -f "$CC_JSON" ]] || die "Missing $CC_JSON — clangd will not resolve includes."
SO_PATHS=( $SO_GLOB )
[[ ${#SO_PATHS[@]} -gt 0 ]] || die "Missing $SO_GLOB — pytest will fail to import."

ok "compile_commands.json: $(stat -c%s "$CC_JSON") bytes"
ok "pybind11 .so:          $(stat -c%s "${SO_PATHS[0]}") bytes  (${SO_PATHS[0]##*/})"

# --- Step 5: Smoke test -------------------------------------------------------

if [[ "$SKIP_TESTS" == "1" ]]; then
    warn "SKIP_TESTS=1 — skipping pytest smoke"
else
    log "Running pytest suite as smoke test..."
    PYTHONPATH="$(pwd)/build/Release:$(pwd)" python3.12 -m pytest tests/ -q
    ok "All tests passed"
fi

# --- Step 6: Next steps -------------------------------------------------------

cat <<EOF

============================================
  Bootstrap complete
============================================

  Build artifacts:
    $CC_JSON        ← clangd reads this for include paths
    ${SO_PATHS[0]}    ← pytest imports this via PYTHONPATH

  Next steps in VSCode:

    1. Restart clangd so it picks up compile_commands.json:
       Ctrl+Shift+P → "clangd: Restart language server"

    2. (Only if VSCode UI still shows stale errors)
       Ctrl+Shift+P → "Developer: Reload Window"

    3. To debug src/sum_columns.cpp:
       - Open the file, set breakpoints in price_options() or sum_columns()
       - Run & Debug dropdown → "Debug pytest (sum_columns module)"
       - Press F5

  Incremental rebuild during dev:
    make -C build/Release sum_columns -j\$(nproc)   # ~5-10 sec, skips conan

  Full rebuild (after conanfile.py / CMakeLists.txt changes):
    ./scripts/bootstrap-workspace.sh

EOF
ok "Done."
