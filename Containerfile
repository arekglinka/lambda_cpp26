# ============================================================
# Stage 1: Builder — GCC 16 + Conan + pybind11 extension
# Base: public.ecr.aws/lambda/python:3.12 (CPython 3.12 ABI)
#
# CACHE STRATEGY: --mount=type=cache on /root/.conan2 persists the
# Conan recipe cache + built packages across builds.  Only recipes
# that changed since the last successful build are recompiled.
# Profiles live in /tmp/conan-profiles (image layer) so the cache
# mount on /root/.conan2 doesn't mask them.
# ============================================================
FROM public.ecr.aws/lambda/python:3.12 AS builder

ARG BUILD_TYPE=Release

RUN dnf install -y \
        gcc gcc-c++ binutils git python3.12-devel \
        tar xz bzip2 ca-certificates ncurses-devel which curl-devel \
        gmp-devel mpfr-devel libmpc-devel isl-devel \
        bison flex texinfo wget diffutils \
        perl perl-FindBin \
        zlib-devel openssl-devel \
    && dnf clean all

RUN mkdir -p /tmp/gcc && cd /tmp/gcc && \
    curl -sL https://gcc.gnu.org/pub/gcc/releases/gcc-16.1.0/gcc-16.1.0.tar.xz | \
    tar xJ --strip-components=1 && \
    ./contrib/download_prerequisites && mkdir build && cd build && \
    ../configure --prefix=/opt/gcc16 \
        --enable-languages=c,c++ --disable-multilib \
        --disable-bootstrap --disable-nls --enable-checking=release && \
    make -j"$(nproc)" && make install && rm -rf /tmp/gcc

ENV CC=/opt/gcc16/bin/gcc
ENV CXX=/opt/gcc16/bin/g++
ENV PATH="/opt/gcc16/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/gcc16/lib64:${LD_LIBRARY_PATH}"
ENV CFLAGS="-std=gnu17"
ENV CXXFLAGS=""

RUN pip3.12 install --no-cache-dir "conan>=2.4" "cmake>=3.28" "ninja>=1.11" "pybind11>=2.13"

WORKDIR /src

# Profiles in /tmp (image layer) — NOT inside the cached Conan home.
COPY profiles/ /tmp/conan-profiles/

# Custom recipes (image layer) — re-exported each build, overwriting cache.
COPY recipes/ /tmp/recipes/

# Conan remote + recipe exports — cached home persists across builds.
RUN --mount=type=cache,target=/root/.conan2 \
    conan remote add conancenter https://center2.conan.io --force 2>/dev/null || true && \
    conan export /tmp/recipes/arrow && \
    conan export /tmp/recipes/quantlib

# Project files (change frequently — invalidate from here)
COPY conanfile.py ./
COPY src/ src/
COPY tests/ tests/

# Resolve + build deps.  Cache mount means already-built deps (from a
# previous successful build) are reused — only changed recipes rebuild.
RUN --mount=type=cache,target=/root/.conan2 \
    conan install . --build=missing \
        -pr:h /tmp/conan-profiles/al2023 \
        -pr:b /tmp/conan-profiles/al2023 \
        -s:h build_type=${BUILD_TYPE}

# Build the pybind11 extension .so.
RUN --mount=type=cache,target=/root/.conan2 \
    conan build . \
        -pr:h /tmp/conan-profiles/al2023 \
        -pr:b /tmp/conan-profiles/al2023

# Extract + strip the .so.
RUN find build -name "sum_columns*.so" -exec cp {} /tmp/sum_columns.so \; && \
    strip --strip-unneeded /tmp/sum_columns.so || true

# ============================================================
# Stage 2: Test — pure Lambda Python 3.12 + .so + local parquet
# ============================================================
FROM public.ecr.aws/lambda/python:3.12 AS test

RUN pip3.12 install --no-cache-dir "pyarrow>=15.0"

COPY --from=builder /tmp/sum_columns.so ${LAMBDA_TASK_ROOT}/
COPY --from=builder /opt/gcc16/lib64/libstdc++.so.6 /lib64/
COPY --from=builder /opt/gcc16/lib64/libgcc_s.so.1 /lib64/
COPY handler.py ${LAMBDA_TASK_ROOT}/
COPY data/ ${LAMBDA_TASK_ROOT}/data/
COPY tests/cleanroom_test.py /tmp/cleanroom_test.py

RUN python3.12 -c "import sum_columns; print('import OK')"
RUN python3.12 /tmp/cleanroom_test.py

RUN ldd ${LAMBDA_TASK_ROOT}/sum_columns.so

CMD ["handler.lambda_handler"]
