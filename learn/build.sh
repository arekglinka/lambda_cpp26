#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
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

SRC="${1:-t1.cpp}"
OUT_NAME=$(basename "${SRC%.cpp}")
OUT="$PROJECT_DIR/build/learn/$OUT_NAME"

/opt/gcc16/bin/g++ -std=c++26 -O0 -g \
    $INCLUDE_DIRS \
    "$SCRIPT_DIR/$SRC" \
    -L"$(dirname "$DEV_LIB")" -ldev_lib \
    -Wl,-rpath,"$(dirname "$DEV_LIB")" \
    -o "$OUT"

echo "Built: $OUT"

{
    echo "-std=c++26"
    echo "-I/opt/gcc16/include/c++/16.1.0"
    for d in /root/.conan2/p/b/*/p; do
        [ -d "$d/include" ] && echo "-I$d/include"
    done
} > "$SCRIPT_DIR/compile_flags.txt"
