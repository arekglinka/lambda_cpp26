#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
cd "$PROJECT_DIR"

DEV_LIB="$PROJECT_DIR/build/learn/libdev_lib.so"

if [ ! -f "$DEV_LIB" ]; then
    echo "==> Building libdev_lib.so (one-time)..."
    ALL_A=$(find /root/.conan2/p/b -path "*/p/lib/*.a" \
        ! -name "*boost*" \
        ! -name "*brotli*" \
        ! -name "*flex*" \
        ! -name "libfl.a" \
        ! -name "*bison*" \
        ! -name "liby.a" \
        ! -name "*m4*" \
        ! -name "*cmake*" \
        ! -name "*ninja*" \
        2>/dev/null | sort -u)
    mkdir -p "$(dirname "$DEV_LIB")"
    /opt/gcc16/bin/g++ -shared -fPIC -o "$DEV_LIB" \
        -Wl,--whole-archive $ALL_A -Wl,--no-whole-archive \
        -lpthread -ldl -lm -lrt
    echo "==> Done ($(du -h "$DEV_LIB" | cut -f1))"
fi

INCLUDE_DIRS=""
for d in /root/.conan2/p/b/*/p; do
    [ -d "$d/include" ] && INCLUDE_DIRS="$INCLUDE_DIRS -I$d/include"
done

# Accept: bare filename (backward compat, assumed in learn/),
# relative path from project root (e.g. src/foo.cpp), or absolute path.
SRC="${1:-t1.cpp}"
if [[ ! -f "$SRC" ]]; then
    if [[ -f "learn/$SRC" ]]; then
        SRC="learn/$SRC"
    else
        echo "ERROR: '$SRC' not found (looked in cwd and learn/)" >&2
        exit 1
    fi
fi

# Output preserves the source's folder structure so learn/t1 and src/t1
# don't clobber each other: build/learn/t1, build/src/t1, etc.
SRC_REL_DIR="$(dirname "$SRC")"
[[ "$SRC_REL_DIR" == "." ]] && SRC_REL_DIR="learn"
OUT_NAME="$(basename "${SRC%.cpp}")"
OUT_DIR="$PROJECT_DIR/build/$SRC_REL_DIR"
OUT="$OUT_DIR/$OUT_NAME"
mkdir -p "$OUT_DIR"

# pybind11 modules (PYBIND11_MODULE macro) are NOT standalone executables —
# they must be built by CMake's pybind11_add_module() and produce a
# Python-loadable .so at build/Release/<name>.cpython-*.so.  Auto-route.
if grep -q "PYBIND11_MODULE(" "$PROJECT_DIR/$SRC" 2>/dev/null; then
    echo "==> $SRC is a pybind11 module, routing to: make -C build/Release $OUT_NAME"
    make -C "$PROJECT_DIR/build/Release" "$OUT_NAME" -j"$(nproc)"
    echo "Built: $PROJECT_DIR/build/Release/$OUT_NAME.cpython-*.so"
    exit 0
fi

/opt/gcc16/bin/g++ -std=c++26 -O0 -g \
    $INCLUDE_DIRS \
    "$PROJECT_DIR/$SRC" \
    -L"$(dirname "$DEV_LIB")" -ldev_lib \
    -Wl,-rpath,"$(dirname "$DEV_LIB")" \
    -o "$OUT"

echo "Built: $OUT"

# Refresh compile_flags.txt so clangd picks up new include dirs if the
# Conan cache layout changed (e.g. after a recipe edit + conan install).
{
    echo "-std=c++26"
    echo "-I/opt/gcc16/include/c++/16.1.0"
    for d in /root/.conan2/p/b/*/p; do
        [ -d "$d/include" ] && echo "-I$d/include"
    done
} > "$SCRIPT_DIR/compile_flags.txt"
