#!/usr/bin/env bash
# scripts/check-wheels.sh — cp-wheel availability probe.
#
# Usage: check-wheels.sh [python-minor, default 3.14]
# Fails (exit 1) listing any pinned dep lacking a cp<minor> manylinux x86_64 wheel
# or universal wheel. Run BEFORE a Python bump to avoid burning CI hours.
#
# Dep floors mirror Containerfile.base — keep in sync with Containerfile.base pins:
#   numpy>=2.5  conan>=2.32  cmake>=4.4  ninja>=1.13  pybind11>=3.1
#   pyarrow>=25  pytest>=9  clangd>=22  torch (cu130 index)
#   polars>=1.44  jax>=0.11 (cuda13 extra)  jaxlib>=0.11  jax-cuda13-plugin>=0.11
# Since the pins are >= floors, each probe resolves the LATEST PyPI release.
# torch is special-cased: it comes from the cu130 index, not PyPI.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${1:-3.14}"
CP="cp${PY//./}"
CPNUM="${CP#cp}"
FAILS=0

# PASS if any wheel is: universal (py3/py2.py3-none-any), a pure-python wheel
# with a manylinux x86_64 platform tag (py3-none-manylinux — cmake/ninja/clangd
# ship these), an abi3 manylinux x86_64 wheel whose minimum cp tag <= our
# target, or a native <name>-<ver>-cpXXX-cpXXX-manylinux x86_64 wheel
# (filenames start with the package name, so tags are matched as substrings).
wheel_ok() {
    local f min
    for f in "$@"; do
        case "$f" in
            *-py3-none-any.whl|*-py2.py3-none-any.whl)
                return 0 ;;
            *-py3-none-manylinux*x86_64*|*-py2.py3-none-manylinux*x86_64*)
                return 0 ;;
            *-${CP}-${CP}-manylinux*x86_64*)
                return 0 ;;
            *-abi3-manylinux*x86_64*)
                min="${f%%-abi3-*}"
                min="${min##*-}"
                min="${min#cp}"
                if [ -n "$min" ] && [ "$min" -le "$CPNUM" ] 2>/dev/null; then
                    return 0
                fi ;;
        esac
    done
    return 1
}

check_pypi() {
    local pkg="$1" json ver
    if ! json="$(curl -fsSL "https://pypi.org/pypi/${pkg}/json")"; then
        printf 'FAIL  %-10s %-10s (PyPI unreachable)\n' "$pkg" "-"
        return 1
    fi
    ver="$(grep -o '"version": *"[^"]*"' <<<"$json" | head -1 | sed 's/.*: *"//; s/"//')"
    mapfile -t wheels < <(grep -o '"filename": *"[^"]*\.whl"' <<<"$json" | sed 's/.*: *"//; s/"//')
    if wheel_ok "${wheels[@]}"; then
        printf 'PASS  %-10s %-10s\n' "$pkg" "$ver"
        return 0
    fi
    printf 'FAIL  %-10s %-10s (no %s manylinux x86_64 / universal wheel)\n' "$pkg" "$ver" "$CP"
    return 1
}

check_torch() {
    local html
    if ! html="$(curl -fsSL "https://download.pytorch.org/whl/cu130/torch/")"; then
        printf 'FAIL  %-10s %-10s (cu130 index unreachable)\n' torch "-"
        return 1
    fi
    html="${html//%2B/+}"
    if grep -Eq "torch-[0-9][0-9.]*\\+cu130-${CP}-${CP}-manylinux.*x86_64" <<<"$html"; then
        printf 'PASS  %-10s %-10s (cu130 index)\n' torch "latest"
        return 0
    fi
    printf 'FAIL  %-10s %-10s (no %s cu130 manylinux x86_64 wheel)\n' torch "latest" "$CP"
    return 1
}

printf 'Checking cp-wheel availability for Python %s (%s, manylinux x86_64)\n\n' "$PY" "$CP"
for pkg in numpy pyarrow conan cmake ninja pybind11 pytest clangd polars jax jaxlib jax-cuda13-plugin; do
    check_pypi "$pkg" || FAILS=$((FAILS + 1))
done
check_torch || FAILS=$((FAILS + 1))

printf '\n'
if [ "$FAILS" -gt 0 ]; then
    printf 'RESULT: %d FAIL — do NOT bump to Python %s yet.\n' "$FAILS" "$PY"
    exit 1
fi
printf 'RESULT: ALL PASS — Python %s wheels are available for every pin.\n' "$PY"
