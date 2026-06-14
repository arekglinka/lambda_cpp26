FROM public.ecr.aws/lambda/python:3.12

ARG GCC_VERSION=16.1.0

RUN dnf install -y \
        gcc gcc-c++ binutils cmake ninja-build git \
        python3.12-devel \
        tar xz bzip2 ca-certificates ncurses-devel which curl-devel \
        gmp-devel mpfr-devel libmpc-devel isl-devel \
        bison flex texinfo wget diffutils \
        perl perl-FindBin \
        zlib-devel openssl-devel \
        clang-tools-extra gdb valgrind \
    && dnf clean all

RUN mkdir -p /tmp/gcc && cd /tmp/gcc && \
    curl -sL "https://gcc.gnu.org/pub/gcc/releases/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz" | \
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

RUN pip3.12 install --no-cache-dir \
    "conan>=2.4" "cmake>=3.28" "ninja>=1.11" \
    "pybind11>=2.13" "pyarrow>=15.0" "pytest>=8.0"

WORKDIR /workspace

COPY profiles/ /tmp/conan-profiles/
COPY recipes/ /tmp/recipes/

RUN conan remote add conancenter https://center2.conan.io --force 2>/dev/null || true && \
    conan export /tmp/recipes/arrow && \
    conan export /tmp/recipes/quantlib && \
    conan profile detect 2>/dev/null || true
