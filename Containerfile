# ============================================================
# Stage 1: Builder — Conan package (library + handler)
# ============================================================
FROM amazonlinux:2023 AS builder

ARG BUILD_TYPE=Release

RUN dnf install -y \
        gcc gcc-c++ binutils cmake ninja-build git \
        python3 python3-pip perl perl-FindBin \
        tar xz bzip2 ca-certificates \
        ncurses-devel which curl-devel \
        gmp-devel mpfr-devel libmpc-devel isl-devel \
        bison flex texinfo wget diffutils \
    && dnf clean all

# Build GCC 16.1.0 from source — AL2023 ships GCC 11.5.0 which lacks C++26.
# --disable-bootstrap uses system GCC 11 as stage-1 compiler (faster).
# Layer is cached unless this step changes.
RUN mkdir -p /tmp/gcc && cd /tmp/gcc && \
    curl -sL https://gcc.gnu.org/pub/gcc/releases/gcc-16.1.0/gcc-16.1.0.tar.xz | \
    tar xJ --strip-components=1 && \
    ./contrib/download_prerequisites && \
    mkdir build && cd build && \
    ../configure --prefix=/opt/gcc16 \
        --enable-languages=c,c++ \
        --disable-multilib \
        --disable-bootstrap \
        --disable-nls \
        --enable-checking=release && \
    make -j"$(nproc)" && \
    make install && \
    rm -rf /tmp/gcc

ENV CC=/opt/gcc16/bin/gcc
ENV CXX=/opt/gcc16/bin/g++
ENV PATH="/opt/gcc16/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/gcc16/lib64:${LD_LIBRARY_PATH}"
# GCC 16 defaults to C17/C23 which rejects old K&R C code in transitive
# deps (termcap 1.3.1 etc.).  Force gnu11 for C so forward declarations
# without prototypes still work; keep C++26 for our project code.
ENV CFLAGS="-std=gnu11 -fgnu89-inline"
ENV CXXFLAGS=""

RUN pip3 install --no-cache-dir "conan>=2.4" "cmake>=3.28" "ninja>=1.11"
RUN conan remote add conancenter https://center2.conan.io --force 2>/dev/null || true

# aws-lambda-cpp is NOT on ConanCenter — build from source and install to /usr/local
RUN mkdir -p /tmp/awslambda && \
    curl -sL https://github.com/awslabs/aws-lambda-cpp/archive/refs/tags/v0.2.6.tar.gz | \
    tar xz --strip-components=1 -C /tmp/awslambda && \
    cd /tmp/awslambda && mkdir build && cd build && \
    cmake .. \
        -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_CXX_STANDARD=26 \
        -DCMAKE_CXX_STANDARD_REQUIRED=ON && \
    cmake --build . -j"$(nproc)" && \
    cmake --install . && \
    rm -rf /tmp/awslambda

WORKDIR /src

# Export custom recipes to local Conan cache
COPY recipes/ /tmp/recipes/
RUN conan export /tmp/recipes/arrow/
RUN conan export /tmp/recipes/quantlib/

COPY profiles/ /root/.conan2/profiles/
COPY conanfile.py .
COPY src/ src/
COPY tests/ tests/

# Resolve and build all dependencies from source
RUN conan install . \
    --build=missing \
    -pr:h al2023 \
    -s:h build_type=${BUILD_TYPE} \
    -s:h compiler.cppstd=26

# Build the library and handler
RUN conan build .

# Install to a known prefix (fixes the missing cmake.install bug)
RUN cmake --install build/${BUILD_TYPE} --prefix /src/install

# Create a stripped copy of the handler for production
RUN cp /src/install/bin/lambda_handler /src/install/bin/lambda_handler.stripped \
    && strip --strip-all /src/install/bin/lambda_handler.stripped

# Smoke tests
RUN test -f /src/install/lib/liblambda_cpp26.a && echo "OK: static library"
RUN test -f /src/install/bin/lambda_handler && echo "OK: handler binary"

# ============================================================
# Stage 2: Development image (full tools + debug support)
# ============================================================
FROM public.ecr.aws/lambda/provided:al2023 AS dev

ARG BUILD_TYPE=Release
ARG LAMBDA_DIR=/opt/lambda

# Debug tools for local development
RUN dnf install -y gdb gdb-gdbserver strace valgrind && dnf clean all

COPY --from=builder /src/install/bin/lambda_handler ${LAMBDA_DIR}/bin/
COPY --from=builder /src/install/lib/ ${LAMBDA_DIR}/lib/
COPY --from=builder /src/install/include/ ${LAMBDA_DIR}/include/
COPY src/bootstrap /lambda-entrypoint
RUN chmod +x /lambda-entrypoint

ENV LAMBDA_TASK_ROOT=${LAMBDA_DIR}
ENV LAMBDA_RUNTIME_DIR=/var/runtime
EXPOSE 8080

CMD ["/lambda-entrypoint"]

# ============================================================
# Stage 3: Production image (stripped, minimal)
# ============================================================
FROM public.ecr.aws/lambda/provided:al2023 AS prod

ARG BUILD_TYPE=Release
ARG LAMBDA_DIR=/opt/lambda

# Only the stripped handler binary — no debug symbols, no lib, no headers
COPY --from=builder /src/install/bin/lambda_handler.stripped ${LAMBDA_DIR}/bin/lambda_handler
COPY src/bootstrap /lambda-entrypoint
RUN chmod +x /lambda-entrypoint

ENV LAMBDA_TASK_ROOT=${LAMBDA_DIR}
ENV LAMBDA_RUNTIME_DIR=/var/runtime
EXPOSE 8080

CMD ["/lambda-entrypoint"]
